# World Manager: core (sessions, world login, characters, zone handoff)

Source: `Files/Server/2016/w00_WorldManager/4WorldManagerServer2.exe` (2016), Ghidra export `re-data/exports/wm`.
Each block cites the function it was reconstructed from (`@ FUN_xxxxxxxx`). View the original with

```
python3 -I tools/protocol-re/clean.py re-data/exports/wm tools/protocol-re/names/wm 419860
```

Names are ours unless they come from a string in the binary (log text, `fc_NC_*` handler names, server
parameter keys). *(inferred)* marks behaviour deduced from context. Payload offsets are from the start of the
payload (after the 2-byte opcode). Counterpart: [`../login-server.md`](../login-server.md) §5.3.
Client cross-references use `docs/knowledge/C01.md` (client scenes `LoginWorldNetFrameWork`, `CharSelectFrameWork`,
`CharCreateFrameWork`, `CHairShopFrameWork`).

Party, guild, friends, chat, KQ, events and other feature callees that the core handlers trigger are only named
here; they belong to W02–W04.

---

## 1. Process structure

```
g_WM  (DAT_0049a028, the server object; "this" in startup/tick code)
├── config            WMServerInfo.txt (+ #INCLUDE ServerInfo.txt)                  @ FUN_00403e70
│     +0x500 myServerType (=5)  +0x504 worldNo (g_WorldNo, DAT_0049a52c)  +0x508 zoneNo
├── listeners         zone (type 6), client (type 20), OPTool (type 8)
├── outgoing links    (session objects embedded in g_WM; state at +0)
│     +0x98f8 g_AccountDB    (DAT_004a3920)   "AC"
│     +0xab14 g_AccountLogDB (DAT_004a4b3c)   "AL"
│     +0xbd30 g_CharDB       (DAT_004a5d58)   "CH"
│     +0xcf4c g_GameLogDB    (DAT_004a6f74)   "GL"
│     +0xe168 g_LoginLink    (DAT_004a8190)   "LO"   also holds the pending world-login table (§3.1)
├── incoming sessions
│     +0xbcb88 g_Clients (DAT_00556bb0)   client sessions, parser CParserClient
│     +0xbdcc4 g_Zones   (DAT_00557cec)   zone sessions,   parser CParserZone (index = zoneNo) + map table
│     +0xc2f9c g_OPTools (DAT_0055cfc4)   operator tools,  parser CParserOPTool
├── g_ServerParams (DAT_006c549c)  named integer parameters (ServerParam_GetInt, e.g. "KQVote_LoginCoolTime")
└── +0x22b534 running flag, +0x22b530 server phase (2 running, 4/6 after AccountDB/CharDB loss)
```

Link/session `state` (word at +0): 0 = not connected, 2 = connecting, 1 = validated (handshake done),
3 = close requested, 4 = closing. Every handler starts with `<Peer>_CheckAlive(session)`, which only passes
for `state == 1` (for clients it also stores disconnect reason 0x787 when it fails) @ FUN_00412b20 / FUN_00424510 /
FUN_00407b40 / FUN_00408bf0 / FUN_00409a30 / FUN_00428230.
Unregistered opcodes go to `fc_dummyfunction, <PEER>, dep=%d, cmd=%d, length=%d` and are ignored.

### 1.1 Client session (size 0x1f7b8; fields used by the core)

| Offset | Field (ours) | Notes |
|---|---|---|
| +0x000 | state | see above |
| +0x010 | connectTime (SYSTEMTIME) | used for the logout play-time log |
| +0x030 | ip (u32) | |
| +0x0f4 / +0xf8 / +0xfc | lastOpcode / lastLen / inHandler | debug copy for the "Closed …" logs |
| +0x114 | handle (u16) | index in g_Clients; sent to the DB servers and to the client in 0x0C14 |
| +0x116 | linking (u8) | 1 = leaving a zone (0x180B, 0x0C18 mode 1); 0 after 0x180C |
| +0x117 | zoneNo (u8) | zone the character is on (set by 0x180C) |
| +0x118 | zoneHandle (u16) | the zone's handle for this player (0x101C) ; 0xFFFF on return to char select |
| +0x11a | closeReason (u16) | 0x780 logout, 0x785 double login, 0x787 not alive, 0x788 auth fail / DB error |
| +0x124 | userNo (i32) | -1 until the world login succeeded |
| +0x128 | userId (char[256]) | |
| +0x228 | extra (u32[5]) | from Login's 0x0C0D, forwarded to CharDB in 0x1036 |
| +0x23c | avatars[6] (AVATAR, 0x82 bytes each, §6.1) | charNo = -1 means empty slot |
| +0x548 | charLoginTime (SYSTEMTIME) | set by 0x1005 |
| +0x558 | expAtLogin (u64) | copy of CHARDATA +0x1a |
| +0x560.. | cached character blobs, (ptr, size) pairs (§6.3) | +0x560 = CHARDATA base (first u32 = charNo) |
| +0x638 | 0x1030 block (u8 + u16 + u16) | |
| +0x6e8 | pendingLink (u32) + dest (map[12], x, y) at +0x6ec | set by zone 0x180D |
| +0x704 | inGame (u32) | 1 after 0x1005 success; the logout path checks it |
| +0x1df7c | guildNo | from CharDB 0x1012 |
| +0x1e28c | playingCharNo (i32) | -1 = no character in game; guards 0x1001 |
| +0x1ed20 | loginStep | 0 = waiting for 0x0C0F, 1 = world login accepted, -1 = refused |
| +0x1ed24 | acceptTime (time_t) | |
| +0x1ed54 / +0x1ed58 | userKind / userKindUntil | 1 normal, 2 newbie, 3 comeback (§3.3) |

---

## 2. Startup, links and timers

```pseudo
LoadServerInfo(wm):                                       @ FUN_00403e70
    parse "WMServerInfo.txt"             else log "*FAILED SCRIPTOR READ* %s"
    log "<I AM THE %s, %s, WorldNo=%d, ZoneNo=%d>"
    find SERVER_INFO rows (type, world, zone, listenType):
        accountLog (1,0,0)  account (0,0,0)  character (2,world,0)  gameLog (3,world,0)
        login      (4,0,0,from=myType)
        zone listen     (myType, world, 0, 6)    client listen (…, 20)    OPTool listen (…, 8)
    each missing row: log "*FATAL ERROR, CAN'T FOUND %s's <X> INFO*"; startup fails if any is missing

BootstrapTick(wm):                                        @ FUN_00404bf0
    OpenListener(zone)                                     @ FUN_00404600  "<SUCCESSED LISTEN ADD, IP=%s:%d, From=%s>"
    connect AccountLogDB, AccountDB, CharDB, GameLogDB, Login if state == 0
        log "<CONNECTING … TO %s:%d>" first time, "<RECONNECT … >" afterwards       @ FUN_00404b00/a10/920
    when AccountDB, AccountLogDB, CharDB and GameLogDB are all state 1:
        OpenListener(client) and OpenListener(OPTool)        @ FUN_00404720 / FUN_00404820
        running = 1; phase = 2; log "<SUCCESSED RUNNING SERVER---->"
    (clients cannot connect before the four DB links are validated; the Login link is not required)

SessionCleanupTick(wm):                                   @ FUN_00404e70
    for each link in state 3: Session_Close, log "Closed AC|AL|CH|GL|LO from (…)(DEP=%d,CMD=%d,LEN=%d,WORK=%d)"
        AccountDB lost while running:  phase = 4, link state 4, log "***FATAL ERROR - ACCOUNT DB SERVER DISCONNECTED, SERVER DOWN PROCESS ACTIVATED***"
        CharDB lost while running:     phase = 6, reconnect at once ("<AUTO-RECONNECT CHAR DB Count=%d …>")
        AccountLogDB / GameLogDB / Login lost: state 0, reconnected by BootstrapTick
            ("ACCOUNTLOG|GAMELOG|LOGIN SERVER DISCONNECTED, ATTEMPT TO RECONNECT.")
    zone / OPTool sessions in state 3: close and free ("<ZONE ALL SESSION ARE DISCONNECTED, FREE>" when none left)
    for each client session:
        if loginStep == 0 and now - acceptTime > 7200 s:  log "Invalid Client Session - TimeOver(%d sec) …"; state = 3
        if Client_IsOverLimit (+0x1ed28 == 1):             log "Invalid Client Session - NumberOfSessionOver(%d) …"; state = 3
        if state == 3: loginStep = -1; remove from the per-IP table (DAT_00556bb0 +0x24, 10 sessions per entry)
                       Client_OnClosed(s); free

Client_OnClosed(s):                                       @ FUN_00437030
    CharacterLogout(s)                                     @ FUN_00436d50 (§5.4)
    playMinutes = minutes since s.connectTime              @ FUN_00430440
    Send AccountDB    0x0C11 { u32 userNo, u8 worldNo, u16 playMinutes, u16 closeReason }   (raw, 11 bytes)
    Send AccountLogDB 0x0722 { u32 userNo, u8 worldNo, u16 playMinutes, u16 closeReason }
    Send AccountLogDB 0xC803 { u32 userNo, u32 playMinutes }
    Broadcast to all zones 0x0C19 NC_USER_CONNECTCUT2ZONE_CMD { u8[6] = 0xFF, u32 userNo }
    Session_Close(s)
```

Heartbeats: every link answers `0x0804 NC_MISC_HEARTBEAT_REQ` with `0x0805` (3 raw bytes `02 05 08`) and
ignores `0x0805` (@ FUN_00412ce0 client, FUN_00424860 login, FUN_00407e60 AccountDB, FUN_00408f30 AccountLogDB,
FUN_00409d90 CharDB, FUN_004242a0 GameLogDB, FUN_004287e0 zone, FUN_00425180 OPTool). Receiving any packet
refreshes the session's receive time (shared network library, as in Login §2).

Periodic pushes:

```pseudo
Login_WorldStatus(loginLink, force):                      @ FUN_00438d10   every 30 s, and once on connect
    if loginLink.state == 1:
        max = g_Clients.capacity; if 0 < g_Clients.userLimit <= capacity: max = userLimit   # limit set by OPTool 0x280E
        SendRaw(loginLink, 0x0808 { u16 currentUsers, u16 max })   # Login derives the world status byte from it (inferred)

Zones_TimeSync(zones, force):                             @ FUN_00439590   every 60 s, and when a zone connects
    Broadcast to all zones 0x0821 { struct tm now (36 bytes) }
```

### 2.1 Server-to-server handshake (all outgoing links)

```pseudo
on 0x0801 NC_MISC_S2SCONNECTION_RDY (link → WM):         @ FUN_004246c0 (Login), FUN_00407cf0 (AccountDB), FUN_00408da0, FUN_00409bf0, FUN_00424100
    SendRaw(link, 0x0802 NC_MISC_S2SCONNECTION_REQ {
        u8 0, u8 server_id_to (peer type: 4 Login, 0 AccountDB, …), u8 server_id_from = 5 (WM),
        u8 worldNo, u8 zoneNo, u16 key = server_id_to + server_id_from })
    # field names from the WM's own log "NC_MISC_S2SCONNECTION_REQ <server_id_from=%d, server_id_to=%d, key=%d, my_type=%d>"

on 0x0803 NC_MISC_S2SCONNECTION_ACK { u8 echo, u16 result }:   @ FUN_00424720 (Login), FUN_00407d50, FUN_00408e00, FUN_00409c50, FUN_00424160
    if result == 0: link.connectedAt = now; link.state = 1; log "Connected to …"
                    Login link only: Login_WorldStatus(force)      # first 0x0808 right away
    else:           log validation failure with the result code
```

---

## 3. World login (client → WM)

### 3.1 Pending world logins (Login → WM)

```pseudo
0x0C0D world login request (Login → WM):                  @ FUN_00424950
    # payload = WORLDLOGIN (0x15B bytes): u16 loginHandle, u8 worldNo, u32 userNo, char userId[256],
    #           u16 validate[32] @+0x107, u32 extra[5] @+0x147         (same struct Login builds, login §4)
    slot = XOR of all 32 validate words                   # = the key Login mixed into word 31 (login §4), 0..0x7FF expected
    g_LoginLink.pending[slot] = payload                   # table at g_LoginLink+0x114, 0x15B bytes per slot; newer entry overwrites
    reply 0x0C0E { WORLDLOGIN copy, u8 ok = 1 }           # Login then sends 0x0C0C to the client
```

The WM never refuses here; Login checks `ok` and the world status itself.

### 3.2 Client connects to the WM

```pseudo
on accept (client listener):                              @ FUN_00405860 (AcceptTick)
    s.type = 20; s.state = 1; register IOCP; Client_SendSeed (0x0807, as Login)    @ FUN_00430550
    # loginStep = 0 and acceptTime = now are set when the session is allocated (inferred; read by the cleanup tick)
    # client LoginWorldNet answers the seed with 0x0C0F
    zone accept: IOCP register + FUN_00439100; OPTool accept: FUN_00438e60 (handshake starts with the peer's 0x0802)

ClientParser.Dispatch(s, packet):                         @ FUN_00419690
    keep last opcode/len for logs; XOR-decrypt (FUN_0045d4b0, same cipher as Login)
    if s.loginStep == 0:
        if opcode != 0x0C0F: goto reject
        s.loginStep = 1; remove s from the per-IP pending table
    elif s.loginStep == -1: goto reject
    ok = handler(s, packet, len)
    if !ok: s.state = 3                                   # handler returning 0 closes the session
reject:
    if a handler is registered for the opcode:
        log "Invalid Client Session - Invalid sequence protocol(Dept/Cmd = %d/%d) - IP_Addr(…), nUserRegNo(%d), nZoneNo(%d)"
    s.state = 3

0x0C0F world login (payload 0x140 bytes: char userId[256], u16 validate[32] @+0x100):   @ FUN_00419860
    entry = LoginLink_TakePendingLogin(validate)           @ FUN_00438ba0
        slot = XOR of the 32 words; if slot < 0x800 and pending[slot].validate == validate (all 32 words):
            result = { userNo = pending[slot].userNo, extra = pending[slot].extra }
            zero pending[slot].validate; pending[slot].userNo = -1           # one-time use
        else result.userNo = -1
    s.userNo = result.userNo; s.extra = result.extra
    if s.userNo == -1:
        log the 32 validate words
        SendRaw(s, 0x0C15 { u16 0x44 })                    # client LoginWorldNet: leaves the scene
        s.closeReason = 0x788                               # ("Authentication failed." per login §8)
        return
    s.userId = payload.userId                              # taken from the client, NOT compared with the pending entry
    Clients_KickDoubleLogin(userNo)                        @ FUN_00437dc0
        for every other session with the same userNo:
            SendRaw(it, 0x0C17 { u16 0x683 })               # client: "same account logged in elsewhere" flag
            it.closeReason = 0x785; it.state = 3; log "CLIENT DOUBLE CONNECT CLOSE2, nUserNo=%d"
    Broadcast to all zones 0x0C16 NC_USER_KICKOFFFROMWORLD_CMD { u8[6] = 0xFF, u32 userNo }   @ FUN_00439540
    clear avatar slots (charNo = -1 in all 6)             @ FUN_004305d0
    s.userKind = 1; s.userKindUntil = 0
    Send AccountDB 0x0C60 NC_USER_RETURN_CHECK_REQ { u32 userNo, u16 handle }
    # continues in AccountDB 0x0C61 (§3.3); the client waits for 0x0C14
```

### 3.3 Newbie / comeback classification, then the avatar list

```pseudo
AccountDB 0x0C61 NC_USER_RETURN_CHECK_ACK { u16 handle, u32 userNo, u8 hasHistory, i32 seconds }:   @ FUN_00408740
    s = Clients_GetByHandle(handle); if s.userNo != userNo: log "ERROR - fc_NC_USER_RETURN_CHECK_ACK UserNo Not Match …"; return
    day = 86400
    if hasHistory == 1:
        if seconds < "UserComeback_DaysAfterComeback"·day:
            s.userKind = 3 (comeback); s.userKindUntil = now + (limit - seconds)
            → AvatarListRequest
        else:
            Send AccountLogDB 0x0C62 NC_USER_LOGOUT_LAST_DAY_REQ { u16 handle, u32 userNo }   → 0x0C63
    else:
        if seconds == 0:                                       s.userKind = 1
        elif seconds < "UserNewbie_DaysAfterSignUp"·day:       s.userKind = 2 (newbie); s.userKindUntil = now + (limit - seconds)
        elif seconds >= "UserComeback_DaysAfterSignUp"·day:    Send AccountLogDB 0x0C62 …; return
        else:                                                  s.userKind = 1
        → AvatarListRequest
    # parameter names are the g_ServerParams keys; each is read once and cached

AccountLogDB 0x0C63 NC_USER_LOGOUT_LAST_DAY_ACK { u16 handle, u32 userNo, i32 secondsSinceLogout }:   @ FUN_004093b0
    if s.userNo != userNo: log "ERROR - fc_NC_USER_LOGOUT_LAST_DAY_ACK UserNo Not Match …"; return
    if secondsSinceLogout < "UserComeback_DaysAfterLogOff"·day: s.userKind = 1
    else: s.userKind = 3; s.userKindUntil = now + "UserComeback_DaysAfterComeback"·day
          Send AccountDB 0x0C64 { u32 userNo }                 # record the comeback (inferred)
    → AvatarListRequest

AvatarListRequest:   Send CharDB 0x0C12 NC_USER_AVATARINFO_REQ { u16 handle, u32 userNo }

0x0C1F (client asks for the avatar list again):          @ FUN_00412ee0
    SendRaw(CharDB, 0x0C12 { u16 handle, u32 userNo })

CharDB 0x0C5F { u16 handle, u8 tutorialSkip }:           @ FUN_0040e260
    s.tutorialSkip = tutorialSkip                          @ FUN_004335f0   (CharDB proc usp_Tutorial_getIsSkip; sent just before 0x0C13)

CharDB 0x0C13 NC_USER_AVATARINFO_ACK { u16 handle, u8 count, AVATAR[count] @+3 }:   @ FUN_0040ede0
    clear avatar slots
    if count == 0xFF:                                       # DB error
        SendRaw(s, 0x0C15 { u16 0x46 })                     # "DB error"; client leaves LoginWorldNet
        s.closeReason = 0x788; Client_OnClosed(s)
        return
    for each record a: if a.slot < 6:
        if a.tutorialState == 0: a.loginMap = "RouT"      # characters that never finished the tutorial
        s.avatars[a.slot] = a
    Send client 0x0C14 { u16 handle, u8 count, AVATAR[count] }   # verbatim copy of the DB records (map not patched)
    # client LoginWorldNet FUN_00471720 (and CHairShop FUN_00629720): stores handle as g_WmHandle, loads the list,
    # switches to character select
```

---

## 4. Character select (client → WM)

### 4.1 Create / delete / rename

```pseudo
NameIsValid(name, maxLen):                               (inline in each handler)
    1 <= strlen(name) <= maxLen and no ' ' and not FUN_0043a400(&DAT_006c5220, name)   # forbidden-name list (inferred)

0x1401 create { u8 slot, char name[20] @+1, u8 shape[4] @+0x15 }:   @ FUN_004229f0
    # shape[0] bits: 0-1 race (inferred), 2-6 class, 7 gender; shape[1..3] hair, hair colour, face (AVATAR +0x2c..+0x2f)
    if slot >= 6 or !NameIsValid(name, 20): goto fail
    if (shape[0] & 0x7c) == 0x68 (class 26):
        if account's highest character level (FUN_00433540) < "ChrLevel_CanCreateSen": goto fail
    SendRaw(CharDB, 0x1402 { u16 handle, u32 userNo, u8 worldNo, u8 0, u8 slot, char name[20], u8 shape[4] })
    return
fail:
    SendRaw(s, 0x1404 { u16 0x84 })                        # every failure above reports 0x84 (client: name already taken)

CharDB 0x1403 create failed { u16 handle, …, u16 error @+0x16 }:   @ FUN_00409f00
    send client 0x1404 { u16 error }          # client: 0x82 failed, 0x83 wrong class, 0x84 name taken, 0x85 max slot, 0x181 name in use

CharDB 0x1405 created { u16 handle, u8 ?, AVATAR @+3 }:  @ FUN_004113c0
    s.avatars[avatar.slot] = avatar
    SendRaw(AccountDB, 0x140D { u32 userNo, u8 worldNo, u32 charNo, char name[20], …, u8 class })   # 0x34 bytes
    SendRaw(GameLogDB, 0x0411 { u32 charNo }); Send GameLogDB 0xC804 { u32 userNo, u32 charNo, u8 class }
    send client 0x1406 { u8 1, AVATAR }                    # client CharCreate: append to the list, back to char select

0x1407 delete { u8 slot }:                                @ FUN_00412fa0
    if slot < 6 and s.avatars[slot].charNo != -1:
        SendRaw(CharDB, 0x1408 NC_AVATAR_ERASEDATA_REQ { u16 handle, u32 charNo, u8 slot })
    else: SendRaw(s, 0x140A { u16 0xC6 })                  # client: "Unable to delete a Guild Master character." (any code but 199)

CharDB 0x1409 NC_AVATAR_ERASEDATA_ACK (failure) { u16 handle, u16 ?, u16 error @+4 }:   @ FUN_00409fa0
    send client 0x140A { u16 error }                       # 199 = "You may not delete guild leader."

CharDB 0x140B erased { u16 handle, u32 userNo @+2, u32 charNo @+6, u8 slot @+0xa }:   @ FUN_0040a010
    SendRaw(AccountDB, 0x140E { u32 userNo, u8 worldNo, u32 charNo }); SendRaw(GameLogDB, 0x0412 { u32 charNo })
    Send GameLogDB 0xC805 { u32 userNo, u32 charNo, u8 class }
    s.avatars[slot].charNo = -1
    send client 0x140C { u8 slot }
    FUN_004382d0(&g_Clients, charNo)                       # drop the character from WM-side registries (inferred)

0x140F rename (char select) { u8 slot, char name[20] @+1 }:   @ FUN_0041a640
    if slot >= 6 or slot empty or !NameIsValid(name, 16):
        SendRaw(s, 0x1410 { u8 slot, char name[20], u16 0xD1 })    # client: "The name cannot be used."
        return
    SendRaw(CharDB, 0x1411 { u16 handle, u32 charNo, u8 slot, char name[20] })

CharDB 0x1412 rename result { u16 handle, …, u8 slot @+6, char name[20] @+7, u16 result @+0x1b }:   @ FUN_0040ff00
    if result == 0xD0: s.avatars[slot].name = name
    send client 0x1410 { u8 slot, char name[20], u16 result }      # client: 0xD0 ok, 0xD1 refused

0xB409 rename with a rename item { u8 slot, char name[20] @+1 }:   @ FUN_00417c90
    reply = 0xB40C { u16 code, u8 slot, char name[20] }
    if slot >= 6:                               code = 0x20C1
    elif s.avatars[slot].charNo == -1:          code = 0x20C2
    elif s.avatars[slot] byte +0x77 != 1:       code = 0x20C3   # rename right not granted for this character (inferred)
    elif !NameIsValid(name, 16):                code = 0x20D3
    else:
        Send CharDB 0xB40A { u16 handle, u32 avatar+0x79, u32 userNo, u32 charNo, char name[20], u8 avatar+0x78 }
        return                                   # answer: CharDB 0xB40B (§6.2)
    send client reply                            # client: 0x20C0 ok, 0x20C7 guild master, 0x20D1 taken, else code text
```

### 4.2 Character login (enter the game)

```pseudo
0x1001 NC_CHAR_LOGIN_REQ { u8 slot }:                     @ FUN_00422be0
    if slot >= 6:                     SendRaw(s, 0x1002 { u16 0x143 }); return    # "Failed to connect to the map server"
    a = s.avatars[slot]
    if a.charNo == -1:                log "ERROR - fc_NC_CHAR_LOGIN_REQ #2 …"; SendRaw(s, 0x1002 { u16 0x144 }); return   # "no character in the slot"
    s.selectedSlot = slot                                   @ FUN_00433610
    if a.tutorialState == 0:
        if a.tutorialStep == 0: send 0x1110 (empty) and return     # client asks "Would you like to start the tutorial?" → 0x1111
        a.loginMap = "RouT00"; send 0x111D (empty)                # client creates the tutorial helpers
    if g_InstanceMaps.Redirect(a+0x5b, a.returnMap @+0x5f, a+0x73):   @ FUN_00452580 (DAT_0055e15c, inferred: instance/KQ map that no longer exists)
        a.loginMap = a.returnMap
    zone = g_Zones.FindByMap(a.loginMap)                    @ FUN_004392c0 (§7.1)
    if zone not connected:            SendRaw(s, 0x1002 { u16 0x145 }); return    # client: "The Map is under maintenance"
    if s.playingCharNo != -1:         log "ERROR - CParserClient::fc_NC_CHAR_LOGIN_REQ - WorldData(…), PlayingCharNo-%d"
                                      SendRaw(s, 0x1002 { u16 0x145 }); return
    s.playingCharNo = a.charNo
    reset per-character state (KQ vote cool-down = now + "KQVote_LoginCoolTime", chat/party/event fields, …)
    SendRaw(CharDB, 0x1004 NC_CHAR_CHARDATA_REQ { u16 handle, u32 charNo, u32 userNo, u32 (stored day-start time - 1 day) })
    # CharDB answers with the blob packets 0x1007…0x101B (§6.3), then 0x1005

0x1111 tutorial answer { u8 skip }:                       @ FUN_00418cb0
    if skip == 0: send 0x111D                              # start the tutorial helpers
    Send CharDB 0x1112 NC_CHAR_TUTORIAL_MAKE_ITEM_REQ { u16 handle, u8 worldNo, u32 charNo(selected slot), u32 userNo, u8 skip }
    # CharDB 0x1113 NC_CHAR_TUTORIAL_MAKE_ITEM_ACK → §6.2

CharDB 0x1005 NC_CHAR_CHARDATA_ACK { u16 handle, … }:    @ FUN_00410040
    c = s.CHARDATA (+0x560); link = s blob 0x101A (+0x648)
    if link == null or c == null: return
    if g_InstanceMaps.Redirect(link.u32, link.map, link+0x18):
        FUN_00452e40 / FUN_00454ee0: if the character still belongs to the instance: s+0x1df74 = 1; re-register
        else: c.map/x/y = link.map/x/y; c.dir(+0x56) = 0x5A
    if c.prison (+0x62 u16) != 0: c.map = "EldPri"; c.x = 0x2C0; c.y = 0x3C2       # prison map
    a = selected avatar (FUN_00433620); if none: SendRaw(s, 0x1002 { u16 0x31EB }); return
    if a.tutorialState == 0: c.map = "RouT00"; if a.tutorialStep == 0: c.x = 0x194E; c.y = 0x293E
    zone = g_Zones.FindByMap(c.map); addr = g_Zones.GetAddress(c.map, worldNo, &ip[16], &port)   @ FUN_004393e0
    if no zone or no address:          SendRaw(s, 0x1002 { u16 0x145 }); return
    if c.charNo != s.playingCharNo or c.charNo == -1:
        log "ERROR - CParserCharDB::fc_NC_CHAR_CHARDATA_ACK 1|2 - …"; SendRaw(s, 0x1002 { u16 0x145 }); return
    s.inGame = 1; s.charLoginTime = now; s.expAtLogin = c.exp; clear pendingLink; set several "first map login" flags
    SendRaw(CharDB, 0x1036 NC_CHAR_LOGIN_DB { u32 charNo, char map[12], u32 x, u32 y, u64 money(+0x3a), u32 userNo, u32 extra[5] })
    Send GameLogDB 0xC806 { u32 userNo, u32 charNo }
    SendRaw(s, 0x1003 { char zoneIp[16], u16 zonePort })   # client CharSelect FUN_00476190 → zone-login scene, connects to the zone
    FUN_00431680(s)                                         # notify W02–W04 subsystems (inferred)
```

The client then connects to the zone and sends `0x1801 NC_MAP_LOGIN_REQ { u16 wmHandle, char charName[20], … }`.
The zone asks the WM for the character data with `0x101C` (§7.2).

Correction to the plan text: `0x1036` goes to the **Character DB** (`NC_CHAR_LOGIN_DB`), not to the zone. The zone
receives the data in §7.2.

### 4.3 Beauty shop at character select (CHairShopFrameWork)

```pseudo
0x1078 apply style { u32 v }:                             @ FUN_004158a0
    if s.CHARDATA: SendRaw(CharDB, 0x107A NC_CHAR_SET_STYLE_DB_REQ { u16 handle, u32 charNo, u32 v })
    else:          SendRaw(s, 0x1079 { u16 0x1284 })        # client: unknown error
0x107C get style info:                                    @ FUN_00415960
    if s.CHARDATA: SendRaw(CharDB, 0x107E NC_CHAR_SET_STYLE_GET_INFO_DB_REQ { u16 handle, u32 charNo })
    else:          SendRaw(s, 0x107D { u16 0x1284, … }) (0x1C bytes)
CharDB 0x107B NC_CHAR_SET_STYLE_DB_ACK / 0x107F NC_CHAR_SET_STYLE_GET_INFO_DB_ACK: §6.2
```

---

## 5. In-game client requests (core)

### 5.1 Logout and return to character select

```pseudo
0x0C18 NC_USER_NORMALLOGOUT_CMD { u8 mode }:             @ FUN_00412df0
    if s.CHARDATA == null: return
    s.inLogout = 1
    if mode == 0:     # quit the game
        Broadcast zones 0x0C19 NC_USER_CONNECTCUT2ZONE_CMD { u8[6] 0xFF, u32 userNo }
        s.closeReason = 0x780; CharacterLogout(s); s.state = 3
    elif mode == 1:   # back to character select, the WM connection stays
        s.closeReason = 0x780; CharacterLogout(s); s.linking = 1; s.zoneHandle = 0xFFFF
    s.inLogout = 0

0x0C33 return-to-world-select token:                     @ FUN_00417330
    Send Login 0x0C35 { u16 handle, u32 userNo, char userId[256], u32 ip }

Login 0x0C36 { u16 result, u16 wmHandle, char token[32] }:   @ FUN_00424a70
    s = Clients_GetByHandle(wmHandle)
    SendRaw(s, 0x0C34 { u16 result, char token[32] })     # client CharSelect FUN_004766a0: 0x1E58 = ok, keeps the token,
                                                           # reconnects to Login and sends 0x0C37 (login §4)
```

Login's real field order is `{u16 result, u16 wmHandle, token}` (Login `FUN_00408a20` writes result at +0); the
summary in `login-server.md` §5.3 lists them the other way round.

### 5.2 Kicks

```pseudo
Login 0x0C16 NC_USER_KICKOFFFROMWORLD_CMD { …, u32 userNo @+6 }:   @ FUN_00424880
    FUN_00437d50(&g_Clients, userNo)                       # close every session of that user (inferred, like §3.2)
    Broadcast zones 0x0C16 { u8[6] 0xFF, u32 userNo }

Zone 0x0C1A { …, u32 userNo @+6, u16 wmHandle @+0xa, u16 reason @+0xc }:   @ FUN_00428a40
    s = Clients_GetByHandle(wmHandle); if s.userNo == userNo: SendRaw(s, 0x0C17 { u16 reason })
```

### 5.3 Small client requests

```pseudo
0x080D server time:                                      @ FUN_00413050
    SendRaw(s, 0x080E { u8 hour, u8 minute, u8 second })   # local time; client clock (Net pre-dispatch)
0x080F client debug dump { u16 handle, u16 len, u8 data[len] }:   @ FUN_00413820
    if handle is a live session and len != 0: append data to ".\DebugClient\NewMsg_%s.ser" (timestamped name)
0x081B web key:                                          @ FUN_004157d0
    Send AccountDB 0x081D NC_MISC_WEB_DB_KEY_REQ { u16 handle, u32 userNo }
AccountDB 0x081E NC_MISC_WEB_DB_KEY_ACK { u16 ?, u16 handle, u32 userNo, u32 key[8] }:   @ FUN_00407e80
    if s.userNo == userNo: send client 0x081C { u16 ?, u32 key[8] } else log "ERROR - fc_NC_MISC_WEB_DB_KEY_ACK MISS …"
0x081A, 0x0836, 0x0827, 0x0832, 0x0834, 0x0819: accepted, no action (CheckAlive only)   @ FUN_00415750 / 415790 / 415a10 / 415bc0 / LAB_00414e40
0x0813 NC_MISC_PINGTEST_TOOL_WM_CLIENT_ZONE_DB:          @ FUN_00415670
    payload +0x28 = timeGetTime(); forward 0x0813 (0x82 bytes) to the OPTool session whose handle is at payload +4
0x10DA NC_CHAR_NEWBIE_GUIDE_VIEW_SET_CMD { u8 view }:    @ FUN_004182f0
    Send CharDB 0x10DB NC_CHAR_NEWBIE_GUIDE_VIEW_SET_DB_CMD { u32 charNo, u8 view }
0x086E NC_MISC_ITEMSHOP_URL_REQ:                         @ FUN_00418450
    if now < s.itemShopNextAllowed: send 0x086F { u16 0x3041 }       # rate limit
    else: Send CharDB 0x0870 { u32 charNo, u32 userNo }; s.itemShopNextAllowed = now + 5 s
```

### 5.4 CharacterLogout (shared by logout, disconnect, return to select)

```pseudo
CharacterLogout(s):                                       @ FUN_00436d50
    if s.userNo != -1 and s.inGame == 1 and s.CHARDATA:
        leave party / raid, guild, friends, instances, chat bans, …   (FUN_00431240, 436670, 4357d0, 4576d0, 4353a0,
                                                                        452d70/454510, 44ccf0, 451790 … → W02–W04)
        s.inGame = 0
        m = minutes since s.charLoginTime
        SendRaw(CharDB, 0x1037 NC_CHAR_LOGOUT_DB { u32 charNo, char map[12] @c+0x42, u32 x, u32 y, u16 m,
                                                   u8 closeReason-0x80, u64 money @c+0x3a })
        if s blob 0x1008 (shape) present:
            SendRaw(AccountLogDB, 0x081F NC_MISC_CHAR_LOGOFF_STATISTICS { u8 worldNo, u32 userNo, u32 charNo, u8 class,
                    u8 level(c+0x19), u64 expGained = c.exp - s.expAtLogin, u16 m })
        Send GameLogDB 0xC807 { u32 userNo, u32 charNo, u32 m }
        if m >= 60: SendRaw(AccountLogDB, 0x0843 { u32 userNo, u16 m })
        if s.playingCharNo != -1: attendance manager FUN_0043b620(charNo)
    reset 0x258c, 0x1df68..0x1df78; FUN_004589b0/FUN_00458790 (remove from a name registry, inferred)
```

Note: `playingCharNo` is not cleared here. It is cleared when the zone sends `0x0C31` (§7.3), so a second
`0x1001` before the zone confirms the logout fails with 0x145.

---

## 6. Character DB link (CParserCharDB)

All replies carry the WM client `handle` at payload +0 (`Clients_GetByHandle`; the reply is dropped if the session
is gone). Some look the session up by `charNo` instead (`Clients_FindByCharNo` @ FUN_00437910).

### 6.1 AVATAR (0x82 bytes; char-select list entry)

Filled by the Character server (`CGameDB_Character::GetAvatarInfo`, character `FUN_0046bff0`); the WM stores and
forwards it without decoding most of it. Offsets used by the WM in **bold**.

| Off | Type | Field (ours) | Source / use |
|---|---|---|---|
| **+0x00** | u32 | charNo | -1 = empty slot (WM side) |
| +0x04 | char[20] | name | renamed by 0x1412 / 0xB40B |
| +0x18 | u16 | level (inferred) | |
| **+0x1a** | u8 | slot | 0..5 |
| **+0x1b** | char[12] | loginMap | "RouT" / "RouT00" forced for tutorial characters |
| +0x27 | u8 + u8[4] | delete-pending flag + date digits (inferred) | |
| **+0x2c** | u8 | race (bits 0-1, inferred), class (bits 2-6), gender (bit 7) | class used in logs and 0x1401 checks |
| +0x2d..+0x2f | u8×3 | hair, hair colour, face (inferred) | |
| +0x30..+0x5a | u16[…] + nibbles | equipped item ids per slot (0xFFFF = none) and upgrade levels | DB slot switch in `FUN_0046bff0` |
| **+0x5b** | u32 | instance/return key (inferred) | g_InstanceMaps.Redirect |
| **+0x5f** | char[12] | returnMap | used instead of loginMap when the instance map is gone |
| +0x6b, +0x6f | u32, u32 | ? | |
| **+0x73** | u32 | packed date (6/5/5/4/4-bit fields) | g_InstanceMaps.Redirect |
| **+0x77** | u8 | renameAllowed (inferred) | 0xB409 requires 1 |
| **+0x78**, **+0x79** | u8, u32 | rename-item data (inferred) | forwarded in 0xB40A |
| **+0x7d** | u32 | tutorialState | `usp_Tutorial_getCharInfo`; 3 when no row; 0 = tutorial not done |
| **+0x81** | u8 | tutorialStep | |

### 6.2 Avatar and character replies

```pseudo
CharDB 0x1006 { u16 handle, u16 error }:                 @ FUN_00409e70   (character data request failed)
    send client 0x1002 { u16 error }                       # client: 0x582..0x595 "There is an error in the <…> Information"

CharDB 0x1113 NC_CHAR_TUTORIAL_MAKE_ITEM_ACK { u16 handle, …, u16 result @+6, u8 skip @+8 }:   @ FUN_0040e2c0
    if result == 0x31E8:
        if skip == 1: a = selected avatar; if a.charNo == -1: send 0x1002 { 0x144 }; return
                      a.tutorialState = 2; a.tutorialStep = 0
        CWMClientSession::TutorialLoginProcess(s)          @ FUN_004371a0  (name from its log strings)
            # same steps as 0x1001 after the tutorial check: map = "RouT00" or the normal map, zone lookup,
            # playingCharNo guard, KQ vote cool-down, then CharDB 0x1004 ("TutorialMap Search Fail" → 0x1002)
    else: send client 0x1002 { u16 result }

CharDB 0xB40B NC_USER_CONNECTION_DB_CHANGE_CHAR_ID_ACK { u16 handle, u16 error, …, char name[20] @+0xc }:   @ FUN_0040d740
    if error == 0x20C0: error = FUN_00431dd0(s, …)          # apply the new name to the avatar slot, returns the slot
    send client 0xB40C { u16 error, u8 slot, char name[20] }

CharDB 0x107B NC_CHAR_SET_STYLE_DB_ACK { u16 code, u16 handle, u32 charNo, u32 shape }:   @ FUN_0040c530
    find s by handle (or by charNo); if code == 0x1280: s.SHAPE blob first u32 = shape
    SendRaw(s, 0x1079 { u16 code })
CharDB 0x107F NC_CHAR_SET_STYLE_GET_INFO_DB_ACK { u16 handle, u32 charNo, u16 code, u16 counts[12] }:   @ FUN_0040c5f0
    SendRaw(s, 0x107D { u16 code, u16 counts[12] })        # client: beauty shop item counts

CharDB 0x0871 NC_MISC_ITEMSHOP_URL_DB_REQ { u32 charNo, u16 code, u16 len, char url[len] }:   @ FUN_0040e090
    send client 0x086F NC_MISC_ITEMSHOP_URL_ACK { u16 code, u16 len, char url[len] }

CharDB 0xA005 NC_PROMOTION_DB_REWARD_ACK { …, u32 charNo @+5, u8 n @+0xd, u32 items[n] }:   @ FUN_0040d390
    if n: send client 0xA006 { u8 n, u32 items[n] }        (in-game session by charNo, FUN_004377c0)
CharDB 0xA002: accepted, no action                         @ FUN_0040d370

CharDB 0x0814 (ping test): payload+0x12 = timeGetTime(); forward 0x0814 (0x26 bytes) to the OPTool at payload+4   @ FUN_0040c460
```

### 6.3 Character blob cache (CharDB → WM → zone)

After `0x1004` the Character server streams the character's data as separate packets. The WM keeps a private copy
of each one in the client session (`Session_StoreBlob` @ FUN_00430780: free the old buffer, `malloc` + copy
`payload+2 .. end`, i.e. everything after the handle). Zones update the same blobs while the character plays
(dept 16, §7.4), and every zone the character enters gets them back in `0x101C` (§7.2). The WM is therefore the
live owner of the character state between zones.

| Session slot (ptr) | Filled by CharDB | Updated by zone (dept 16) | Sent to zone as (zone handler name) |
|---|---|---|---|
| +0x560 CHARDATA base | 0x1007 | 0x400E (level, exp, money, map, pos, stats) , 0x4017 (money), 0x1073 (exp), 0x1074 (level) | 0x101F NC_CHAR_ZONE_BASE_CMD |
| +0x568 shape | 0x1008 | 0x1058 (class bits) | 0x1020 NC_CHAR_ZONE_SHAPE_CMD |
| +0x570 quest doing | 0x100A | 0x400F | 0x1021 NC_CHAR_ZONE_QUEST_DOING_CMD |
| +0x578 quest done | 0x100B (FUN_00433210) | 0x4010 | 0x1022 (chunked ≤8000 bytes, 10-byte records; FUN_004332f0) |
| +0x580 quest read | 0x10CC | 0x4029 | 0x10CD NC_CHAR_ZONE_QUEST_READ_CMD |
| +0x588 quest repeat | 0x10D5 | 0x402B | 0x10D6 |
| +0x590 abstate | 0x100C | 0x4011 | 0x1023 NC_CHAR_ZONE_ABSTATE_CMD |
| +0x598..+0x5ac skill (up to 6 chunks) | 0x100D (FUN_004307d0 appends) | 0x4012 | 0x1024 NC_CHAR_ZONE_SKILL_CMD (stops after the chunk with flag bit 1 at +4) |
| +0x5c8 passive | 0x100E | – | 0x1025 NC_CHAR_ZONE_PASSIVE_CMD |
| +0x5d0 house | 0x100F | – | 0x1026 |
| +0x5d8 "maspup" | 0x1011 | – | 0x1028 |
| +0x5e0 emblem | 0x1013 | – | 0x102A |
| +0x5e8 pet | 0x1014 | – | 0x102B |
| +0x5f0 arena | 0x1015 | – | 0x102C |
| +0x5f8 sea war | 0x1016 | – | 0x102D |
| +0x600..+0x628 items: 3 inventory chunks, equip, mini-house skin, action | 0x1017 (FUN_00430870 splits by type) | 0x4013 | 0x102E NC_CHAR_ZONE_ITEM_CMD ×6 |
| +0x630 u16 list | 0x1018 | 0x4014 | (not in 0x101C) |
| +0x640 char title | 0x1019 | 0x4016 | 0x1031 NC_CHAR_ZONE_CHARTITLE_CMD |
| +0x648 saved link position | 0x101A | – | used by 0x1005 (§4.2) |
| +0x650 charged buff | 0x101B | – | 0x1032 NC_CHAR_ZONE_CHARGEDBUFF_CMD |
| +0x638 game block (u8 + u16 party + u16 raid) | – | 0x4015 NC_CHARSAVE_2WLDMAN_GAME_CMD, 0x083D | 0x1030 NC_CHAR_ZONE_GAME_CMD (party/raid numbers re-read from the WM registries) |
| +0x660 link-from | – | 0x4019 (0x18 bytes) | 0x10B8 NC_CHAR_ZONE_LINK_FROM_CMD (then freed) |
| +0x658 single option | 0x10D2 NC_CHAR_FREESTAT_SET_DB_ACK | 0x402A, 0x10C1 (byte +8) | 0x10D3 NC_CHAR_ZONE_SINGLE_OPTION_CMD |
| +0x668 item action cool-time | – | 0x4034 | 0x10D0 NC_CHAR_ITEMACTIONCOOLTIME_ZONE_CMD |
| +0x1ece4 chat block (8 bytes) | 0x10CA | 0x4021 | 0x10CB NC_CHAR_GET_CHAT_BLOCK_SPAMMER_CMD |
| +0x1ed04 previous map name (12) | – | – | 0xBC01 NC_GAMBLE_ZONE_PREVMAPNAME_CMD (only if set, then cleared) |
| +0x6c0 coin info | 0x10DC | 0x402C | 0x10DD |
| +0x6c8 / +0x6d0 / +0x6d8 card collection | 0x10E2 / 0x10E5 / 0x10E8 | – | 0x10E3 / 0x10E6 / 0x10E9 NC_CHAR_ZONE_CARDCOLLECT_(…)_CMD |
| +0x6e0 sell-item info | – | 0x4037 | 0x1130 NC_CHAR_SELL_ITEM_INFO_ZONE_CMD (then freed) |
| +0x1ecfc | 0x10D8 | – | |
| tutorial info | 0x1114 (FUN_00433630) | 0x111C | NC_CHAR_TUTORIAL_INFO_ZONE_CMD (FUN_00433660) |
| quest-chase / chat colour | 0x111E (FUN_00433800/810) | 0x4032 | FUN_00433820 |
| pet re-summon | – | 0x4033 (FUN_00433910…970) | NC_PET_LINK_RESUMMON_CMD (FUN_00433980) |
| minimon | 0x1121 NC_CHAR_USEITEM_MINIMON_INFO_CMD (FUN_00433bb0) | 0x4036 | NC_CHAR_USEITEM_MINIMON_INFO_ZONE_CMD (FUN_00433bd0) |
| mover link data | – | 0xCC0B (FUN_00432fa0) | NC_MOVER_ZONE_LINKDATA_ZONE_CMD (FUN_004330a0) |

Zone dept-16 handlers check `CHARDATA.charNo == payload charNo` before writing (@ FUN_00429d40 … FUN_0042d080).
Other CharDB pushes handled by later items: 0x1010 (list of ≤100 25-byte entries into +0x708, friends, inferred → W04),
0x1012 (guild number → +0x1df7c, W03), 0x1097 (guild academy, W03), 0x1414 NC_AVATAR_GUILD_DATA_ACK and 0x1416
NC_AVATAR_GUILD_MEMBER_DATA_ACK (W03), 0x0844 (chat-block flags, W04), 0x0864 / 0x0869 spammer chat ban (W04),
0x10EC / 0x10EF / 0x10F4 attendance event (W04).

---

## 7. Zone links (CParserZone)

### 7.1 Zone registration and map table

```pseudo
0x0802 NC_MISC_S2SCONNECTION_REQ { u8 echo, u8 server_id_to, u8 server_id_from, u8 world, u8 zone, u16 key }:   @ FUN_004283e0
    if to != 5 (WM): log …; return
    if key != to + from: log "NC_MISC_S2SCONNECTION_REQ <server_id_from=…, key=…>"; return
    row = ServerInfo(type 6, world, zone, listen 6); if the peer IP != row IP: log; return
    newZone = (g_Zones[zone] was empty)
    session.world/zone = …; g_Zones[zone] = session; session.state = 1
    reply 0x0803 { u8 echo, u16 0 }
    Zones_TimeSync(force)                                  # 0x0821 to all zones
    if newZone: FUN_00457110 → send the zone every active entry of DAT_006c536c as 0x086A (0x20 bytes each)   (W04)
    GMEventManager::GMEM_SendAllEventInfo(zone)            @ FUN_004010c0

0x180F map list { u16 n, n × { u8 a, char map[12], u8 b } }:   @ FUN_00428800
    for each: g_Zones.AddMap(map, zoneNo = session.zone, a, b)      @ FUN_004391d0
    # map table: 0x10-byte entries at g_Zones+0x1cc (u8 active, u8 zoneNo, …, char map[12]); count at +0x1c8

g_Zones.FindByMap(map[12]):  first active entry whose 12-byte name matches → zoneNo, else -1   @ FUN_004392c0
g_Zones.Get(zoneNo): session pointer or null                                                @ FUN_004391b0
g_Zones.GetAddress(map, world, &ip, &port): client IP/port from ServerInfo for that zone     @ FUN_004393e0
```

### 7.2 Character data for a zone (map login and map change)

```pseudo
0x101C NC_CHAR_ZONE_CHARDATA_REQ { u8 ref[6], u16 wmHandle @+6, char charName[20] @+8 }:   @ FUN_00428ba0
    # ref = the zone's own 6-byte reference (its player handle etc.); every reply starts with it
    s = Clients_GetByHandle(wmHandle)
    if s == null or s.CHARDATA == null:
        SendRaw(zone, 0x101E NC_CHAR_ZONE_CHARDATAFAIL_ACK { ref[4] , u16 ref+4, u16 0x141 }); return
    if charName != CHARDATA.name:
        log "NC_CHAR_ZONE_CHARDATA_REQ : CharID Not Match [%s/%s]"
        SendRaw(zone, 0x101E { …, u16 0x590 }); return
    if s.pendingLink: CHARDATA.map/x/y = s.linkDest; s.pendingLink = 0      # set by 0x180D on the old zone
    for each blob in the table of §6.3, in table order:
        Send zone <op> { ref[6], blob }                    @ FUN_00428ac0 (skipped when the blob is null)
        on send failure: log "ERROR - <NAME> To Zone, nCharNo=%d, CharName=%s" and stop (no reply)
    0x1029 NC_CHAR_ZONE_GUILD_CMD { ref, u32 guildNo }; 0x1098 NC_CHAR_GUILD_ACADEMY_ZONE_CMD { ref, u32 academyGuildNo }
    s.zoneHandle = ref[0..1]; FUN_00439e30(&DAT_006c5468, zone, ref)
    SendRaw(zone, 0x101D NC_CHAR_ZONE_CHARDATA_ACK { ref[6], u16 wmHandle })   # end of data
```

The zone answers the client's `0x1801` only after this sequence (Z01). The log strings name each opcode; where the log
text and the zone receiver disagree (0x1025 is logged as "SKILL", the null-skill check as "PASSIVE", 0x1030 as
"ITEM_CMD", 0x10D3 as "UI_STATE") this table uses the **zone receiver's** name.

```pseudo
0x104B NC_CHAR_REGISTNUMBER_REQ { u8 ref[6], u16 wmHandle @+6, char charName[20] @+8, … }:   @ FUN_0042f1e0
    s = Clients_GetByHandle(wmHandle)
    if s and s.mapLoginTicket (+0x1dfa0) == 1 and charName == CHARDATA.name:
        s.mapLoginTicket = 0; userNo = s.userNo; charNo = CHARDATA.charNo
    else:
        if s: s.state = 3                                   # unexpected map login: drop the WM session
        userNo = charNo = -1
    SendRaw(zone, 0x104C NC_CHAR_REGISTNUMBER_ACK { ref[6], u32 userNo, u32 charNo, u16 wmHandle, char charName[20] })
    # ticket set by 0x1005 (first login) and 0x180D (link reserve): one map login per ticket
```

### 7.3 Map login done, map change, logout notices

```pseudo
0x180D link reserve (old zone, player walks into a gate to another zone)
      { u8 ref[6], u16 wmHandle @+6, u8 ?, char destMap[12] @+9, u32 x @+0x15, u32 y @+0x19, … (to +0x3b) }:   @ FUN_0042f420
    s.mapLoginTicket = 1; s.pendingLink = 1; s.linkDest = { destMap, x, y }
    SendRaw(zone, 0x180E NC_MAP_LINKRESERVE_ACK { ref[6], payload[0x1d .. 0x3a] })   # back to the same zone
    # the zone then sends the client to the new zone (client LinkFrameWork), whose 0x101C gets the new position

0x180B left the zone for a link { u16 wmHandle, u32 charNo }:   @ FUN_00429c90
    if CHARDATA.charNo == charNo: s.linking = 1

0x180C map login done { u16 wmHandle, u16 ?, u32 charNo @+4, char map[12] @+8, u8 zoneNo @+0x14, …, u8 flag @+0x2e }:   @ FUN_0042d8d0
    if CHARDATA.charNo != charNo: return
    s.zoneNo = zoneNo; s.linking = 0; CHARDATA.map = map
    refresh party / raid / guild / academy / friends / instance state for the new map (FUN_00436b90, 430a30, 41b7d0,
        41b050, 41b200, 4132c0, 41c3b0, 436900, 4360f0, 430bc0, 435170, 434c20, 430e30, 431cd0, 452b60, 432ce0, 432e10 → W02–W04)
        (raid map: may send 0xB016 to members and 0xB017 to all zones; W02)
    attendance: if flagged, FUN_0043a7f0(charNo)
    g_InstanceMaps.OnEnter(s, map)                         @ FUN_00456b20
    send client 0x182A (1 byte)                            # client GameFrameWork: Raemi NPC pop-up refs (meaning not traced)
    if pending friend points p (FUN_00433d30): send client 0x5425 { u16 p }; clear     # "You have received %d friend point(s)."
    SendRaw(GameLogDB, 0x040F { charNo, map[12], …, 0x28 bytes from the payload })    # map-entry log

0x0C31 NC_USER_POSSIBLE_NEW_CONNECT_CMD { …, u16 wmHandle @+6, u32 charNo @+8 }:   @ FUN_0042c1c0
    if s.playingCharNo == charNo: s.playingCharNo = -1     # the zone finished the character logout; 0x1001 allowed again
    else log "ERROR - CParserZone::fc_NC_USER_POSSIBLE_NEW_CONNECT_CMD - WorldData(…)"
```

End-to-end, first login and map change:

```
client 0x1001 → WM: CharDB 0x1004 → CharDB 0x1007…0x101B (cached) + 0x1005
WM: CharDB 0x1036, GameLog 0xC806, client 0x1003 {zone ip, port}, ticket = 1
client → zone 0x1801 → zone → WM 0x104B (ticket check) → 0x104C
                     → zone → WM 0x101C → 0x101F…0x1130 blobs + 0x101D → zone → client 0x1038… + 0x1802
zone → WM 0x180C (map login done) → client 0x182A
map change: zone A → WM 0x180D (dest stored, ticket = 1) → 0x180E → zone A tells the client → client → zone B 0x1801
            → 0x104B / 0x101C as above (with the reserved destination) → 0x180C
```

### 7.4 Character state saves (dept 16 and others; zone → WM cache)

```pseudo
0x400E base save { u16 wmHandle, u16 ?, u32 charNo @+4, u8 level @+0xc, u64 exp @+0xd, u32 @+0x15, map[12] @+0x1d,
                   u32 x @+0x29, u32 y @+0x2d, stats u16×4 @+0x4d.., u32×2 @+0x5d, u32 @+0x65, u16 @+0x69 }:   @ FUN_00429d40
    copy into CHARDATA (+0x19 level, +0x1a exp, +0x36, +0x42 map, +0x4e x, +0x52 y, +0x22..+0x2e, +0x57, +0x5b)
0x4017 { u16 wmHandle, u64 money @+2, u32 @+0xa, u32 charNo @+0xe }: CHARDATA +0x3a money, +0x36   @ FUN_0042a3f0
0x1073 { u16 wmHandle, u32 charNo, u64 exp }: CHARDATA.exp (by handle, or by charNo)                 @ FUN_0042b320
0x1058 { …, u16 wmHandle @+6, u8 class @+8 }: SHAPE byte bits 2-6 = class                         @ FUN_00429bc0
0x10C1 { …, u16 wmHandle @+6, u8 v @+8 }: single-option blob byte +8 = v                           @ FUN_00429c30
0x4015 NC_CHARSAVE_2WLDMAN_GAME_CMD { u16 wmHandle, u32 charNo, u16 partyNo @+7, u16 raidNo @+9, u32 @+6?, u8 @+0xa }:   @ FUN_0042a230
    if partyNo / raidNo differ from the WM registries (DAT_0055e128 / DAT_006bdf60): log "ERROR - … nPartyNo|nRaidNo : (%d/%d)" and use the WM's
    store into the +0x638 game block
0x083D { u32 charNo }: if CHARDATA level (+0x64) != 0: game block byte = 1                         @ FUN_0042b860
other dept-16 opcodes: store the blob given in §6.3
```

### 7.5 Level change

```pseudo
0x1074 NC_CHAR_LEVEL_CHANGED_CMD { u16 wmHandle, u32 charNo @+2, u8 level @+6 }:   @ FUN_0042e160
    s = by handle, else by charNo; none: log "ERROR - fc_NC_CHAR_LEVEL_CHANGED_CMD Not found nCharNo=%d, NewCharLevel=%d, wmhandle=%d"
    CHARDATA.level = level; update party member level; FUN_004355a0 (W02)
    guild member level; guild academy member level (W03):
        level == 60: SendRaw(CharDB, 0x9851 { …, charNo, academyGuildNo, name, class, level })   # academy graduation (inferred)
        level < 60 with a reward row (DAT_006c50d4): SendRaw(CharDB, 0x9854 { handle, academyGuildNo, reward(8 bytes) })
    friends/other list update (FUN_00451930, FUN_00451290)
    Send GameLogDB 0xC808 { u32 userNo, u32 charNo, u8 level }
```

### 7.6 Other zone messages in scope

```pseudo
0x0815 / 0x0816 ping test: stamp time, forward (0x3a bytes) to the OPTool at payload+4     @ FUN_0042b180 / FUN_0042b250
0x082A { u32 a, u32 b, u16 c }: SendRaw(AccountDB, 0x082F NC_MISC_SERVERPARAMETER_REQ { u16 zone session handle, u32 a, u32 b, u16 c })   @ FUN_0042b740
AccountDB 0x0830 { u16 zoneHandle, u32, u16, u8 }: SendRaw(zone, 0x082B NC_MISC_CONNECTFROMWHERE_ACK {…})   @ FUN_00407fd0
0x0837 { u32, u32, u8, u16 }: SendRaw(AccountDB, 0x0838 { …, u16 zone handle, … })        @ FUN_0042b7d0
AccountDB 0x0839 { u32 userNo?, u32 charNo @+4, u8, u16 result @+9, u16 zoneHandle @+0xb, u16 @+0xd }:   @ FUN_00408050
    if result == 0x1541: broadcast to all clients 0x6402 { u8 2, char text[] = character name }   # announcement (inferred)
    SendRaw(zone, 0x083A { … })
0x0866 { u32 charNo, char[20] }: if level 50..100: Send CharDB 0x0868                        @ FUN_0042c3b0   (W04)
0x0824 NC_MISC_WHSHANDLEFIX_CMD { …, u32 charNo @+2, u16 whsHandle @+6, u8 flag @+8 }:   @ FUN_0042b550
    if the handle's session does not hold charNo but the character is found by number:
        SendRaw(zone, 0x0825 NC_MISC_WHSHANDLEREPAIR_CMD { …, u16 correct wmHandle }); log "FIX - … FIND"
    counters nCountOK / nCountRepare / nCountFail in the logs
0x6401 NC_ANNOUNCE_Z2W_CMD { u8 type, u8 len, char text[] }:   @ FUN_0042ab50
    broadcast to all clients 0x6402 { u8 type, u8 len, text }   (FUN_00437b40; type 11 = second flag set, inferred: in-game only)
0x7C14 NC_ZONE_PRISON_GO_ACK: prison by GM; result 0xDC0 → CharDB 0x7C0B (0x16C bytes) or a 0x7C02 reply (0xD82/0xD88) to the GM client   @ FUN_0042dea0  (W04)
```

---

## 8. AccountDB / AccountLogDB / GameLogDB links (rest)

```pseudo
AccountDB 0x0C27: accepted, no action                     @ FUN_00407fb0
AccountLogDB 0x0809 user statistics request:             @ FUN_00408f50
    count in-game characters per class (0..63) from each session's SHAPE byte
    Send AccountLogDB 0xC811 { u32 currentUsers, u8 worldNo }
    SendRaw(AccountLogDB, 0x080A { u8 worldNo, u16 currentUsers, u16 perClass[64] })
AccountLogDB 0x082D NC_MISC_EVENT_L20_DB_ACK { u16 handle, …, u32 charNo @+7, u16 code @+0xb }:   @ FUN_004091d0
    if code != 0x1289 and charNo matches: SendRaw(s, 0x082E { u8 0, u16 code })
AccountLogDB 0x8008 / 0x800A / 0x800C (user report results): forward to the client as 0x8002 / 0x8004 / 0x8006   @ FUN_004092e0 / 4090c0 / 409130
    (0x8008 code 0xF40 also stamps s+0x1dfa8 = GetTickCount(); report flow belongs to W04)
GameLogDB: only the handshake and heartbeat are registered.
```

---

## 9. OPTool (CParserOPTool)

Same role as the Login server's OPTool parser (login §5.4).

```pseudo
0x0802 S2SCONNECTION_REQ: to must be 5 and key == to + from; reply 0x0803 { echo, 0 }; session.state = 1   @ FUN_00424e20
0x2801 → 0x2802 connection list: AccountDB, AccountLogDB, CharDB, GameLogDB, Login, then every client(?)/zone/OPTool
        session that is up: { u8 type, u8 world, u8 zone, u32 connectedAt packed y/m/d/h/m/s }   @ FUN_004251a0
0x2803 → 0x2804 { u16 0x0600 }; g_Shutdown = 1   ("SERVER STOP - fc_NC_OPTOOL_CLOSE_SERVER_REQ")   @ FUN_00425860
0x2807 NC_OPTOOL_CONNECT_BRIF_REQ → 0x2808                          @ FUN_00425950
0x280E { i32 limit }: g_Clients.userLimit = limit (-1 if above capacity); Login_WorldStatus(force)   @ FUN_00426390
0x2827 → 0x2828 user lookup { u32 userNo } → { u32 userNo, u8 found, char userId[256], u32 charNo, char name[20], char map[12] }   @ FUN_00426c50
0x2829 NC_OPTOOL_KICK_USER_REQ { u32 userNo } → 0x282A (same layout as 0x2828):   @ FUN_00426e20
    if found: Broadcast zones 0x0C16 { userNo }; SendRaw(s, 0x0C17 { u16 0x68F }); s.closeReason = 0x790; s.state = 3
0x281F { u32 v }: FUN_004382d0(&g_Clients, v)                       @ FUN_00426730
0x280B: g_InstanceMaps FUN_00455550(payload)                        @ FUN_00425d30
0x2010 { u8 ?, u8 len, text }: broadcast 0x2011 { u8 len, text } to all clients   @ FUN_00425c90   (client pre-game scenes ignore 0x2011)
0x2811 NC_OPTOOL_KQ_DELETE_CMD, 0x2826 ("--- NO SUPPORT - KQ ALL RESET---"), 0x2824 (→ 0x7419, 0x7477 guild), 0x9425 (→ 0x9432/0x9418),
0x384E → 0x384F, 0x2809 → 0x280A, 0x280C → 0x280D, 0x280F → 0x2810, 0x2815 → 0x2816, 0x281B → 0x281C, 0x281D → 0x281E,
0x2820 → 0x2821, 0x2822 → 0x2823 ("CurrentTime-%d"), 0xD001…0xD009 (GM events), 0x0813/0x0814/0x0815/0x0816 ping tests:
    feature queries for W02–W04; not reconstructed here
0x0828, 0x2805, 0x281A, 0x282B: accepted, no action
```

---

## 10. Client cross-check (summary)

| WM → client | Client scene / handler | Client behaviour |
|---|---|---|
| 0x0807 seed | LoginWorldNet `FUN_00471980` | set cipher seed, send 0x0C0F |
| 0x0C14 avatar list | LoginWorldNet `FUN_00471720`, CHairShop `FUN_00629720` | store handle + list, go to character select |
| 0x0C15 {u16} | LoginWorldNet `FUN_008c58b0` | leave the scene (code not read): sent with 0x44 (bad key) and 0x46 (DB error) |
| 0x0C17 {u16} | Account/CharSelect/CharCreate | only 0x683 (double login) is acted on; 0x68F (OPTool kick) shows nothing special |
| 0x0C34 {u16, token[32]} | CharSelect `FUN_004766a0` | 0x1E58 → keep token for the Login reconnect |
| 0x1002 {u16} | CharSelect `FUN_004769d0` | 0x141 world server, 0x142/0x143 map server, 0x144 empty slot, 0x582..0x595 data errors, else "The Map is under maintenance" (0x145, 0x31EB) |
| 0x1003 {ip[16], port} | CharSelect `FUN_00476190` | connect to the zone |
| 0x1110 / 0x111D | CharSelect | tutorial question / tutorial helpers |
| 0x1404 / 0x1406 | CharCreate | create failed / created |
| 0x140A / 0x140C | CharSelect | delete failed (0xC6 from the WM itself) / deleted |
| 0x1410, 0xB40C | CharSelect | rename results |
| 0x1079 / 0x107D | CHairShop | beauty shop |
| 0x080E | Net pre-dispatch | server clock |

WM disconnect reasons (`closeReason`, sent to AccountDB/AccountLog in 0x0C11/0x0722, not shown to the client):
0x780 normal logout, 0x785 double login, 0x787 packet while not alive, 0x788 world-login refused or DB error,
0x790 OPTool kick. None of these has an entry in the client error table.

---

## 11. Not reconstructed / uncertain

- Feature callees of character login/logout and map login (party, raid, guild, academy, friends, instances, chat ban,
  attendance, reports) are only listed by address; W02–W04 own them.
- `g_InstanceMaps` (`DAT_0055e15c`) is our name; the redirect test (`FUN_00452580`) was not followed. Its use of
  AVATAR +0x5b/+0x5f/+0x73 suggests "instance map no longer valid → return map".
- AVATAR fields marked *(inferred)* and the CHARDATA layout beyond the offsets the WM touches belong to D02.
- 0x0808 field meaning on the Login side (how the status byte is derived) is in `login-server.md` §5.3, not re-read.
- The 6-byte `ref` that zones put in front of 0x101C/0x104B is echoed only; its meaning is Z01's.
- `FUN_004382d0` (after a character delete and OPTool 0x281F) and `FUN_00437d50` (Login kick) were not opened.
- OPTool queries other than those listed, and client handlers 0x0840 (→ CharDB 0x0841), 0x0846 (→ CharDB 0x0847
  NC_MISC_SET_CHAT_BLOCK_SPAM_FILTER_DB_CMD), 0x085F (gold-spammer report → 0x0860 {0x2160 ok, 0x2161 "Can't find the
  character", 0x2162 "Gold spammer has reported", 0x2163 "already reported"}), 0x0861 (chat-ban request → CharDB 0x0863
  or client 0x0862 {0x216B}), 0x10F1 (attendance reward → CharDB 0x10F3 or error 0x2C12/0x2C13) are summarised only;
  they belong to W04.
- No capture was available; nothing here is *(captured)*.
