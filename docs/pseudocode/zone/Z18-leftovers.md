# Zone: leftovers of finished zone items from Z09's coverage boundary (Z18)

Source: `Files/Server/2016/w00_Zone00/5ZoneServer2.exe`, read in the PDB export
(`python3 -I tools/protocol-re/clean.py re-data/exports/zone-pdb - <addr> …`). All class, method and member names are
from the 2016 zone PDB *(pdb2016)* unless marked. Vtable slots were resolved with `tools/protocol-re/rtti.py` over the 2016
exe. The list of functions is `docs/knowledge/Z09.md` §3 (rows of `Z09-world.md` §31.2); one section per owner item,
each linking the owner's section the function plugs into. Corrections of the owners' text: `docs/knowledge/Z18.md`.

Sections: §1 Z01 (core), §2 Z02, §3 Z03, §4 Z04, §5 Z06, §6 Z07, then bugs, uncertain, coverage boundary.

---

## 1. Z01: player login, handles, sessions, diagnostics, SHN boxes

### 1.1 Login-burst helpers of `sp_NC_MAP_LOGINCOMPLETE_CMD`

Called in this order from 0x1803 `sp_NC_MAP_LOGINCOMPLETE_CMD` FUN_00443390 (Z01 §6), except `sp_RegistNumberVarification`
(at its start) and `sp_RemoveField` (near its end).

```pseudo
ShinePlayer::sp_RegistNumberVarification(p)                          @ FUN_00551950
    send GameDB 0x10B3 NC_CHAR_REGNUM_VARIFICATION_REQ {               # 0x1a bytes = PROTO struct (pdb2016)
        u16   zonehandle  = p.handle (+4)
        Name5 zone_charid = so_CharName(p)   (vt 0x56c)
        u32   charregnum  = so_GetCharRegistNumber(p) (vt 0x344) }
    # packet too long → AssertFail "…sp_RegistNumberVarification : Packet Too Long" (cannot happen)
    # CharDB side: D02 §7.1 (`usp_Char_chkCharNo`)

ShinePlayer::sp_ConnectFromWhere(p)                                  @ FUN_0043f1f0
    if p.sp_CharData.toclient.basedata.adminlevel (+0x7fa1) ≠ 0:
        so_ply_Notice(p, sprintf("From %d.%d.%d.%d", p.sp_LoginIP[0..3] (+0x2a7d0)))   (vt 0x784)
    p.sp_ConnectFrom (+0x2a7d4) = 0
    # no packet to the WM: Z01 §6 says "WM 0x082A" (correction in knowledge Z18). A GM sees the IP the zone
    # recorded at accept (so_ply_LoginIPSet, §1.3). 0x082B (Z01 §9) later sets sp_ConnectFrom again.

ShinePlayer::sp_GhostBan(p)                                          @ FUN_0043f3d0
    walker = AxialListGhostBan { algb_GhostName = so_CharName(p) }   # Name5, 20 bytes
    so_AllInMap(p, walker, 0)                                         # every object of p's map (Z01 §3.2)
AxialListGhostBan::ali_Work(walker, sender, o)                       @ FUN_0043c9f0
    if o and o.so_ObjectType() (vt 0x4d0) == 2 (player) and so_CharName(o) == algb_GhostName:
        so_Logout(o)                                                  # FUN_0054b780: o leaves everyone's sight (0x1805)
    return 1 (continue)
    # the walker does not skip p itself (see §8)
AxialListGhostBan::~AxialListGhostBan                                # FUN_0043c9e0, iterator base dtor only

ShinePlayer::sp_KeepFromDoubleLogin(p)                               @ FUN_0043cc90
    list = shineobjmanager.som_ListContainer[2] (players)
    if list == null: write a line to MoreDisconnectLog; return
    for each live player o in list with o.handle ≠ p.handle:
        if so_GetUserRegistNumber(o) (vt 0x348) == so_GetUserRegistNumber(p):      # same account
            MoreDisconnectLog: a line, then so_GetCharRegistNumber(o) (vt 0x344) "%d"
            so_banning(o, 1)   (vt 0x5fc, FUN_00558b70, Z01 §8.3)                   # the older object is removed
    # so the same account can hold only one player object per zone; the newest login wins

ShinePlayer::sp_RemoveField(p)                                       @ FUN_00440b40
    # despite the name: ends the abstates that the new map refuses
    if p.so_Field (+0x7a) == null: return
    list = so_mobile_AbstateList(p) (vt 0x52c, AbstateListInObject)
    for each element e (AbstateElementInObject) of list:
        info = abstateidentarray[e.aeo_Index].info
        if info and FieldMap::fm_IsRefuseAbstate(field, info+0x22):
            e.aeo_Flag.f_SystemRemove = 1; e.aeo_Tick.terminate = clockwatch.cw_CurrTick   # ends on the next abstate tick (Z03 §6)
```

| Function | What it does |
|---|---|
| `ShinePlayer::<unnamed-type-sp_Item>` ctor FUN_00549820 | builds `p.sp_Item` (+0x7fd8, 0xf300 bytes): `CharacterInventory itembag` (`ItemEquipment`, `ci_Inventory`, `ci_QuestBox`, `ci_MiniHouse`, `ci_ActionBox`) and `invenlocklist` (+0x7ad0); called by the player ctor FUN_0055bc80. Inventory classes: Z04 §1 |
| `ShinePlayer::sp_LoginInit` FUN_00440d80 | documented in Z12 §6.9 (end of the login data) |
| `ShinePlayer::sp_NextSaveExperience` FUN_0042d6f0 | documented in Z12 §5.3 (next experience-save point) |

### 1.2 Object handles: `ShineObjectHandleUnion`

`ShineObjectManager::som_AllocObject` FUN_0054fe20 turns a pool index into the
object's handle with one setter per class. Each returns `0xFFFF` (and leaves `sohu_Handle` unchanged) when the index is
too large, else sets and returns `sohu_Handle = index + base`. The bases equal Z01 §4.2's handle table.

| Setter | Address | Max index | Base |
|---|---|---|---|
| `sohu_SetMobHandle` | FUN_00548e00 | 7999 | 0 |
| `sohu_SetPlayerHandle` | FUN_00548e30 | 1499 | 8000 |
| `sohu_SetMiniHouseHandle` | FUN_00548e60 | 999 | 9500 |
| `sohu_SetDropItemHandle` | FUN_00548e90 | 2999 | 10500 |
| `sohu_SetAxialHandle` | FUN_00548ec0 | 3583 | 13500 |
| `sohu_SetNPCHandle` | FUN_00548f20 | 255 | 17084 |
| `sohu_SetBanditHandle` | FUN_00548ef0 | 2047 | 17340 |
| `sohu_SetEffectHandle` | FUN_00548f50 | 999 | 19388 |
| `sohu_SetDoorHandle` | FUN_00548fb0 | 999 | 20638 |
| `sohu_SetServantHandle` | FUN_00548fe0 | 499 | 21638 |
| `sohu_SetMoverHandle` | FUN_00549010 | 999 | 22138 |
| `sohu_SetPetHandle` | FUN_00549040 | 1499 | 23638 |

The magic-field range (20388–20637) has no setter in this list; 23138–23637 is unused by every setter.

### 1.3 Client sessions: accept, seed, session-mode filter, per-IP group

`ZoneServer::zs_connect` FUN_005aa840 (summarised in Z09 §1.5) handles each accepted socket
(`CSocket_Acceptor::GetAccepted` FUN_00652980, S02 §1.4) by listen type. The client branch in detail:

```pseudo
zs_connect, accepted socket with UserData 0x14 (client port):        @ FUN_005aa840
    s = ClientSessionManager vt[0](socket, addr)                      # take a free ClientSession; none → shutdown + closesocket
    ClientSession::cs_SetSessionMode(s, BEFORE_MAP_LOGIN_REQ (0))      @ FUN_0045b180   (cs_sessionMode +0x104)
    ClientSession::cs_SetActiveTimeToCurrent(s)                        @ FUN_0045b1a0   (cs_activeTime +0x108)
    ClientSession::cs_SetBoolClosingSession(s, 0)                      @ FUN_0045b1e0   (cs_bClosingSession +0x10c)
    ClientSessionManager::csm_AddClientSessionToIPGroup(mgr, s)        @ FUN_0045c720   (below)
    s.m_Packet reset (vt 0x2c); m_Status = CONNECTED; m_Connected_Server_ID = 0x14; m_LastReceiveTime = now;
    m_LastHeartBeatSendTime = 0
    p = som_AllocObject(type 2 player) (FUN_0054fe20)
        none → AssertFail "ZoneServer::zs_connect : ShinePlayer full"; s.m_Status = 3 (closing); next socket
    p.so_FirstActionAfterSocketConnect()   (vt 0x30c, ShinePlayer FUN_00554870 → … → ShineObject FUN_0054b670)
    p.so_SetSocketSession(s) (vt 0x2f0); s.cs_clienthandle (+0x102) = p.handle
    seed = p.so_EncSeedSet() (vt 0x2f4, FUN_0054f660):
        g_seed += 1; if g_seed ≥ PacketEncrypt::pe_encryptlen (499): g_seed = 0
        p.sp_Encryption.pe_point = pe_mark = g_seed mod 499            # decrypt index for client→zone packets
    p.so_ply_LoginIPSet(addr bytes 1..4) (vt 0x93c, FUN_005aa050) → p.sp_LoginIP[4] (+0x2a7d0)
    Socket_Register_To_IOCP(s) (FUN_005a6700, S02 §1.6) fails, or
    ClientSession::Send_NC_MISC_SEED_ACK(s, seed) fails:                @ FUN_0045b120
        raw 5 bytes { u8 len 4, u16 0x0807 NC_MISC_SEED_ACK, u16 seed }   # (captured): protocol README §1.4, "sent on accept"
        → s.m_Status = 3 (closed by zs_disconnect)
```

So the seed reaches the client **unasked at accept**, from the counter `seed` (DAT used only by `so_EncSeedSet`). The
0x0806 handler `sp_NC_MISC_SEED_REQ` FUN_00451a30 that Z01 §5.1 documents is effectively dead: see the filter below
and Z18-B2 (correction in knowledge Z18).

```pseudo
ShineObject::so_FirstActionAfterSocketConnect(o)                     @ FUN_0054b670
    o.so_Field = null                                                 # base of the chain; the ShinePlayer version
                                                                      # FUN_00554870 (cited by Z12 §1.2, Z11) resets the
                                                                      # per-connection player state first, incl.
                                                                      # ProtocolLogger::pl_Clear (§1.5)
```

**Session-mode filter.** `ClientSession::zbs_Parsing` FUN_004fb9f0 (Z02 §1 documents only its dispatch) decrypts the
packet (`PacketEncrypt::pe_FromClientToServer` with the player's `sp_Encryption`, vt 0x4a8), drops everything once
`sp_WillDisconnect` is set, then filters by `cs_sessionMode` (enum `ClientSession::SessionMode` *(pdb2016)*):

```pseudo
ClientSession::zbs_Parsing(s, p, sessionArg)                          @ FUN_004fb9f0
    p == null: AssertFail "ClientSession::zbs_Parsing : sp not entry!!!"; return
    decrypt; if p.sp_WillDisconnect: return
    mode = s.cs_sessionMode
    mode 0 BEFORE_MAP_LOGIN_REQ:
        0x1801 NC_MAP_LOGIN_REQ → mode = 1; dispatch
        anything else → dropped silently (no log, no cut)
    mode 1 BEFORE_MAP_LOGINCOMPLETE_CMD:
        0x1803 NC_MAP_LOGINCOMPLETE_CMD → mode = 2; csm_RemoveClientSessionFromIPGroup(mgr, s); dispatch
        0x0805 NC_MISC_HEARTBEAT_ACK → dispatch
        0x200B, 0x304D, 0x3848 NC_PARTY_MEMBERINFOREQ_CMD → log "…Invalid sequence protocol(Skip Only) (Dept/Cmd=…"
        any other → log "…Invalid sequence protocol (Dept/Cmd=" (registered opcode) or "…Not registered protocol
                    (Dept/Cmd=" (pft_IsRegisteredProtocol false)
        log line (InvalidSessionCutLog): dept/cmd, SessionAuthMode, IP_Addr "%d.%d.%d.%d" (cs_GetRawIPAddress
            FUN_0045b1c0 = &socket peer address), nUserRegNo, nCharRegNo, nWMSHandle of the player
        # (original bug) Z18-B3: the packet is dropped but the session is **not** closed, although the log is
        # named "InvalidSessionCut"; Login (L01 §2.6) and WM (W01 core, "Invalid Client Session") cut it
    mode −1 INACTIVE_MODE: as "any other" above
    mode 2 AFTER_MAP_LOGINCOMPLETE_CMD: every packet → sp_LastProtocol(p, pkt); handler table [cmd][dept]
```

**Per-IP group of sessions that have not finished map login.** `ClientSessionManager.csm_SessionGroupByIPArray`
(+0x1c, a `vector` of pointers to 10-slot arrays of `ClientSession*`; the group key is the peer IP at session +0x34,
compared through slot 0):

```pseudo
csm_AddClientSessionToIPGroup(mgr, s)                                @ FUN_0045c720
    g = the group whose slot 0 has s's IP
    none: g = new ClientSession*[10] (all 0); g[0] = s; push_back(g); return 1
          (allocation failure: AssertFail "Cannot memory allocation for array of session which is not certified yet."; return 0)
    put s in the first empty slot i of g
    if i == 9 (s is the 10th) or no slot was empty:
        every non-null g[k]: g[k].cs_bClosingSession = 1; g[k] = 0         # all 10 sessions of that IP are cut
        erase g from the vector                                            # (original bug) Z18-B1: g is not freed
    return 1
csm_RemoveClientSessionFromIPGroup(mgr, s)                           @ FUN_0045c620
    g = group with s's IP, else return 0; i = index of s in g, else return 0
    shift g[i+1..9] down; g[9] = 0
    if g has no session left: delete[] g; erase it
    return 1
    # callers: zbs_Parsing at 0x1803 (the session is "certified"), zs_disconnect FUN_005abb60 on every cut
```

Effect: at most 9 connections from one IP may sit between accept and 0x1803 at once; the 10th closes all 10
(`zs_disconnect` cuts sessions whose `cs_bClosingSession` is 1, Z09 §1.5). A session cut this way is no longer in
any group, so its later `csm_Remove…` returns 0.

### 1.4 OPTool and zone-ring session glue

```pseudo
OPToolSession::opts_ActivSession(sess, socket, sockaddr)             @ FUN_004c7db0
    sess.m_Packet reset (vt 0x2c of +0xe0); socket handle (+0x2c) = socket; copy the 16-byte sockaddr (+0x30..+0x3f);
    m_Status (+4) = 2; return sess
    # identical code serves the zone-ring listen socket: zs_connect calls it on `zonelisten` (ZoneListenSession) too
zs_connect, UserData 6 (zone ring, from the previous zone, Z01 §10):
    opts_ActivSession(zonelisten, …); CONNECTED; m_Connected_Server_ID = 6; times reset; Socket_Register_To_IOCP;
    failure → _DebugMessageNew "%s"; CLOSEING
zs_connect, UserData 8 (OPTool):
    opts_ActivSession(optoolsock, …) (null → closesocket); CONNECTED; m_Connected_Server_ID = 8; times reset
    o = optoollist.take() (vt 8); none → CLOSEING
    OPToolObject::opto_SetSocketSession(o, sess)                       @ FUN_004c7d40
        o.opto_SocketSession = sess; o.opto_ListPacket = clockwatch.cw_CurrTick
    Socket_Register_To_IOCP; OPToolSession::opts_ConnectReady(sess):   @ FUN_004c7d60
        raw 3 bytes { u8 len 2, u16 0x0801 NC_MISC_S2SCONNECTION_RDY }  # the OPTool then sends 0x0802 (Z01 §3.3)
    any failure → _DebugMessageNew; CLOSEING
```

Heartbeat of the server-to-server sessions (S02 §1.10 leaves the lifecycle to Z01):

```pseudo
ZoneBaseSessionManager::ProcHeartBeat(mgr, iocp)                     @ FUN_005a6a40   (from zs_disconnect)
    for each active session: if session.vt[0](30) == 0: CSocket_IOCP::CloseUseIOCP(session.m_SocketIOCP, iocp)
ZoneBaseSession::CheckHeartBeat(s, _)                                @ FUN_005a67c0   (vt[0])
    if s.m_Status == EMPTY: return 1
    if now − m_LastReceiveTime < 30000 ms: m_LastHeartBeatSendTime = 0; return 1
    if m_LastHeartBeatSendTime == 0: m_LastHeartBeatSendTime = now; return CSocket_IOCP::Send(3-byte 0x0804 HEARTBEAT_REQ)
    return now − m_LastHeartBeatSendTime < 180000                     # 30 s silence → 0x0804; 180 s more → close
    # the argument (30) is not used
```

### 1.5 Socket, packet and server-info functions documented elsewhere

| Function | Address | Where documented |
|---|---|---|
| `CPacket::GetWriteDataPtr` / `GetWriteableBufferSize` | FUN_00650280 / FUN_00650270 | S02 §1.7 and the zone column of S02 §1.9 |
| `CSocket_Acceptor::GetAccepted` | FUN_00652980 | S02 §1.4, §1.9 (main-loop side: §1.3 above) |
| `CSocket_IOCP` Close / CloseUseIOCP / Receive / Shutdown | FUN_0064f690 / FUN_0064f5f0 / FUN_0064f410 / FUN_0064f530 | S02 §1.5, §1.9 |
| `ZoneBaseSession::Socket_Register_To_IOCP` / `Connect` | FUN_005a6700 / FUN_005a68b0 | S02 §1.6 |
| `ZoneIPContainer::zipc_Store` | FUN_005a9640 | S02 §4.4 |
| `CServerInfo::ReadServerInfo` / `GetServerInfo` | FUN_0064d0f0 / FUN_0064d420 | Z10 §1.1, S02 §2.7 |
| `ZoneServer::zs_GetServerGroup` FUN_005a9950 | returns `zs_serverinfo.servergroup`; callers `fc_Load` FUN_004655f0, the GT observer, `so_LinkTo` (Z11 cites it) |
| `ZoneServer::zs_mechineinfo` FUN_005a9910 | returns `&zs_serverinfo.serverinfo` (the `CServerInfo`); callers `fc_MakeField` FUN_004650a0, `so_LinkTo` FUN_0049ad30 |

```pseudo
ZoneServer::zs_Getportinfo(zs, out, type)                            @ FUN_005a9960   (caller zs_ServerConnect FUN_005a9b50, Z01 §3.3)
    try GetServerInfo(out, type, myWorld, myZone, myServerID), then (myWorld, myZone, 0), then (myWorld, 0, myServerID),
    then (myWorld, 0, 0); return whether one matched          # most specific ServerInfo row first

ProtocolPacket::pp_NetCommand(pp, dept, cmd)                         @ FUN_00401280
    pp.pp_Buffer→protocol = (dept << 10) ^ (cmd & 0x3ff); return pp.pp_Buffer
    # callers: NPCAction::DamageAbsorbAction::exe FUN_005c11a0, Send_SETITEMHEALEFFECT FUN_005cfbb0
```

### 1.6 Diagnostics and logging

| Function | Address | What it does |
|---|---|---|
| `AssertClass::operator()(cond, text, a, b)` | FUN_00401110 | `cond == 0` → `ac_AssertFail(text, a, b)`; returns `cond == 0` |
| `FunctionEntarance::FunctionEntarance(code, name, flag)` | FUN_00402880 | RAII profiler scope: `fe_FunctionCode = name`; `pr_Entrance(name)`; pushes `name` / `flag` on `funcallanalizer` (the same three steps every function inlines); used by `CQuestZone::QuestNext` FUN_005bdef0 and `NeighborhoodChecker::ali_Work` FUN_005c2fe0 |
| `FunctionProfiler::PerformanceRecorder::pr_Report` | FUN_004680d0 | writes `FunctionPerformance.txt`; documented in Z11 §4.5 (`&profile`) |
| `DebugLogging::dl_MakeFileName` | FUN_00419100 | log file name `"%s%s%02d.txt"` from the log's path, `YYYYMMDD` and a number; empty when logging is off; Z11 §1.5 |
| `GetCurrentTimeString2(utc)` | FUN_0064f110 | `GetLocalTime` (0) or `GetSystemTime`; returns the static `sCurrentDateTime` = `"%04d-%02d-%02d"` + `" "` + `GetTimeFormatA("tt hhmmss")` |
| `MiniDumper::MinidumpCallStack(ex)` | FUN_0064e5f0 | from `MiniDumper::TopLevelFilter` FUN_0064e810 (Z09 §30.1): file `<exe path>` + separator + `GetCurrentTimeString2(0)` + `CallStack.txt`; writes `GetFaultReason(ex)`, a dashed line and up to 14 frames (`GetFirstStackTraceString` / `GetNextStackTraceString`, one per line); open failure → `"EXCEPTION - Failed to Call Stack file '%s' (error %d)"` |
| `ProtocolLogger::pl_Clear` | FUN_005528a0 | zeroes the opcode of all 16 entries of `pl_NetCommand[]` and `pl_Pointer = 0`; the player's last-packets ring (`sp_LastProtocol` writes it), cleared at socket connect (FUN_00554870) |
| `StringMaker::Maker::operator<<(char*)` | FUN_0058dc10 | appends while the 1 KB buffer (`m_Buffer`, `m_Pointer`) has room, else drops the whole string |
| `…operator<<(char)` | FUN_0058dcb0 | appends one char if `m_Pointer + 2 < 0x400` |
| `…operator<<(int)` | FUN_0058dd40 | `sprintf("%d")` then the `char*` form |
| `…operator<<(Name3*)` | FUN_0058de10 | copies the 12-byte name into the next `namestring` ring buffer, NUL-terminates, appends |
| `…operator<<(Finisher&)` | FUN_0058dfd0 | sends the built line: `fin.f_Admin.so_ply_Notice(maker)` (vt 0x784); the GM-answer path of Z11 §5.7 |

### 1.7 SHN boxes and fixed-length strings

`BinaryDataBox<T>::bdb_ReadData(file)` = `CDataReader::Read(file, DataVersionKey, rowSize)` (FUN_0062a9e0, knowledge Z01
"SHN loader check"); failure → `AssertFail "BinaryDataBox<T>::bdb_ReadData : readfail"`, a `"Code:%X:%d\tSHN:%X:%d"`
line, `ShineExit`.

| Function | Address | What it does |
|---|---|---|
| `BinaryDataBox<GradeItemOption>::bdb_ReadData` | FUN_00648bd0 | key 616 (0x268), row 0x3e = 2017 PDB `GradeItemOption` (`ItemIndex[32]`, STR … MAPlus u16); caller `ItemDataBox::idb_Load` FUN_00649780 (Z01 §2.3 table list) |
| `BinaryDataBox<MapInfo>::bdb_ReadData` | FUN_0064eb40 | key 504 (0x1f8), row 0x4c = PDB `MapInfo`; caller `MapDataBox::mdb_Load` FUN_0064ebf0 (Z01 §2.3 table list) |
| `MapDataBox::operator[](id)` | FUN_00419440 | `id < mdb_maxmapid ? mdb_index[id] : null` |
| `MapBuffDataBox::mbdb_GetModeIDLvType(lv)` | FUN_00462870 | `ID_LEVEL_TYPE` → `ModeIDLvType`: EASY 0→0, NORMAL 1→1, HARD 2→2, `ILT_MAX` 3→NORMAL 1, else 3 (`MAX_MODEIDLVTYPE`); used by `sp_NC_MAP_LOGINCOMPLETE_CMD` and `sp_ReviveNow` FUN_0057d290 to pick the map buff of an instance's difficulty |
| `Name3::Name3(s)` / `operator=(s)` | FUN_00418e00 / FUN_00418e30 | zero 12 bytes, `strncpy(…, 12)` (no terminator when 12 long) |
| `Name3::operator!=` | FUN_00401000 | 3-dword compare |
| `Name4::Name4(s)` / `operator=(s)` / `operator==` | FUN_004566e0 / FUN_0049ad00 / FUN_004d1f90 | same for 16 bytes; `==` used by `sp_PetSystem_PlayerRoutine` FUN_004d2d20 |
| `Name8::Name8(s)` / `operator=(s)` | FUN_00418e50 / FUN_00427de0 | same for 32 bytes |
| `NameString::operator[](Name4*)` | FUN_0045b060 | next buffer of the `namestring` ring (`ns_point.value = (value+1) & mask`), copy 16 bytes + NUL, return it; for log lines (`so_LinkTo`) |

---

## 5. Z06: trade, booths, gambling (constructors)

| Function | Address | What it does / where it plugs in |
|---|---|---|
| `BoothManager::BoothManager` | FUN_0043b550 | the per-map booth search index (Z06 §2.1, FieldMap +0x1f0): two empty STL list heads (`bsm_StoreList`, `bim_ItemList`), `bim_nLastCreatedHandleNo = −1`; from both `FieldMap` ctors FUN_00466170 / FUN_004662e0 (Z11 cites it for `&booth…`) |
| `BoothManager::operator=` | FUN_00467500 | list-copies both lists and the handle counter; only from `FieldMap::operator=` FUN_00467580 |
| `BoothManager::~BoothManager` | FUN_0043b620 | clears and frees the item list (+0xc) and then the store list (FUN_0043b220, +0); from `FieldMap::~FieldMap` FUN_00465490 |
| `CGambleObject::go_Get_MaxEnterPlayerCnt` | FUN_00591ff0 | returns `go_nMaxEnterPlayerCnt`; read by the gamble-house TaiSai (`GDTSO_DiceTaiSai_Enter` FUN_00618890, `GDTSO_ClearDiceTaiSaiInfo` FUN_0061b490, Z06 §4.4) and by the loot dice game (`DiceGame::End` / `DiceThrow` / `Update`, `ShineDropItem::so_IsDiceGamePlay`, Z09 §11.6) |
| `StreetBoothBuy::StreetBoothBuy` / `StreetBoothSell::StreetBoothSell` | FUN_0058f390 / FUN_00590580 | base `StreetBooth` ctor + own vftable; the two booth objects at `p+0x294b8` / `p+0x29348` built by the player ctor FUN_0055bc80 (Z06 §2.1) |
| `TradeBoard::TradeBoard` | FUN_00427ee0 | `tb_opposit = null`; the player's board (`p+0x17d5f`, Z06 §1.1), FieldMap ctors and the static `so_deftradebrd` |

---

## 7. Original-server bugs

| ID | Owner / handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z18-B1 | Z01 `csm_AddClientSessionToIPGroup` FUN_0045c720 | when the 10th not-yet-logged-in session of one IP arrives, the 10-slot group is erased from the vector without `delete[]` | 40 bytes leaked per event (a flood from one IP leaks steadily) | `delete[] g` as `csm_Remove…` does |
| Z18-B2 | Z01 0x0806 `sp_NC_MISC_SEED_REQ` FUN_00451a30 | reachable only with session mode 2 and player mode 0 (mode mask 0x01), i.e. after a 0x1803 that bailed out before `mode = 1`; it then sends a new seed from its own counter `newseed` without moving `sp_Encryption` | in practice dead; if reached the client switches its XOR index and every later packet decrypts wrong | drop the handler (the seed is sent at accept, §1.3), or set `pe_point` as `so_EncSeedSet` does |
| Z18-B3 | Z01 `ClientSession::zbs_Parsing` FUN_004fb9f0 | in session mode 1 (and −1) an out-of-sequence packet is only logged to `InvalidSessionCutLog`; in mode 0 it is dropped silently | a client can send anything before 0x1803 without being cut | close the session, as Login and WM do |

## 8. Not reconstructed / uncertain

- `sp_GhostBan` (§1.1): `AxialListGhostBan::ali_Work` does not skip the caller, so whether `so_AllInMap` passes the
  logging-in player itself decides whether it logs itself out of sight. It runs late in the login burst, and nothing
  reports a missing self in practice, so the map walk probably skips the caller *(inferred)*. The walker's map
  function (`fm_BroadFunc.fm_fp_AllInMap1`) was not opened.
- `sp_KeepFromDoubleLogin`: the text of the "empty list" log line is a `"%.255s"` with a lost argument.
- `zs_connect`'s client path: the ClientSessionManager's take function (vt 0) was not opened; the pool size is Z01's.
- The three "skip only" opcodes of the session filter (0x200B, 0x304D, 0x3848) are those the 2016 client may send while
  loading; only 0x3848 has a name in `opcodes.json`.
