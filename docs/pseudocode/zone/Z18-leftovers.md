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

## 2. Z02: brief info, server menus, chat ban

### 2.1 The batched brief-info exchange: `BriefInfoExchanger`

Z02 §5.2 describes `so_ExchageBriefInfo` (the map-iterator callback of a full exchange: login complete, regen, teleport,
layer move, hide-except-me off, camera move) and the character batch; Z09 §9.6 the per-step appear / disappear. The
batches it fills are global objects (`briefchar`, `briefmob`, `briefitem`, `briefminihouse`, `briefabstate_char`,
`briefabstate_mob`, `briefmover`, `briefpet`, plus door / effect / magic-field ones): one packet buffer each, filled for
**one receiving player** and flushed when full and at the end of the exchange (`bixall_Send` FUN_0043fc80, Z09 §9.6).

| Batch (class, size) | Object kinds (Z02 §5.2) | Packet | Entry (2016 PDB struct, size) | Buffer | Max entries |
|---|---|---|---|---|---|
| `BriefInfoExchangeMob` (0x10f8) | 4 NPC, 5 mob, 10 servant | 0x1C09 NC_BRIEFINFO_MOB_CMD `{u8 mobnum, …}` | `PROTO_NC_BRIEFINFO_REGENMOB_CMD` 0x95 | 4321 | 28 |
| `BriefInfoExchangeItem` (0x1c8) | 1 drop item | 0x1C0B NC_BRIEFINFO_ITEMONFIELD_CMD `{u8 itemnum, …}` | `PROTO_NC_BRIEFINFO_DROPEDITEM_CMD` 0xf | 435 | 28 |
| `BriefInfoExchangeMiniHouse` (0x754) | 3 mini-house | 0x1C14 NC_BRIEFINFO_MINIHOUSE_CMD `{u8 minihouses, …}` | `PROTO_NC_BRIEFINFO_MINIHOUSEBUILD_CMD` 0x40 | 1856 | 28 |
| `BriefInfoExchangeMover` (0xfd4) | 11 mover | 0x1C1B NC_BRIEFINFO_MOVER_CMD `{u8 nMoverNum, …}` | `PROTO_NC_BRIEFINFO_REGENMOVER_CMD` 0x8b | 4031 | 28 |
| `BriefInfoExchangePet` (0x738) | 12 pet | 0x1C1D NC_BRIEFINFO_PET_CMD `{u8 nPetCnt, …}` | `PROTO_NC_BRIEFINFO_REGENPET_CMD` 0x3f | 1827 | 28 |
| `BriefInfoExchangeAbstate` (0x26fc) ×2 | `_char`: 2 player, 8 bandit; `_mob`: 4, 5, 10, 11 | 28 separate 0x1C19 NC_BRIEFINFO_ABSTATE_CHANGE_LIST_CMD | `{u16 handle, u8 count, ABSTATE_INFORMATION[count] (0xc)}` | 28 × 341 | 28 (29 written, §2.2) |

The mob / mover / pet init functions write the opcode into their buffer (`0x1C00 | 9`, `| 0x1b`, `| 0x1d`); the item and
mini-house opcodes come from the 2016 PDB struct names of their pointers (`bixi_Pointer` is a
`PROTO_NC_BRIEFINFO_ITEMONFIELD_CMD*`, `bixmh_Pointer` a `PROTO_NC_BRIEFINFO_MINIHOUSE_CMD*`; the write itself was not
located) and are confirmed by the client handlers below.

```pseudo
bixm_Exchange / bixi_Exchange / bixmh_Exchange / bixmv_Exchange / bixp_Exchange (batch, me, other)
        @ FUN_0043fe40 / FUN_004401a0 / FUN_004403e0 / FUN_00440690 / FUN_004407d0
    # me = the player the exchange runs for; other = the object the map walk found
    (mover, pet) me, other or batch pointer null: return
    me.layer.l_Main ≠ other.layer.l_Main and neither is −1: return
    (mini-house only) if so_SubLayer_CanSee(me, other): me.so_SendMyBriefInfo(other)   (vt 0x4c8)
    if !so_SubLayer_CanSee(other, me): return            # (a, b) = "b may see a" (Z02 §5.2 table DAT_0d67a118)
    if me.so_ObjectType (vt 0x4d0) ≠ 2: return            # receivers are players only
    if batch.count > 27: bix*_Send(batch, me); batch.count = 0
    (item only) me.vt[0x538](other)                       # (original bug) Z18-B16, see below
    other.so_FillBriefInformation (vt 0x4c4)(&batch.entries[count]); count++

bixm_Send / bixi_Send / bixmh_Send / bixmv_Send / bixp_Send (batch, me)
        @ FUN_0043d6a0 / FUN_0043da30 / FUN_0043dc90 / FUN_0043e0d0 / FUN_0043e200
    if count == 0 (or a null pointer): return
    if me.vt[0x4d0]() == 2 and me.smo_GetMode (vt 0x484) ≠ 0:
        pp_SetPacketLen(count × entry + 3)   (failure: assert "BriefInfoExchange<X>::bix<x>_Send")
        me.so_GetGameSocketStream (vt 0x2fc).append(me, packet)          # into me's outgoing buffer
    # Send does not reset count: the Exchange caller does, or the next bixall_Init

bixm_Init / bixmv_Init / bixp_Init (batch)                @ FUN_0043c630 / FUN_0043c810 / FUN_0043c8a0
    first call (pointer null): pp_Buffer = own array, pp_BufferSize = 4321 / 4031 / 1827, opcode 0x1C09 / 0x1C1B / 0x1C1D,
        pointer = payload; count = 0   (mover: assert "BriefInfoExchangeMover::bixmv_Init : bixmv_Pointer NULL" if null)
    later calls: count = 0
bixall_Init()                                             @ FUN_0043d500
    briefchar / door / effect / item / magfld / minihouse counts = 0; bixm_Init; bixa_Init(_char); bixa_Init(_mob);
    bixmv_Init; bixp_Init
    # callers: sp_NC_MAP_LOGINCOMPLETE_CMD (Z01 §6), sp_ReSetSendMyBriefInfo FUN_00441b10, so_ply_SendBriefInfo_MoveLayer
    # FUN_00441ed0 (Z09 §9.6)
```

`ShineDropItem` overrides vt 0x538 with `so_drpitm_CanLootingBitSet(viewer)` FUN_0052a420 (writes `attr.looting`, bit 3
of the entry's last byte, from vt 0x53c "can this viewer loot", Z09 §11.3). The item exchange calls the slot on **me**
(the player; disassembly 0x44025b: `mov ecx, edi` = me, `push esi` = item), where it is the empty base stub
FUN_00549070 (`ret 4`), so the item's brief keeps the looting bit last computed for some other player
(original bug) Z18-B16. Z09 §11.3 notes the same stale bit for the single 0x1C0A path.

Client (C01 `re-data/client-handlers.json`, scene `GameFrameWork`): 0x1C09 `On_NC_BRIEFINFO_MOB_CMD` FUN_004a9c10,
0x1C0B `On_NC_BRIEFINFO_ITEMONFIELD_CMD` FUN_004998c0 (`DropItemMgr::Add` per 15-byte entry; the pickable flag comes from
`attr.looting`), 0x1C14 FUN_004999c0, 0x1C1B FUN_00646ef0, 0x1C1D FUN_006492f0, 0x1C07 FUN_004a0540, 0x1C19 FUN_004a5560.
Each walks `count` entries of the sizes above; none has an error code.

### 2.2 The abstate batch: one 0x1C19 per object

```pseudo
BriefInfoExchangeAbstate::bixa_Init(batch)                @ FUN_0043c6b0
    only when bixa_Pointer is null (the first call): for each of the 28 buffers: pp_Buffer = its 341-byte array,
        pp_BufferSize = 0x155, opcode 0x1C19, handle = 0xFFFF, count = 0; then bixa_count = 0, pointer = buffer 0
    later calls change nothing (bixa_count is not reset here)

bixa_Exchange(batch, me, other)                           @ FUN_00440510
    me.layer.l_Main ≠ other.layer.l_Main and neither is −1: return
    if !so_SubLayer_CanSee(other, me): return                       # me cannot see other
    if so_SubLayer_CanSee(me, other):                               # and other can see me
        bia_Fill(briefInformationAbstate, me)  (FUN_0043cc00, Z02 §5.1)
        if its count ≠ 0: other.so_GetGameSocketStream (vt 0x2fc).append(other, that 0x1C19)   # me's abstates → other
    if me is a player (vt 0x4d0 == 2):
        if bixa_count > 28: bixa_Send(batch, me); bixa_count = 0
        pkt = buffer[bixa_count]: handle = other.handle; count = 0
        other.so_FillBriefABState (vt 0xa94)(pkt.infoList, &pkt.count)                         # other's abstates → me
        bixa_count++

ShineMobileObject::so_FillBriefABState(o, out, &n)        @ FUN_00417330
    n = 0; for each active element of o's abstate list (vt 0x52c → asl_GetAbstateList):
        if n > 27: return                                            # at most 28 entries = 28 × 12 + 5 = 341 bytes
        out[n] = { abstateID = aeo_Index, restKeeptime = aeo_GetRestTime(), strength = aeo_GetStrength() }; n++

bixa_Send(batch, me)                                      @ FUN_0043df50
    if 0 < bixa_count < 29 and me is a player and me.smo_GetMode ≠ 0:
        for each buffer i < bixa_count with count ≠ 0: pp_SetPacketLen(count × 12 + 5); me's stream.append(me, buffer i)
        bixa_count = 0
```

The class holds **28** buffers (`bixaPacketbuffer[28]` *(pdb2016)*) but the exchange flushes only when `bixa_count > 28`,
so a 29th object is written to `buffer[28]`, which lies on `bixa_nc` / `bixa_Pointer`: its `pp_Buffer` is read from
`bixa_nc`, which still points at buffer 27, so the 29th object's list overwrites the 28th's. `bixa_count` is then 29, and
the next flush (the 30th object, or `bixall_Send` at the end) refuses it (`< 29`): **all 29 packets are dropped** and
the count is reset by the caller. A player who logs in, teleports or changes layer with 29 or more players (or 29 or
more mobs / NPCs / servants / movers) in sight therefore does not get the abstate lists (buff and debuff effects) of
the first 29 of them; objects 30–57 start a new batch, and so on (original bug) Z18-B15. Because `bixa_Init` does not
reset the count, a batch that `bixa_Send` did not send (count 29, or a receiver with mode 0) is carried into the next
exchange, where its first flush drops it.

### 2.3 Brief packet objects and the tent view backup

| Function | Address | What it does / where it plugs in |
|---|---|---|
| `BriefInformationCharacter::BriefInformationCharacter` | FUN_00549090 | the player's own appear packet (`sp_CharBriefInfo`, `p+0x7e34`, Z02 §5): buffer 0xEE, length 0xED, opcode 0x1C06 NC_BRIEFINFO_LOGINCHARACTER_CMD, `bic_BriefInfo` = payload (`p+0x7f32`); `type = 2`, `myguild = 0`, `isGuildAcademyMember = 0`; from the `ShinePlayer` ctor FUN_0055bc80 and the `ShineBandit` ctor FUN_0055b2c0 |
| `BriefInformationCharacter::bic_SetAnimation(s)` | FUN_0043c250 | `strncpy(sAnimation, s, 32)` when `s` is not null; only from `sp_NC_MAP_LOGINCOMPLETE_CMD` (Z01 §6) with `""`, which clears a looping animation left from the last session |
| `BriefInformationMob::BriefInformationMob` | FUN_00549120 | the mob's appear packet (`mob+0x1ecc`): buffer 0x98, length 0x97, opcode 0x1C08 NC_BRIEFINFO_REGENMOB_CMD; from the `ShineMob` ctor FUN_0055b140 |
| `PROTO_NC_BRIEFINFO_BUILDDOOR_CMD::operator=` | FUN_00555af0 | field copy of the 0x30-byte door brief (handle, mobid, coord, doorstate, blockindex `Name8`, scale); used by `ShineDoor::so_FillBriefInformation` FUN_00555c00 (vt 0x4c4, Z09 §13.1) |
| `PROTO_NC_BRIEFINFO_EFFECTBLAST_CMD::operator=` | FUN_005553d0 | the same for the 0x30-byte effect brief (handle, effectname `Name8`, coord, detach, scale, flag); used by `ShineEffectObject::so_FillBriefInformation` FUN_005554a0 |
| `BriefInfoBackup::BriefInfoBackup` | FUN_0043c9b0 | `bib_Backuped = 0`; the player's `sp_MiniHouse.mhs_Backup` (`p+0x292ac`, flag `p+0x292d7` = knowledge Z02's "saved shapedata"; 0x2c bytes: `CHARBRIEFINFO_NOTCAMP bib_BriefInfo` 0x2b = the equipment view `PROTO_EQUIPMENT`, `bib_Backuped`); from the player ctor |
| `BriefInfoBackup::bib_Backup(view)` | FUN_00456750 | if not yet backed up: copy the 0x2b view bytes, `bib_Backuped = 1` |
| `BriefInfoBackup::bib_Restore(view)` | FUN_0042ab20 | if backed up: copy the 0x2b bytes back into the brief, `bib_Backuped = 0` |

The brief's `shapedata` is a union of `notcamp` (equipment view) and `camp` (tent view). `sp_NC_ACT_PITCHTENT_REQ`
FUN_00457760 (Z02 §7) backs the equipment view up, builds the tent view with `sp_MakeTentBriefInfo`, and restores the
backup if that fails (then `so_SendErrorCode` vt 0x308 (8, 0x28, 0xA85); 0xA85 has no client text in
`client-error-codes.json`). Folding the tent (`sp_NC_ACT_FOLDTENT_REQ` FUN_00457a90) and the mount / horse /
booth paths (`sp_MoverSystem_GetOn` FUN_0045d7a0, `sp_HorseOn` FUN_0045f270, `sp_NC_BOOTH_OPEN_REQ` FUN_0058e900) do the
same copy inline on the same member; `so_Prison_Go` FUN_005b94b0 restores it when it finds the player in mode 3 (and
sets mode 1) before sending them to prison. `sp_NC_MAP_LOGINCOMPLETE_CMD` clears `bib_Backuped`.

### 2.4 Server menus: building the menu, the summon flag

Z02 §6.6 documents the open (`sp_ServerMenuOpen`), the answer 0x3C02 and the actor layout. The builders:

```pseudo
ShinePlayer::sp_ServerMenuTitle(p, title) → p            @ FUN_0054e8a0
    g_buf (gpp): opcode 0x3C01 NC_MENU_SERVERMENU_REQ; payload.title[128] = strncpy(title, 128); menunum (+0x8d) = 0
    sma_Clear(p.sp_NPCProcess.servermenuactor)            @ FUN_0050f660
        the 10 slot callbacks and the cancel callback = the empty default; sma_bRangeCheck = 1; sma_Subst (count) = 0
    p.sp_MiscFlag.BeSummoned (p+0x5cb9 bit 2) = 0

ShinePlayer::sp_ServerMenuItem(p, callback, text, arg) → p   @ FUN_0054e990
    i = payload.menunum
    i ≥ 10: assert "ShineObjectClass::ShinePlayer::sp_ServerMenuItem : Too many items"; return p   (item dropped)
    payload.menu[i] = SERVERMENU { u8 reply = i, string[32] = strncpy(text, 32) }      # entry 0x21 bytes at +0x8e
    sma_Regist(actor, callback, arg)                       @ FUN_0050f710
        sma_Subst ≥ 10: assert "ServerMenuActor::sma_Regist : Too many regist"
        else slot[sma_Subst] = { 0x68-byte ServerMenuArgument copy, callback }; sma_Subst++
    menunum++
```

Both return the player so calls chain (`Title(t).Item(a).Item(b)` then `sp_ServerMenuOpen`). The callers are
`cServerMenu` FUN_005dab40 (Lua, Z09 §14.6), `NPCRole_Portal::nrb_Role` FUN_004c2ef0 and
`NPCRole_RandomMulti_Portal::nrb_Role` FUN_004c3850 (Z02 §6.5), `itembreakmenu` FUN_0048ced0,
`sp_SilverWingMenu` FUN_0059c090, `UseItemImmediateDivorce::uib_DirectUse` FUN_00596810 (Z02 §10),
`WorldManagerSession::wms_NC_INSTANCE_DUNGEON_DELETE_DUNGEON_*` FUN_00484590,
`ZoneRingPacketFindInstanceDungeon::zrpb_Query` FUN_005a6d10 and `ZoneRingPacketSummonPartner::zrpb_Success`.

| Function | Address | What it does |
|---|---|---|
| `ServerMenuActor::ServerMenuActor` | FUN_0050ec70 | `sma_pPlayer = null`, `sma_Subst = 0`, cancel callback = the empty default (FUN_00509900, an empty member function whose PDB name `CGambleObject::go_SMC_WinRank` is identical-code folding) |
| `ServerMenuActor::sma_SetPlayer(p)` | FUN_0050ecb0 | `sma_pPlayer = p`; from the player ctor |

**The summon flag (answers Z02 §6.6 "the setter was not traced").** `p+0x5cb9` bit 2 is
`sp_MiscFlag.BeSummoned` *(pdb2016)*. Its only setter is the wedding partner summon:

```pseudo
ZoneRingPacketSummonPartner::zrpb_Success(req, obj, ringPkt)      @ FUN_005a8680
    t = som_FindPlayer(ringPkt+9 charNo); must be a player
    arg = { map name (12 chars at ringPkt+0xd), x = ringPkt+0x19, y = ringPkt+0x1d }
    t.sp_ServerMenuTitle(ss_String("Summons")).Item(smfm_LinkWithoutNPC, ss_String("Yes"), arg)
                                         .Item(smfm_Cancel, ss_String("No"), empty)
     .sp_ServerMenuOpen(priority 0, npc 0xFFFF, no position, limitRange 1000)
    t.sp_MiscFlag.BeSummoned = 1
ServerMenuFuncter::smfm_LinkWithoutNPC(p, arg)                   @ FUN_0050f1d0
    if BeSummoned: p.so_LinkTo (vt 0x600)(arg, 6, 9, 10); BeSummoned = 0
```

With the flag set, 0x3C02 (Z02 §6.6) skips the 1000-unit range check, so the summoned partner can answer from anywhere;
any later `sp_ServerMenuTitle` clears it. The request side (`zrpb_Request` FUN_005a83b0, skill `ss_SummonMate`) is Z13's
(Z09 §28.4).

### 2.5 Spam chat ban setter

`ShinePlayer::so_SetSpamerChatBan(v)` FUN_00560a20 (vt 0xae8): `sp_Spammer_ChatBan` (`p+0x2aa54`) = v. The player ctor
sets 0; the WM option 0x10D3 sets the value (Z12 §7.1); WM 0x0865 NC_MISC_SPAMMER_ZONE_CHAT_BAN_CMD writes the same
member (Z01). Chat and shout read it (Z02 §3.1 `gmBlocked`, FUN_00560a30).

---

## 3. Z03: combat, skills, abnormal states

Rows "Abnormal states" (18) and "Skills, attacks and target scans" (35) of Z09 §31.2, the packets 0x2442 / 0x2443
(§31.3) and the "Skill-side helpers" open points of Z09 §31.5. Context: Z03 §5 (skills), §6 (abstates), §7.2–§7.3
(death, shelters, revive). Names *(pdb2016)*; `g_AbActiveInfo` (Z03's name) is the PDB's `abstateidentarray`.

### 3.1 The SubState → actor table: `ActorCluster`

`AbnormalStateContainer::ActorCluster::ActorCluster` FUN_00405a10 builds the global `actorcluster` (0x384 bytes):
one actor object per member (each just a vftable), then `ac_SubStateList[120]` (+0x1a4) = `SubState` → actor. It
zeroes the list, fills every index and asserts "ActorCluster : Buffer not full" + `ShineExit` if one stays null.
`aeo_Set` FUN_0040a340 (Z03 §6.2) is its only reader: `g_AbActiveInfo[index].actor = actorcluster.ac_SubStateList[sub.Type]`.
`~ActorCluster` FUN_00406330 resets the vftables. This replaces Z03 §6.1's actor table, which was read from the class
names (corrections in knowledge Z18):

| `SubState` (enum, pdb2016) | Actor class |
|---|---|
| 16 DAMAGESHIELD, 92 UBAUP, 93 UBADOWN | `SubAbnormalStateActorShield` |
| 17 MANASHIELD | `…ActorManaShield` |
| 22 BLOODING, 27 DOTDAMAGE, 33 POISON, 67 KNOCKBACK, 83 BURN, 84 FITBLOODING, 94 BURNPAINME | `…ActorPoison` (67 see Z18-B5) |
| 24 MAXHPRATE, 25 MAXSPRATE, 39 MAXHPPLUS, 40 MAXSPPLUS | `SubAbnormalStateMaxHP` |
| 26 DEADHPSPRECOVRATE | `…ActorPartyRecharge` |
| 28 FEAR / 70 CAPTIVATE / 105 CANNOTTARGET | `SubAbnormalStateFear` / `…Captivate` / `…CannotTarget` |
| 29 CONHEAL / 41 CONSPHEAL / 66 CONHPSPHEAL | `…ActorHPHeal` / `…SPHeal` / `…HPSPHeal` |
| 30 CASTINGTIMEPLUS / 118 DELCASTING | `…ActorCastDelay` / `…ActorDelCastTime` |
| 31 COOLTIMEREMOVE | `…ActorIgnoreCoolTime` |
| 32 MAGICATTACKNOUSE / 88 ONETIMECANNOTUSESKILL | `…ActorSilence` / `…ActorSilencetoone` |
| 34 DISEASE | `…ActorDisease` |
| 58 SELFREVIVE / 59 RANGESHIELDCOUNTER | `…ActorSelfRevive` / `…ActorRangeIntercept` |
| 75 ANGRY (member `ac_TOTALDAMAGERATE`) / 76 DAMAGENEGLECT (`ac_TOTALDAMAGERATE_BYDEF`) / 77 TIMEATTACK | `…ActorLastDmgRatio` / `…LastDmgRatio_DefSide` / `SubAbnormalStateActerTimeAttack` |
| 78 DETACHPROCESS | `…ActorDetachProcess` |
| 82 GTI, 95 BURNPAINFOE, 101 MENDOWNRATEME (member `ac_SPDOWNRATEME`) | `…ActorAreaDamage` |
| 97 BOMBSHOT | `…ActorBomb` |
| 100 USESPDOWN | `…ActorUseSPDown` |
| 106 HIDEDAMAGE / 107 MAGICFIELD | `…ActorHideDamage` / `…ActorMagicField` |
| 109 EXPRATE / 110 DROPRATE | `…ActorExpUpRate` / `…ActorDropUpRate` |
| 113 DISPEL | `…ActorDispel` |
| 114 RANGEDMGDOWNRATE / 119 RANGEDMGDOWNRATEATK | `SubAbnormalStateDamageMinus` / `SubAbnormalStateRangeDamageMinusAtk` |
| 115 DMGSHIELDRATE / 116 DMGDOWNRATE / 117 MINHP | `…ActorShieldHPRate` / `…ActorDamageDownRate` / `…ActorMinHP` |
| all others (0–15, 18–21, 23, 35–38, 42–57, 60–65, 68, 69, 71–74, 79–81, 85–87, 89–91, 96, 98, 99, 102–104, 108, 111, 112) | base `SubAbnormalStateActor` (no hooks; the stat effect comes from the matrix, Z03 §6.1) |

`SubAbnormalStateActorDmgState` (member `ac_DOTWCRATE`, `sasa_Routine` FUN_0040dc60) is built but in no slot: it is
never attached (Z18-B5). The actor bodies are Z22's.

**Which SubAbState kinds use the "MagicField" actor** (Z09 §12.8 open point): only SubState 107. `SubAbState.shn` has
two such rows, `SubStaEglack04` (ID 9300) and `SubStaEglackMad04` (9301), Strength 1, KeepTime 15000 ms, actions
`SAA_TICK` 1000 (the routine runs every second) and `SAA_SETACTIVESKILL` 29408 / 29414 (the skill whose field
`sasa_Routine` FUN_00408d80 spreads, Z09 §12.2 (2)); the abstates are `StaEglack04` (494) / `StaEglackMad04` (501).

**`smo_SkillBlastOption` values** (open point): `ShineMobileObject::smo_SkillBlastOption` FUN_0057c750 returns the
maximum of `actor.vt[0x1c](e)` over the object's abstates (`SkillBlast`: 0 `SB_NORMAL`, 2 `SB_SILENCE`). Every actor
returns 0 (the base slot is a folded `return 0`) except `SubAbnormalStateActorSilence::sasa_Act_SkillBlast` FUN_0063ecc0
(→ 2) and `SubAbnormalStateActorSilencetoone::sasa_Act_SkillBlast` FUN_00401d20 (→ 2 and sets the element's
`aeo_Tick.terminate = now`, so the state ends at the next routine). "One use" is therefore consumed by the first
**query**, whoever asks: the cast checks (Z03 §5.2 / §5.5, 0xFC7), the item-use check (Z04, 0x3129) or a mob's attack
choice (Z09 §7.4) *(inferred from the callers)*.

### 3.2 Abstate elements and lists

The element class `AbnormalStateElement` (one per `AbState` row, `abstatetemplate`, 11 virtual slots; subclasses
`…ElementNormal`, `…Recover`, `…TickRoutine`, `…EachTickRoutine`, `…RestCount`, `…RestCountHPRate`, `…Hide`,
`…Polymorph`, `…ReinforcedMove`, `…PartyEnchant`, `…CouplePartyEnchant`, `…GuildAcademyMasterEnchant`) is the second
hook level besides the SubState actor. Its vt 0xc is "party-type enchant" (true only for the three `*PartyEnchant` /
`GuildAcademyMasterEnchant` classes).

```pseudo
AbnormalStateElement::ase_AttachObject(cls, e, o)      (element vt 0x1c)                     @ FUN_00401d40
    if e == null: return
    g_AbActiveInfo[cls.ase_index].actor.vt[4](e, o)            # the SubState actor's sasa_AttachObject
    if ActionEffectAbStateTable::FindActionID(AbState.InxName of e, &id):
        o.so_AddItemAction(id, 0xFFFF)  (vt 0x5d8)              # abstates that switch on an item action (Z04 item actions)

AbnormalStateReinforcedMove::ase_AttachObject(cls, e, victim)                                @ FUN_00401db0
    # knock-back / pull: the element class of the push abstates (Z09 §9.3 "callers of vt 0xa28")
    base ase_AttachObject(cls, e, victim)
    if victim == null or victim.smo_GetMode() (vt 0x484) == 5: return
    if mode == 4: victim.vt[0x488]()                             # player so_ply_ReinforceFoldtent *(inferred: leaves the sitting / tent state)*
    sub = AbState entry .strength[e.aeo_Strength] (1…39); caster = e.aeo_GetCaster(); if caster == null: return
    from = caster.pos
    first of sub's 4 actions that is one of:
        SAA_AWAY (49) d = arg:          push away from the caster,      backwards = 1
        SAA_AWAYBACK (79) d = arg:      pull toward the caster,         backwards = 0
        SAA_AWAYBACKSPOT (109) d = arg: pull toward e.AbsSetData.CenterLoc (the skill's spot), backwards = 0
    (none of them → return; d == 0 → return)
    if pull: d = min(d, dist(from, victim) − victim.so_BodySize() (vt 0x6cc)); d = −d   # stops at the body edge
    dest = victim.pos + unit(victim.pos − from) · d              (same spot: dest.y += d)
    if so_FindBlockLocate(victim, dest, |d|, &out, mbi_IsMoveBlock):
        speed = sub row KeepTime (+0x2b) ≠ 0 ? |d · 1000 / KeepTime| : 500
        victim.so_ReinforceMove(out, speed, backwards, 0, 0) (vt 0xa28 → 0x2069, Z09 §9.3)
```

`smo_ShadowStep` FUN_0045ad10 (the third mover, Z03 §5.4; path maths in Z09 §9.3) after the path: caster
`so_mobile_StopHere` (vt 0xa48), `so_Unmark(2, 0, 3)`, position = last path point, `fm_Marking`; marking fails →
`so_Disconnect(0x685)` (vt 0x5f8; a kick code, not in the client table); else face the target, broadcast to sight
0x206A NC_ACT_REINFORCEMOVEBYPATH_CMD `{u16 mover, u16 speed = 500, u8 direct, u8 pathlength, SHINE_XY_TYPE path[n]}`
(6 + 8n bytes, packets-zone.md), set `STA_CANNOTCONTROL` (350) on the caster for `pathLen · 1000 / 500` ms (how 9) and
inform it, and halt the move manager unless it is in `MM_REINFORCEMOVE`. `NPCAction::BallAction::exe` FUN_005c1390 is
Z09 §16.5 (actions).

| Function | Address | What it does / where it plugs in |
|---|---|---|
| `AbstateElementInObject::aeo_CompName(list, i, other)` | FUN_004065c0 | `other.aeo_Index − this.aeo_Index`: the `List` compare callback (Z11 cites it) |
| `aeo_GetAbstateElement` | FUN_004067b0 | element class of `aeo_Index` from `abstatetemplate` (null when out of range); readers `so_RecalcAbstateParam` (Z12 §2.5), `so_Dispel` (§3.4), `ab_SaveAbstate`, `lid_Call` |
| `aeo_GetCaster` | FUN_00401b90 | `aeo_Caster.obj` if it still exists with the same `so_GetCharRegistNumber` (vt 0x344) as `aeo_Caster.chrregnum`, else clears the pointer and returns null; readers: ReinforcedMove above, MagicField / Bomb actors |
| `aeo_GetRestTime` | FUN_00408990 | remaining ticks rounded up to whole seconds × 1000 (ms), 0 when expired (Z12 §5.4); also `so_FillBriefABState`, `ab_SaveAbstate`, `so_KilledBy` |
| `aeo_GetStrength` | FUN_004011e0 | `aeo_Strength` (u8) |
| `~AbstateElementInObject` | FUN_00401b20 | destroys the two embedded objects `aeo_SetItemEffect` (+0x60) and `aeo_Tick.nextaction` (+0x24) (folded no-op dtor) |
| `AbstateListInObject::AbstateListInObject` | FUN_0040cf10 | 28 in-place elements `asl_Element[28]` (0x74 each) and `asl_List` (+0xcb0, `l_MakeList(28)`), every list slot pointing at its element: **an object holds at most 28 abstates at once**. From the `ShineMobileObject` ctor FUN_005591c0 and the static `so_defabstatelist` |
| `asl_Check_SameAbstate(idx, strength)` | FUN_0040c180 | true when `idx` is set (`asl_Abstate_IsSet`) with exactly that strength (1…39); only caller `sp_UseItemMinimon_NormalRoutine` FUN_00564040 (Z13: the mini-pet does not re-cast a buff already present) |
| `asl_GetAbstateList` | FUN_00401250 | `&asl_List` |
| `asl_IsHereBad` / `asl_IsHereGood` | FUN_0040ad40 / FUN_0040abb0 | any element whose `AbState.DispelIndex` is ≠ / == `DA_GOOD` (1); used by the target rules `so_mob_CanMyTarget` FUN_004ade40 / `so_ply_CanMyTarget` FUN_004ae010 (and twins FUN_004ae280 / FUN_004ae450) for skills restricted to buffed / debuffed targets |
| `ListTraveler<AbstateElementInObject>::lt_Next` | FUN_00402740 | iterator step (`lt_CurrElement = lt_NextElement`, follow `ls_Next`); false at the end |
| `AbStateStrArgument::assa_IsHaveEffect(action)` | FUN_00416190 | true if one of the SubAbState row's 4 `assa_Effect[i].action` equals `action`; the actors' guard (24 callers, Z22) |

```pseudo
AbstateListInObject::asl_SendAfterLogin(list, p)                                              @ FUN_0040aed0
    for each active element e: aeo_InformAfterLogin(e, p)                                       @ FUN_00409a20
        cls = element class of e; if cls == null or cls.vt[0xc]() (party-type enchant): skip
        ms = ceil((e.terminate − now) / 10) · 1000
        p.so_AbnormalState_Inform(e.index, ms, 0) (vt 0x3f0 → 0x242A NOEFFECT)
        so_AbnormalState_BroadcastSet(p, e.index, ms, e.strength)   (0x2427 / 0x1C18, Z03 §6.3)
    # callers: 0x1803 login (Z01 §6), sp_ReviveNow FUN_0057d290, sp_ReSetSendMyBriefInfo FUN_00441b10,
    #   alcm_SendBriefInfo FUN_00441c50, so_ply_SendBriefInfo_MoveLayer FUN_00441ed0 (Z02 §5)
```

### 3.3 Death shelters: `AbstateShelter`

`g_ShelterItem` / `g_ShelterDie` (Z03 §7.2) are `AbnormalStateShelter::AbstateShelter` = `vector<AbstateBuffer> as_Safe`;
`AbstateBuffer` (0x14) = `{ ulong ab_Master (charNo, 0xFFFFFFFF = free), vector<AbstateElementInObject> ab_List }`.

```pseudo
AbstateShelter::operator[](sh, charNo) → AbstateBuffer &                                     @ FUN_00418890
    buffer with ab_Master == charNo → it;  else the first free one (ab_Master = −1) → claim it (ab_Master = charNo)
    else push_back {charNo, empty} and return the new last one          # never shrinks
AbstateShelter::as_Remove(sh, charNo)                                                         @ FUN_00417520
    every buffer of charNo: ab_Master = −1                      # the element list is NOT cleared here
AbstateBuffer::ab_Recover(buf, o)                                                              @ FUN_00417ef0
    for each saved element: aeo_Recover(e, o)                                                   @ FUN_004176c0
        if e.terminate <= now: skip                              # expired while dead
        ms = (e.terminate − now) · 1000 / 10
        if o.so_AbnormalState_Set(e.caster, e.index, e.strength, entry, now, 0, e.aeo_RestCount, ms, how 11) (vt 0x638):
            if not a party state (PartyRange == 0 or PartyEnchantNumber == 0): BitSet; BroadcastSet(ms); Inform(ms, 0)
            o.vt[0x528]() (recalc)
    # callers of all three: 0x482A sp_NC_SKILL_REPLYREVIVE_CMD (Z03 §7.3), uib_Effect FUN_00418b60 (revive item, Z04),
    #   sp_ReviveReqProcess FUN_00451bd0 (Z07); operator[] also from so_KilledBy (store) and 0x1103 REBIRTH_REJECT (Z07)
```

A claimed buffer keeps its old `ab_List` until the next store overwrites it *(inferred: `so_KilledBy` fills the buffer;
not re-read)*.

### 3.4 Dispel, cure and the caster-side abstate

```pseudo
ShineMobileObject::smo_Dispel(a, s, empower, t, bos)                                          @ FUN_0057d8e0
    # from smo_SkillBlast (Z03 §5.6, section D) for EffectType SE_DISPEL / SE_CURE
    mask = 0  (bit n = DispelAttr n: 1 GOOD, 2 DEBUFF, 3 DISEASE, 4 POISON, 5 CURSE, 8 DEEPER, 9 HIDE, 10 BOMB)
    if not a.so_mobile_IsEnemy(t) (vt 0x72c):                    # friendly target: remove bad states
        SE_CURE → mask = DISEASE | POISON (0x18)
        SE_DISPEL → DISPELDEBUFF 0x4 | DISPELDISEASE 0x8 | DISPELPOISON 0x10 | DISPELCURSE 0x20 | BOMBDISPELALL 0x400
    else if not s.DISPELDEEPER: mask = s.DETECT ? HIDE (0x200) : GOOD (0x2)   # enemy: strip buffs / reveal
    else: mask = DEEPER (0x100) if t has a STA_DEEPER element set by a (aeo_IsMine), else 0
    a.so_SkillCure(t, smash, bos)  (vt 0x5a4);  a.so_Dispel(t, smash, bos, mask)  (vt 0x5a8)
    result slot: target t, isenchant = 1, isresist = 0

ShineMobileObject::so_SkillCure(a, t, smash, bos) → bool                                      @ FUN_0042c440
    if t == null or t dead (mode 3) or not s.CURE: return false
    walk t's abstates; first element with DispelIndex DISEASE or POISON and AbState.StateGrade <= s.CURE value:
        e.aeo_Flag |= f_Cured; e.terminate = now; return true
    # a 1000-roll "< 1001" guards each element: always true (original bug) Z18-B6

ShineMobileObject::so_Dispel(a, t, smash, bos, mask) → bool                                   @ FUN_0042bf70
    if t == null or t dead: return false
    if t.so_MiscTable() (vt 0x984) row has Dead.ByDebuff (+0x58 bit 0) and mask & GOOD:
        t.so_DamagedBy(t, t.HP, 1000, 1) (vt 0x5c0); return true   # servants that die to a dispel (Z09 §13.3)
    forward over t's abstates (same always-true roll, Z18-B6), elements whose DispelIndex bit is in mask:
        s.DISPELONE  → e.terminate = now; return true            # first match only
        s.DISPELALL  → e.terminate = now
        s.DISPELRANDOM → reservoir pick: the k-th match replaces the pick with probability 1/k (RandomBox)
        s.BOMBDISPELALL → e.aeo_Flag |= f_Dispeled; e.terminate = now   # the Bomb actor's detach sees the flag (Z22)
    backward over t's abstates, first element with a mask bit and s.STEALENCHANT whose element class is not a
    party-type enchant (vt 0xc):
        if rand1000 < STEALENCHANT value: e.terminate = now on t;
            a.so_AbnormalState_Set(a, e.index, e.strength, entry, e.start, 0, e.aeo_RestCount, 0, how 6) → on success
            BitSet, Inform(KeepTime, 1), BroadcastSet(KeepTime, strength): the caster now has the state
        stop after this one element, stolen or not
    random pick (2 or more candidates seen): pick.aeo_Flag |= f_Dispeled; pick.terminate = now
    return: true after a steal or an ALL / BOMB removal *(the decompiled return byte is unclear for the random path)*

ShineObject::so_AbnormalState_Set_SS_SETABSTATEME(o, &abstate, &keeptime) → bool  (vt 0x648)  @ FUN_00416880
    # a skill's SETABSTATEME on the caster: smo_SkillBash_Blast FUN_0057cd40, smo_MagicFieldSpread FUN_0057c880
    entry = AbState by ID abstate.value (> as_maxhandle → assert "as_FromID : Invalid skill id"); none → false
    if o.so_AbnormalState_Set(o, entry.index, strength 1, entry, now, 0, 0, keeptime.exist ? keeptime : −1, how 13):
        BitSet; BroadcastSet(index, 0, 1); Inform(index, 0, 0); return true
```

### 3.5 Skill target scans and random targets

`AxialListScanSkillTarget` (0x758, base `AxialListLimitAreaScan`) adds `alsst_attacker` +0x730, `alsst_attackPos`
+0x734, `deque alsst_RandomTargetList` +0x73c, `alsst_nEffectForJustSkill` +0x754. Its four subclasses differ only in
their scan filter (vtable): `AxialListNearScanSkillEnemy` (`Last` = TARGET_ENEMY), `…Party` (PARTY / GROUP), `…Friend`
(FRIEND), `…EnemyUser` (ENEMYUSER); the base class is used for TARGET_ALL. Constructors FUN_0057e0f0 (base),
FUN_0057e1a0 / FUN_0057e260 / FUN_0057e360 / FUN_0057e420 (subclasses): `AxialListLimitAreaScan` ctor, empty deque,
counters 0; `~AxialListScanSkillTarget` FUN_0057e320 frees the deque. `alsst_SetAttacker(a)` FUN_005793b0 stores `a` and its
position. The blast functions use five global instances (`alnse`, `alnsp`, `alnsf`, `alnsst`, `alnseu`, Z03 §5.6);
these ctors are reached only from the random-target helper below, which builds its own five on the stack.

```pseudo
ShineMobileObject::so_smo_GetRandomTarget_Object(m, s, range, from) → object  (vt 0xc1c)       @ FUN_0057e660
    # mob AI "skill on a random target" (Z09 §7.4, sk.First ≠ SPOT)
    if s or s.sdi_Activ is null or m has no position: return null
    scanner by s.Last: ENEMY → …Enemy, PARTY / GROUP → …Party, FRIEND → …Friend, ALL → base, ENEMYUSER → …EnemyUser,
        else return null
    alsst_SetAttacker(scanner, from.vt[0xb8c]()) ; attackPos = m.pos
    so_AllOfRange(from, m.pos, range, scanner); alns_Sort
    exclude = m's own handle; if s.TOPAGGRONO and ≥ 2 candidates and m.so_mob_GetTopAggroTarget() (vt 0xc18):
        exclude = that target's handle                            # "not the tank"
    alsst_MakeRandomTargetList(scanner, 1, exclude); return its first entry or null

AxialListScanSkillTarget::alsst_MakeRandomTargetList(sc, want, exclude)                       @ FUN_0057e4e0
    clear the deque; want = min(want, candidates)
    while deque size < want and candidates left:
        pick a random candidate (RandomBox[count]; count ≥ 101 → index 0); remove it from the candidate array
        (swap with the last)
        keep it when it is not `exclude` and the straight line attacker → it is free
            (so_FindBlockLocateFrom(attacker, attackPos → its pos, 10000, mbi_IsAttackBlock) reaches its pos)

ShineMobileObject::so_smo_GetRandomTarget_Locate(m, s, &out) → bool  (vt 0xc20)                @ FUN_00579910
    # mob AI SPOT skills (Z09 §7.4)
    r = rb_largerandom(s.Range); angle = RandomBox[64] · 180 / 64 (sr_sin1024 / sr_cos1024 units)
    p = m.pos + r · (sin, cos)
    so_FindBlockLocate(m, p, 2r, mbi_IsAttackBlock) then again with mbi_IsMoveBlock: out = the reachable point; true
    (either fails → false; the AI then uses the target's position)
```

`FanFormSectorArgument::FanFormSectorArgument(caster, target)` FUN_0057bda0 (0x14: `ffsa_shineradian`, `UnitVector
ffsa_chardirect`): the cone direction = unit vector caster → target; when target == caster, toward the caster's current
target (vt 0xa04) if any. From `sbe_BlastObject` FUN_00583bc0 for cone skills (Z03 §5.6, `SkillDegree`).

### 3.6 0x2442 / 0x2443: trap blasts `smo_SkillBash_Blast_Trap`

The only caller is `MobExplosionBase::meb_Explosion` FUN_004a7960 (mines and traps, Z09 §8.8: `blastMode` 1 / 3 → Loc,
2 / 4 → Obj), so these packets announce a trap's skill without a cast phase.

```pseudo
ShineMobileObject::smo_SkillBash_Blast_Trap(Obj)(o, t, empower, s)                           @ FUN_005838a0
    broadcast to sight of o (incl. o) 0x2442 NC_BAT_SOMEONESKILLBASH_OBJ_CAST_CMD {
        u16 skill = s.sdi_Activ.ID, u16 caster = o.handle, u16 target = t.handle }                 # 6 bytes (pdb2016)
    (copies o's name into the `namestring` ring; unused)
    SkillResultBuffer::bufferpoint = 0
    if s.TargetNumber == 1:
        smo_SkillBlast(o, s, o.smo_SkillCast.scs_BattleSkill.target, &o.smo_SkillCast.scs_Empower, −1, MultiHitArgument(), 1, 1000)
        # (original bug) Z18-B7: neither t nor the empower argument is used
    else:
        scanner by s.Last: ENEMY → alnse, PARTY / GROUP → alnsp, FRIEND → alnsf, ALL → alnsst
            else assert "smo_SkillBash_Blast : Invalid TargetType" and skip the blast   # ENEMYUSER: (original bug) Z18-B7
        attacker = o; no AreaSkill row: circle of Area/2 around t (self not included);
        else the AreaSkill shape from o's position and facing (allas_Init / allas_GetEffectCoord, radius row +0x34)
        so_AllOfRange; qsort by distance; alsst_SkillBlast(scanner, s, &o.smo_SkillCast.scs_Empower, TargetNumber, null)
    smo_SkillResultPacket(o, s, t.pos)            # the results (Z03 §5.4); sds_Finish in meb_Explosion sends 0x2452

ShineMobileObject::smo_SkillBash_Blast_Trap(Loc)(o, xy, empower, s)                          @ FUN_005835e0
    broadcast to sight of o (incl. o) 0x2443 NC_BAT_SOMEONESKILLBASH_FLD_CAST_CMD {
        u16 skill = s.sdi_Activ.ID, u16 caster = o.handle, SHINE_XY_TYPE loc = xy }               # 12 bytes (pdb2016)
    always the area path (also for TargetNumber 1): scanner by Last incl. ENEMYUSER → alnseu; circle Area/2 around xy
    (self included) or the AreaSkill shape; alsst_SkillBlast(scanner, s, empower, TargetNumber, null)
    smo_SkillResultPacket(o, s, xy)
```

Client *(2016 handlers, names from the 2017 PDB)*: `GameFrameWork::On_NC_BAT_SOMEONESKILLBASH_OBJ_CAST_CMD` FUN_0049a460
looks up caster and target (`GetCharByHandle`, opcode 0x2442 for the log); if the caster exists, is not the own
character and the target exists: `caster.ActSkill(target, 1, skill)` (vt 0x138) and `AdjustMove` (vt 0x218).
`On_NC_BAT_SOMEONESKILLBASH_FLD_CAST_CMD` FUN_0049a4d0: caster found and not the own character →
`Char::SetSkillTargetGroundPoint(x, y, 1)`, `ActSkill(x, y, 1, skill)` (vt 0x134), `AdjustMove`. Same code in the 2017
client (FUN_0049de40 / FUN_0049deb0). No error codes. A trap the client does not know (hidden by `StaEntrapHide`)
shows nothing: the handle lookup fails.

### 3.7 Blast queue, multi-hit and damage tables

`sbec_Store` FUN_00438380 (Z03 §5.6) queues each blast into `g_BlastEffects`; the row functions plug in there:

| Function | Address | What it does / where it plugs in |
|---|---|---|
| `SkillBlastEffect::SkillBlastEffect` | FUN_00434c60 | 0x6c-byte queue entry; only initialises its `sbe_MultiHitArgument` like the ctor below |
| `MultiHitArgument::MultiHitArgument` | FUN_00434b30 | `mha_HitStep = −1` (single hit), `mha_DamageRate = 1000`, 4 × `{rate 0, MAX_ABSTATEINDEX, strength 0}`; also built by `alsst_SkillBlast`, `alsst_SkillBlast_RandomTarget`, `meb_Explosion`, Trap(Obj) |
| `mha_SetAbState(i, name, rate, strength)` | FUN_00434de0 | slot i ← AbState by InxName (`as_BTreeIndex`); `"-"` or unknown name → empty slot. `sbec_Store` fills the 4 slots from the skill's `StaNameA…D` / `StaSucRateA…D` / `StaStrengthA…D` for single-hit skills |
| `MultiHitData::MultiHitTable::operator[](id)` | FUN_004c0a90 | `MultiHitType.shn` row (0xa8: `mhe_ID`, `OneHit mhe_Array[10]`, `mhe_ArrayCnt`; loader `mht_Load` FUN_004c0ff0, Z01) by index, null if out of range or `mhe_ID ≠ id` |
| `DamageBySoul::SoulDamageContainer::operator[](n)` | FUN_00434db0 | row n of `DamageBySoul.txt` (`ushort sde_DamageRateBySoul[8]`, loader `sdc_Load` FUN_0045d070), `sdc_Default` when out of range |
| `SkillBlastEffectContainer::sbec_ListCheck` | FUN_004358a0 | empty (profiler only); called after every insert |
| `DamageByAngle::DamageTable::operator[](delta)` | FUN_0045c9a0 | back-attack rate (‰) for an angle difference: `|delta|` folded into 0…90 (`delta > 90` → `delta − 180·k − 180`, then `|…|`), else assert "Invalid delta" and 1000; from `roe_CalcDamage` / `roe_AttackPowerCalcDamage` (Z03 §4.5) |

```pseudo
sbec_Store multi-hit part (s.HitID ≠ 0 and chain depth ≤ 1):                                  (in FUN_00438380)
    row = g_MultiHitTable[s.HitID]; missing → nothing is queued (the skill does nothing)
    soul = s.DemandSoul ? DamageBySoul[DemandSoul].sde_DamageRateBySoul[souls held] : 1000
    for i, hit in row.mhe_Array while hit.oh_HitTimeRate ≠ 0:
        queue {fireAt = now + oh_HitTimeRate · 10 / 1000 − 2, mha_HitStep = i, mha_AraeStep = oh_AreaStep,
               mha_DamageRate = oh_DamageRate · soul / 1000, mha_AbState[0] = {oh_AbStateRate, oh_AbState, oh_AbStrength}}
    # multi-hit skills apply only the row's one abstate per hit, not the skill's StaNameA…D
single-hit: mha_DamageRate = soul, the 4 skill abstates, fireAt = now + smo_SkillBlastTick(s) (or SHOTSPEED flight
    time: dist · 1000 / SHOTSPEED · 10 / 1000, ≥ 1, plus the blast tick for the first chain step) − 2 unless RANDOMTARGETNUMBER
the queue is kept sorted by fireAt (insert before the first later entry)
```

`SkillDamageSender::sds_Initialize` FUN_00437ba0 empties the `SkillDamage` vector (`resize(0)`), here from
`meb_Explosion` (Z03 §5.6 shows the `sbec_Routine` use). `SkillEffectEraser::~SkillEffectEraser` FUN_00437c40 is the
scope guard of `sbec_Routine` FUN_00437fc0: on leaving it erases the entry `see_Skill` from `see_List` (vector erase,
0x6c-byte moves), i.e. pops the processed blast also when an exception unwinds.

**Damage-absorb flag consumer** (Z09 §31.5 open point). `smo_Flag.DamageAbsorb` (bit 7 of +0x1e78) is set by an
NPC protector that took the hit for the player (`DamageAbsorbAction::exe` FUN_005c11a0, Z09 §16.6, which broadcasts
its own 0x2449) and cleared by `so_ply_CheckDamageAbsorption` FUN_00579860 at the start of every damage step and at
0x1803. It is read through `smo_GetFlagDamageAbsorb` FUN_005558c0 (vt 0xbec) right after the damage was applied:

```pseudo
smo_SwingDamage(a, d)  (basic attack, Z03 §3.2)                                              @ FUN_00432f30
    … damage applied, passive triggers (vt 0xbf8) …
    if d.smo_GetFlagDamageAbsorb(): skip the 0x2448 NC_BAT_SWING_DAMAGE_CMD broadcast for this hit
SkillDamageSender::sds_TemplateStore(a, result)  (skill hit, Z03 §5.6)                       @ FUN_005803c0
    … hpchange, resthp = target HP …
    if not target.smo_GetFlagDamageAbsorb(): push the SkillDamage entry      # else the target is left out of 0x2452
```

So a fully absorbed hit is shown to clients only as the protector's 0x2449; the victim's own damage line is dropped.

### 3.8 Player attack timing and the rest

| Function | Address | What it does / where it plugs in |
|---|---|---|
| `ShinePlayer::TimeScheduler::TimeScheduler` | FUN_005697c0 | `p.sp_TimerStr` (Z03 §3.1 "`p.action`"): `ts_Limit = 0`, both callbacks = a `return 0` stub, `ts_CurWork = TSCW_NONE`. PDB layout: +0 `ts_Limit`, +4 `ts_CallFunc`, +8 `ts_DefaultReturn`, +0xc `ts_CurWork`, +0x10 `ts_TimerFunc`; `TS_CurWork`: 0 NONE, 1 MISC, 2 NORMALATTACK_SWING, 3 NORMALATTACK_DAMAGE, 4 LOGOUT |
| `TimeScheduler::ts_IsInNormalAttack` / `ShinePlayer::sp_IsNormalAttack` | FUN_0042abb0 / FUN_00560230 | `ts_CurWork` ∈ {2, 3}. The first from 0x242B BASHSTART, 0x2440 / 0x2441 casts, 0x2017 / 0x2019 moves, item active skills; the second from the captivated-mob AI `mab_Think` FUN_004b99e0 / `mab_CaptivatePlayerAttack` FUN_004ba0d0 |
| `ShinePlayer::so_ply_setSwingTime(t)` | FUN_00560ae0 | `sp_SwingTime = t`; only the player ctor (0) |
| `NormalAttackDamageTick::NormalAttackDamageTick` / `nadt_Clear` | FUN_00577cd0 / FUN_00577e30 | the delayed-hit queue `p+0x173d0` (Z03 §3.2): ctor pushes 8 empty `NormalAttackDamageElement {nade_Tick, nade_Target, nade_AttackSequance, nade_MissileFlyMilliSec}` and resizes to 0 (pre-allocates); `nadt_Clear` = resize(0), from 0x242B, 0x1803, 0x2017 / 0x2019 (moving drops pending hits) |
| `ShinePlayer::sp_SkillShiftCancel` | FUN_0057bcd0 | if `smo_Flag.InSkillShift` (bit 4 of +0x1e78): log "…sp_SkillShiftCancel : Cancel" (stdout), `smo_CastAbort` (vt 0xed4), clear the bit and `+0x1d84`; from 0x2017 / 0x2019 moves and `so_ReinforceMove` (Z09) |
| `ShinePlayer::sp_SkinPolymorph(mob, abstate, broadcast)` | FUN_004a3280 | brief `polymorph = mob`, `sp_nPolymorphAbstateIndex = abstate` (MAX when mob == 0xFFFF); 0x10AF NC_CHAR_POLYMORPH_CMD `{u16 player, u16 polymorph, u32 AbstateIndex}` to sight incl. p (broadcast 1) or to p only (assert text copied from "sp_NC_MAP_LOGINCOMPLETE_CMD"); from `sp_SetAbstatePolymorph` FUN_004a33c0 and 0x1803 (Z07 §3.4 documents 0x10B0) |
| `BattleObjectGroup::BattleObjectStruct(att, def)` | FUN_00434bb0 | 0x98-byte per-hit record copied from the zero template `battleobjectstructclear`, then `bos_Attacker` / `bos_Defender`; fields `bos_Damage`, `bos_Heal`, `bos_AbsoluteAggro`, `bos_DamageRateAggro`, `bos_MyHealHit`, `bos_MyHealKill`, abstate and dispel lists, `bos_StealedEnchant`; from `so_Bash` FUN_0042e950, `smo_SkillBlast`, `smo_old_skill_blast` |
| `BattleObjectList::bol_Store` | FUN_00434ee0 | empty (profiler only): the battle records are built and passed around but never stored |
| `BattleStat::bs_Clear` | FUN_0043be00 | zero the counters (`bs_KillScore`, `bs_DamageAmount`, `bs_HealAmount`, `bs_SkillBlast`, `bs_CriticalNum`, `bs_HittedNum`, `bs_KnockDownNum`, `bs_Dead`, `bs_Kill`), `bs_Score = 10000`; from 0x1803 |
| `CharaterSkillList::CharaterSkillList` | FUN_00447eb0 | `p+0x17d0c` (Z03 §5.1): empty `csl_Skill` reserved for 3000 entries (0x14 each), `csl_SkillNumber = 0`, empty `csl_ToggleSkill`; player ctor |
| `csl_EmpowerSummary` | FUN_00445070 | sum of the four 4-bit fields of every skill's `SKILL_EMPOWER` (+8): the points spent; from `sp_GainExp`, `&levelup`, `so_charskilldata`, 0x4811 (Z03 §9.1), `so_ply_InitSkillEmpow` |
| `CharacterPassiveList::CharacterPassiveList` | FUN_00447200 | Z20 §6.5 (1000-bit passive set) |
| `SkillDataBox::sdb_SpecSkillStruct` | FUN_0046a410 | Z20 §5.1 |
| `ShinePlayer::sp_HPChangeCheck` | FUN_0055e130 | calls vt 0x4e8 and 0x484 and discards both: no effect (Z11, `&sethp`) |
| `learnSkill(o, skill, isPassive)` | FUN_005a1790 | GameDB 0x4801 NC_SKILL_SKILLTEACH_REQ `{u16 handle, u32 charNo, u32 charNo, u16 skill, u8 isPassive, u16 0xFFFF}` (17 bytes; layout as Z03 §9.4); the answers are Z03 §9.3. Only caller: the wedding reward `gds_NC_CHAR_WEDDING_DO_ACK` FUN_005a1830 (Z07) |

### 3.9 Open point: B31's player-rule twin

`ShinePlayer::so_mobile_ICanDamageTo` FUN_004361a0 (Z03 §3.3): in the type-4 KQ branch "same raid" is computed as
`p.raid (vt 0xa84) and d.raid exist and p.raid.number == p.raid.number`, i.e. any two raided players count as one raid
(original bug) Z18-B4. The normal branch compares p with d correctly. Z09-B31 is the mover copy.

---

## 4. Z04: items, equipment, set items, random options

Owner text: `Z04-items.md` (§1 data model, §5 equipment, §9 upgrades, §11 random options), knowledge Z04; persistence and
the `0x34xx` answers: `Z05-itemdb.md`. Answers the Z09 §31.5 "Items" points: `ItemAttr` vt 0x2c (§4.5), `so_ply_EquipmentChange`
and the view slots (§4.3), the `sp_DestroyItem` overloads (§4.4).

### 4.1 Item tables and `ItemDataBox` accessors

`ItemDataBox::idb_Load` FUN_00649780 (Z01 §2.3 "home") loads seven boxes into `itemdatabox.idb_BinData` and builds
`idb_index[itemID]` (`ItemDataBoxIndex`, 0x28 bytes: `data` ItemInfo*, `dataserv` ItemInfoServer*, `itemoption`
GradeItemOption*, `MovingShot`, `AttackAngle`, `SetItemIndex`, `HitTimeArray[3]`, `itemdroplog`, `ItemSortOrder`,
`eDelConditionType`, `pBuyItemData` ItemMoney*). The readers are the generic `bdb_ReadData` of §1.7 (key, row size):

| Function | Address | What it does / where it plugs in |
|---|---|---|
| `BinaryDataBox<ItemInfo>::bdb_ReadData` | FUN_00648a50 | `ItemInfo.shn`, key 0x4b67, row 0x17a (offsets: Z04 §1.2) |
| `BinaryDataBox<ItemInfo>::operator[](i)` | FUN_004ae550 | row `i`; `i` ≥ row count → `bdb_defaultblock` |
| `BinaryDataBox<ItemInfoServer>::bdb_ReadData` | FUN_00648b10 | `ItemInfoServer.shn`, key 0x12a2, row 0xde (`ISET_Index`, `RandomOptionDropGroup` +0x89, `ItemSort_Index` …) |
| `BinaryDataBox<ItemMoney>::bdb_ReadData` | FUN_00648df0 | `ItemMoney.shn`, key 0x37, row 0x42 `{IM_ItemIDX[32], IM_MoneyIDX[32], u16 IM_MoneyLot}` (540 rows): price of an item in "item money" (Z04 §2.2) → `idb_index[].pBuyItemData` |
| `BinaryDataBox<ItemSort>::bdb_ReadData` | FUN_00648ca0 | `ItemSort.shn`, key 1, row 0x20 (one column `ItemSort_Index`, 59 rows `IS_MYSTERYVAULT` … ): its row number is `ItemSortOrder`, matched by `ItemInfoServer.ItemSort_Index` (no match → "idb_Load : Invalid ItemSort Index", exit); the auto-arrange order of 0x304A (Z04 §12.5) |
| `ItemDataBox::idb_GetItemInxName(id)` | FUN_006487d0 | `ItemInfo.InxName` of `id`, null for 0xFFFF / unknown; 11 callers (mover / pet / riding logs and lookups) |
| `ItemDataBox::idb_iter_next(&i)` / `idb_iter_Get(&i)` | FUN_004900a0 / FUN_004900c0 | walk all `idb_Itemspacies` ItemInfo rows (`++i < count`; `Get` = `ItemInfo[i].ID`, 0xFFFF past the end); only user `DropItemListInGroup::dilig_StoreItem` FUN_0048e6b0 (Z09 §11.2: drop groups that name items by pattern) |

`ItemInvenDel.shn` (the seventh box; the reader is a folded copy shown as `BinaryDataBox<CollectCardMobGroup>::bdb_ReadData`, row
`{InxName[32], u32 DelCondition}`) sets `idb_index[].eDelConditionType`; its 19 rows (snowballs, eggs, `E_M_RentaBoard01…05`, …) are
all `DCT_LINKIN_ALL` (1), used by §4.4 `sp_ItemInvenDelete`.

### 4.2 Equipment slot rules: `EquipEnumChanger` and `ItemServerEquipTypeInfo`

`ItemServerEquipTypeInfo.shn` (34 rows; `ItemEquipTable g_ItemEquipTable`, loader FUN_00493140, Z01 §2.3 "moon";
`iet_GetArray(ISET_Index)` FUN_004930d0, null for an index ≥ 34) has one byte per equipment column: **1** = the item
goes into this slot, **2** = the item also covers this slot (whatever is there must come off), 0 = unrelated.
`ItemInfoServer.ISET_Index` selects the row. The global `EquipEnumChanger equipman` maps `ItemEquipEnum` (Z04 §1.1) to the
row's byte offset (`eec_Column[30]`, filled by its static initializer FUN_00695690; −1 = no column):

| Slot | 1 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 | 18 | 19 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Column | Head | Neckles | Body | AccBody | AccBack | LeftHand | AccLeftHand | RightHand | AccRightHand | Bracelet | RingA | RingB | CosEff | AccHip | Pant |
| **Slot** | **20** | **21** | **22** | **23** | **24** | **25** | **26** | **27** | **28** | **29** | 0, 2–5 | | | | |
| Column | AccPant | Boot | AccBoot | Ear | AccMouth | MiniMon | AccEye | AccHead | MiniMon_R | AccShield | none | | | | |

Examples from the 2016 table: row 22 `RightHand 1, LeftHand 2` (a two-handed weapon empties the left hand), row 23
`RightHand 2, LeftHand 1`, row 28 `RightHand 1` + `LeftHand / AccLeftHand / AccRightHand / AccShield 2`, row 3 `MiniMon 1,
MiniMon_R 1` (either minimon slot), row 18 `RingA 1, RingB 1`.

```pseudo
EquipEnumChanger::eec_Next(&i)                          @ FUN_00460e70
    do ++i while i ≤ 29 and eec_Column[i] == −1;  returns i ≤ 29        # iterates the 25 real slots, start i = −1
EquipEnumChanger::eec_GetColumn(&i, &slot)              @ FUN_00460f40
    0 ≤ i ≤ 29: slot = i, return eec_Column[i];  else slot = NONE, return eec_Column[0] (−1)
eec_EquipLocation(ItemInfoServer s, ItemBag equipment)  @ FUN_00460ff0
    row = iet_GetArray(s.ISET_Index); none → ITEMEQUIP_NONE (0)        # EQUIP answers 0x283, Z04 §5.1
    for each slot with row[column] == 1: if equipment[slot] is empty → return slot;  remember the first such slot
    return the first "1" slot (all occupied: the item replaces what is there), or NONE when the row has no "1"
eec_EquipSlotCheck(s, slot)                             @ FUN_00461a30   (MINIMON_EQUIP, Z04 §5.3)
    s and 1 ≤ slot ≤ 29 and row exists: row[column(slot)] == 1
eec_GetEquipSlotList(out[], &n, s)                      @ FUN_00461590
    append every slot with row[column] == 2                 # the extra slots a view item covers (§4.3)
eec_ConflictWithNewEquip(s, cells[], &n, equipment, lockList)   @ FUN_004611c0
    for each slot not yet in cells[] with row(s)[column] == 2 and an item in equipment[slot]:
        cells[n++] = {slot, cell}           # what the new item pushes off (lockList is not used)
eec_ConflictWithOldEquip(cells[], &n, equipment, newSlot, lockList)  @ FUN_00461360
    for each slot not yet in cells[] with an item w:
        w has no ItemDataBox row: stop scanning (return)
        w has no ItemInfoServer, or no equip row, or row(w)[column(newSlot)] == 2: cells[n++] = {slot, cell}
        # worn items that cover newSlot (e.g. a two-hander when a shield is equipped)
eec_ConflictWithNewViewSlot(equip, slots[], &n, s)      @ FUN_004616c0
    for each slot not yet in slots[] with row(s)[column] == 2 and ie_ViewSlot_GetItemID(slot) ≠ 0xFFFF: slots[n++] = slot
eec_ConflictWithOldViewSlot(equip, slots[], &n, newSlot)  @ FUN_00461840
    for each slot not yet listed whose view item v ≠ 0xFFFF: v unknown → stop;
        v without ItemInfoServer / equip row, or row(v)[column(newSlot)] == 2 → slots[n++] = slot
```

Callers: `sp_NC_ITEM_EQUIP_REQ` FUN_0052b8d0 (Z04 §5.1: location + both conflict lists, then the view-slot pair),
`sp_NC_ITEM_RINGEQUIP_REQ` FUN_0052c5b0 / `sp_NC_ITEM_MINIMON_EQUIP_REQ` FUN_0052d020 (location only), `sp_NC_ITEM_UNEQUIP_REQ`
FUN_0053a990 (view-slot pair), the view-slot functions `so_ply_ViewSlot_Equip` FUN_0052b110 (Z09 §17.8) /
`so_ply_ViewSlot_UnEquip` FUN_0052b3c0 (Z11 §3.4) / `so_ply_DecoActList_Cehck` FUN_0052b6b0 (Z05 §5.4), and
`so_RecalcEquipParam` FUN_004cab70 (Z12) through `iet_GetArray`. An item whose equip row is missing counts as covering
every slot in the two "Old" scans *(inferred: a data safety net; with the 2016 tables every equippable item has a row)*.

### 4.3 View slots and `so_ply_EquipmentChange`

`ItemEquipment` (the equipment box `p+0x7fd8`) carries `ie_ViewSlot[30]` (`EquipmentViewSlot {u8 bEquip, u8 nMainSlot,
u16 nItemID}`): slot *i* shows item `nItemID` put on through main slot `nMainSlot` (0 = slot not overridden). These are
the costume previews of `cViewSlotEquip` / `&vie` (Z09 §17.8, Z11 §3.4); `bEquip` is a "re-send this slot" mark set while
equipment changes (`so_ply_DecoActList_Cehck`, Z05 §5.4) and consumed by `so_ply_ViewSlot_EquipInfoSend` FUN_0052b5e0
(Z05 §5.1, named `EquipViewSlot_Flush` there). Nothing of it is stored in the DB.

| Function | Address | What it does |
|---|---|---|
| `ie_ViewSlot_Set(slot, main, id)` | FUN_00643630 | 1 ≤ slot ≤ 29: `{bEquip 0, nMainSlot main, nItemID id}` |
| `ie_ViewSlot_Clear(main)` | FUN_00643660 | 1 ≤ main ≤ 29: every one of the 30 slots whose `nMainSlot == main` → `{0, 0, 0xFFFF}` (the item and the slots it covers) |
| `ie_ViewSlot_ClearAll` | FUN_00643720 | all 30 → `{0, 0, 0xFFFF}` |
| `ie_ViewSlot_UseCheck(slot)` / `ie_ViewSlot_GetItemID(slot)` | FUN_00643750 / FUN_006437b0 | `nMainSlot ≠ 0` / `nItemID` (0xFFFF out of range) |
| `ie_ViewSlot_UseCheckAll` | FUN_00643780 | any slot with `bEquip` or an item |
| `ie_ViewSlot_SetEquipWork` / `GetEquipWork` / `ClearEquipWork` | FUN_006437e0 / FUN_00643800 / FUN_00643820 | the `bEquip` mark (1…29) / clear all 30 |
| `ie_GetItemID(slot)` / `ie_GetUpgrade(slot)` | FUN_00643840 / FUN_00643880 | what sight sees: the view item when `nMainSlot ≠ 0`, else the real item / its upgrade (attr vt 0x30; 0 for a view slot) |
| `ie_DecoActList_Insert(id)` | FUN_00643940 | appends to `ie_DecoActList[30]` while `ie_DecoActCount` < 30 (silently drops more); filled by `sp_DecorationActivCheck` FUN_00534c60 (Z09 §2.4, Z12) |
| `ie_DecoActList_ClearAll` / `_Count` / `_Get(i)` | FUN_006438c0 / FUN_00643970 / FUN_00643980 | reset to 30 × 0xFFFF, count 0 / the count / entry *i* |

```pseudo
ShinePlayer::so_ply_EquipmentChange(itemID, slot, ItemTotalInformation* info, broadcast)   vt 0xd60   @ FUN_0052ce60
    cls = itmattcontainer[itemID]          # ItemAttributeClassContainer::operator[] FUN_0063e2a0; 0xFFFF / unknown /
                                           # class > 38 → iacc_default (the base class)
    item = info ? info.iti_itemstruct : { itemid = itemID, attribute zeroed }
    len = cls.iac_equipbriefinfo (vt 0x24)(p.handle, g_buf, item, slot, &titleMob, &titleLevel)
    len ≤ 0: return                                        # amulets and bracelets: nothing is shown
    if p.so_GetCharacterTitle (vt 0x420).m_CurrentTitle == 10 (the weapon title):
        CCharacterTitle::SetCurrentTitle(t, 10, titleLevel, titleMob, null)   @ FUN_0062e2e0
        # titleMob / titleLevel are written only by the weapon class; for every other item they are uninitialised
        # stack bytes (disassembly 0x52ceee–0x52cf25: only their addresses are pushed) (original bug) Z18-B9
    broadcast == 1: so_AllOfRange broadcast of g_buf (len) around p      # AxialListPacketBroadcast, sight range
    else: send to p only (so_GetGameSocketStream vt 0x2fc → send)
```

The four packets, one per class group (`vt 0x24` implementations):

| Builder | Address | Classes | Packet (payload, 2016 PDB struct *(pdb2016)*) |
|---|---|---|---|
| `ItemAttributeClass::iac_equipbriefinfo` | FUN_0063f7e0 | base + 29 classes (and 0xFFFF) | `0x1C04 NC_BRIEFINFO_UNEQUIP_CMD {u16 handle, u8 slot}` (3) |
| `ItemAttrCls_Decoration::iac_equipbriefinfo` | FUN_0063f910 | Decoration, CostumWeapon, CostumShield | `0x1C02 NC_BRIEFINFO_CHANGEDECORATE_CMD {u16 handle, u16 item, u8 nSlotNum}` (5) |
| `ItemAttrCls_Armor::iac_equipbriefinfo` | FUN_0063f8d0 | Armor, Boot, Shield | `0x1C03 NC_BRIEFINFO_CHANGEUPGRADE_CMD {u16 handle, u16 item, u8 upgrade, u8 nSlotNum}` (6) |
| `ItemAttrCls_Weapon::iac_equipbriefinfo` | FUN_0063f820 | Weapon | `0x1C05 NC_BRIEFINFO_CHANGEWEAPON_CMD {CHANGEUPGRADE upgradeinfo, u16 currentmobid, u8 currentkilllevel}` (9) |
| `ItemAttrCls_Amulet::iac_equipbriefinfo` | FUN_0063f810 | Amulet, Bracelet | returns 0: nothing |

Weapon: `upgrade` = `weapon.upgrade`; the title mob is the `mobkills[k]` entry (3 × `{u16 monster, u32 count:28}` at attr
+7) whose monster equals `weapon.CharacterTitleMobID` (+0x19): `currentmobid` = that monster, `currentkilllevel` =
`CWeaponTitle::GetLevel(monster, count)`; no match → `0xFFFF, 0`. `upgradeinfo.nSlotNum` (payload +5) is never written:
a stale `g_buf` byte (original bug) Z18-B10; the client ignores it.

Client (`GameFrameWork`, 2016 client; names from the 2017 PDB *(pdb2017)*): `On_NC_BRIEFINFO_UNEQUIP_CMD` FUN_004a08f0
(`Char::UnEquip(slot)`; weapon slot 12 with the weapon title shown → title cleared; slot 17 → aura effect re-enabled),
`On_NC_BRIEFINFO_CHANGEDECORATE_CMD` FUN_004a0710 (`Char::Equip(item)`, remembers `nSlotNum`; slot 17 hides the aura),
`On_NC_BRIEFINFO_CHANGEUPGRADE_CMD` FUN_004a0780 (`CharShape::Equip(item, upgrade)`, `Char::Equip`),
`On_NC_BRIEFINFO_CHANGEWEAPON_CMD` FUN_004a07e0 (`Char::Equip(item, upgrade)`; if that char shows title type 10 and the
item's class is 5 (weapon): `currentmobid` 0xFFFF → title off, else `WeaponTitleTab::GetWeaponTitleStringByLevel(mob, level)`).
No error codes. Layouts in `annotations/Z18.json`.

Callers of vt 0xd60 are only the view-slot functions (`so_ply_ViewSlot_Equip` / `_UnEquip` / `_UnEquipAll` /
`_EquipInfoSend`), all with `broadcast = 1`; the brief info of a real equip / unequip goes out through the 0x3411 /
0x3414 answers (Z05 §5.1). In `so_ply_ViewSlot_EquipInfoSend` FUN_0052b5e0 the item id is not reset per slot: a marked slot
without a view item re-sends the id of the previous marked view slot (original bug) Z18-B11.

### 4.4 Destroying items: the `sp_DestroyItem` family and `0x3459`

All of them send `0x3459 NC_ITEMDB_DESTROY_REQ` to the Character DB (`sock2gameDB`) and reserve the cells under the
current lock index (Z04 §1.4); the DB answer `0x345A` applies the reservations (Z05 §6.4). Payload (layout as Z11 §4.3,
completed here; the 2016 PDB has no struct for it):

```
+0x00 u16 handle      +0x02 u32 charNo (vt 0x344)     +0x06 u16 lockIndex
+0x08 u8  flags: bits 0–6 = number of keys, bit 7 = one cell keeps a rest (partial destroy)
+0x09 u16 itemID      +0x0b u64 key      +0x13 u16 attrOffset (payload offset of the attribute bytes)   +0x15 u16 inven
      # +0x09…+0x16: the rewritten cell, valid only with bit 7
+0x17 u64 keys[count]   then (bit 7) the rewritten cell's attribute bytes (attr vt 4)
```

```pseudo
sp_DestroyItem(h, cell, ITEM_INVEN* inv)        "sp_DestroyItemA"                     @ FUN_00527870
    0x3459 { h, charNo, lockIndex, flags = 1, keys = [cell.key] }  (0x19 + 8 bytes)
    if inv is an equipment cell (type 8): lock vt 0x54 (equip location, slot, cell)
    lock vt 0x30 icl_ClearItem(lockIndex, cell, inv, inv)
    if type 8: lock vt 0x50 (unequip reservation, slot, cell, −1, 0)
    lockIndex += 1;  return true
    # callers: sp_ItemDelete FUN_00451090, sp_HorseItemSave FUN_0045e810, so_ply_Script_CostumeTakeOff FUN_005191b0,
    # sp_UseAmountHP / SP FUN_0059c500 / FUN_00596e30, so_ply_ChestBoxOpenAck FUN_00598e90, and the overload below

sp_DestroyItem(h, itemID, ItemBag* bag, invenType)                                    @ FUN_00527a70
    first cell of `bag` holding itemID that no lock reserves (UnlockedInventoryIterator, ItemBoxIterIdent):
        sp_DestroyItemA(h, cell, invenType << 10 | slot);  none: false
    # callers so_scene_EraseItem FUN_0050dba0 (equipment, type 8; Z09 §17.8 cItemErase) and so_ply_DivorceProcess
    # FUN_0059f550 (the wedding present, from two bags)

sp_DestroyItem(h, itemID, count, LinkInformTemplete* link)   "sp_DestroyItemB"         @ FUN_00527b60
    owned = sum of lots (attr vt 0x1c) of itemID over the unlocked inventory (type 9) cells
    count ≤ 0: count = owned;  count > owned: assert "…Try to delete too many lot", false
    for each unlocked cell c with itemID, in slot order:
        if lot(c) ≤ count: keys += c.key; lock vt 0x30 (clear c); count −= lot(c); stop at 0
        else:  copy = c with lot − count (attr vt 0x20); lock vt 0x40 (replace c by copy)
               flags |= 0x80; itemID/key/inven/attrOffset = copy; attribute bytes after the keys; stop
    if link: lock vt 0x6c(lockIndex, link)      # a map link carried out when the DB confirms *(inferred: slot not
                                                 # opened)*; instance-dungeon entry fees: wms_…LEVEL_SELECT_JOIN… FUN_00485b90, zls_…FIND_RNG… FUN_00487510)
    send; lockIndex += 1; true
    # callers: the Lua cInvenItemDestroy (Z09 §17.8), so_scene_EraseItem, ride feeding FUN_0045f9e0, the wedding
    # propose answer FUN_0059f900 (ring) and hall guest entry FUN_0059fcb0 (invitation card), the two dungeon entries above

sp_DestroyItem(h, ItemTotalInformation* info, ITEM_INVEN* inv)   (small-item box)        @ FUN_00566f00
    0x3459 { h, charNo, lockIndex, keys = [info.key] }; lock vt 0x44(lockIndex, inv, empty item, inv, inv)
    # replace the small cell by an empty one *(inferred from the arguments)*; icl_IncIndex
sp_SmallItemDelete<ItemInform_ActionItem>(cell, type, slot, ShineDateTime*)              @ FUN_00569b80
    cell: ItemInform_ActionItem::sii_Export(cell → info) (FUN_00643440: key, itemid, lot = iiai_Attribute);
    copies the char name into the name ring (unused here); sp_DestroyItem(p.handle, &info, type << 10 | slot)
    # only caller sp_SmallChargedItemLimitCheck FUN_0056b900 (expired action items, Z09 §2.4)

sp_ItemInvenDelete(DelConditionType cond)                                             @ FUN_0051c590
    one 0x3459 with every unlocked inventory item whose idb_index[].eDelConditionType == cond (≠ NONE); each cell is
    re-checked with lock vt 0x0c and reserved with vt 0x30; nothing found → nothing sent
    # only caller sp_NC_MAP_LOGINCOMPLETE_CMD FUN_00443390 with DCT_LINKIN_ALL (1): the ItemInvenDel.shn event items
    # (§4.1) vanish at every map login
```

The 7-bit key count of `sp_DestroyItemB` and `sp_ItemInvenDelete` wraps past 127 keys as in Z11-B8 (original bug)
Z18-B13 (latent: 19 such event items; a 128-cell destroy of one item id is needed for B).

### 4.5 Drop attributes (`ItemAttr` vt 0x2c), random options and card drops

`iac_DropItemMake(ItemTotalInformation* item, ItemGroup* row, int roll, u16 mobID)` is vt 0x2c, called by the mob
drop `dilig_Drop` FUN_0048e260 (Z09 §11.2, `roll` = rand 0…999) and the Pine `itemdrop` node (Z09 §24.1) with its synthetic
row. `ItemGroup` (`DropItemStruct::ItemGroup`, 0x64): `+0x3c ig_quantitylow`, `+0x3e ig_quantityhigh`, `+0x40
ig_upgraderate[16]`. No implementation reads `ig_itemid` (the uninitialised name bytes of `itemdrop`'s row are harmless).

| Implementation | Address | Classes | Effect |
|---|---|---|---|
| `ItemAttributeClass::iac_DropItemMake` | FUN_0063f940 | 16 classes (ActionItem, Amount, BindItem, Capsule, Costum*, Decoration, Furniture, GBCoin, ItemChest, KingdomQuestItem, MiniHouseSkin, Pet, Riding, SkillScroll, WeaponTitleLicence) | nothing, true |
| `ItemAttrCls_ByteLot::iac_DropItemMake` | FUN_0063fab0 | ByteLot, Enchant, Feed, NoEffect, RecallScroll, UpSource, Upgrade Red/Blue/Gold gems | u8 lot = low + (high − low + 1)·roll / 1000 |
| `ItemAttrCls_WordLot::iac_DropItemMake` | FUN_0063f950 | WordLot, ActiveSkill, KQStep, QuestLot | same, u16 lot |
| `ItemAttrCls_DwrdLot::iac_DropItemMake` | FUN_0063f990 | DwrdLot | same, u32 lot |
| `ItemAttrCls_Amulet::iac_DropItemMake` | FUN_0063e6c0 | Amulet, Bracelet | `upgrade` = 0, then `iac_ClearItemOptionUpgrade` (vt 0x84, FUN_0063e7e0): the 8 upgrade-option elements zeroed, `UpgradeOption.optionnumber` = 1 |
| `ItemAttrCls_Armor::iac_DropItemMake` | FUN_0063fa60 | Armor, Boot, Shield | see below; `option.optionnumber` = 1 |
| `ItemAttrCls_Weapon::iac_DropItemMake` | FUN_0063f9d0 | Weapon | see below; `mobkills[3].monster` = 0xFFFF, counts / title 0, `option.optionnumber` = 1, 3 gem sockets `{0xFFFF, 0}`, `maxSocketCount` = `EnchantSocketRateData::GetSocketRateData()` (FUN_0064c5c0, `sm_pSocketRateData`) vt 0 (itemID), `createdSocketCount` 0 |
| `ItemAttrCls_CardCollect_Close::iac_DropItemMake` | FUN_0063faf0 | closed collection card | `g_CardCollectMake(mobID, &card)` (below); its result is the drop decision |
| (folded, FUN_00510f50) | FUN_00510f50 | open collection card | returns 0: an open card never drops |

```pseudo
Armor / Weapon upgrade from the group row:
    for i in 0…15: if roll < ig_upgraderate[i]: upgrade = i; break       # per-entry test, not cumulative
    upgrade = 0                                                          # unconditional overwrite
    # the Upgrade00…15 weights of ItemDropGroup never take effect (original bug) Z18-B8; drops get their upgrade
    # only from dilig_Drop's upMin…upMax roll (Item_ForcedUpgrade, Z09 §11.2)

g_CardCollectMake(mobID, ShineItemAttr_MobCardCollect_Unident* card)       @ FUN_00628880
    mob row (mobdatabox) → CollectCardMobGroup by mob InxName (g_CollectCardMobGroup_MobGroup); none → false
    card.Group = CC_CardMobGroup; card.CardID = 0xFFFF; W = 0
    for each CollectCard c of that group (g_CollectCard_MobGroup):
        w = CollectCardDropRate[c.CC_CardID].CC_CardGetRate (linear search; a card without a row would be a null read,
            latent: all 334 cards have one); W += w
        if rand(1 000 000)·W / 1 000 000 < w: card.CardID = c.CC_CardID       # one-pass weighted pick (reservoir)
    CardID ≠ 0xFFFF: c = CollectCard[CardID]; card.Star = 0, S = 0
        for each CollectCardStarRate r of c.CC_CardGradeType: S += r.CC_StarRate; same pick → card.Star = r.CC_StarLot
        return card.Star ≠ 0
    return false
    # the card table semantics (groups, stars, rewards) are Z07's collection cards (part 4 of this item)
```

```pseudo
ItemRandomOption::RandomOptionTable::rot_FillOption(ItemOptionStorage* s, RandomOptionDatum* d)   @ FUN_00493590
    s.optionnumber = 1 (bit 0 "identified", count 0)
    d or d.rod_RandomOptionMaker (RandomOptionList L) null: assert "Null datum", return
    r = rb_1000(); n = first rol_Count entry {count, weight} with r < weight (r −= weight per entry)   # RandomOptionCount.shn
    n < 1: assert "Option Counter bug", return (no options)
    n = min(n, number of option types of L) ("Too many option"), min(n, 50) ("Large then")
    idx = 0…types−1 shuffled (swap idx[i] with idx[rand(types)] for each i)
    for k in 0…n−1: t = L.rol_Option[idx[k]] (0x14 bytes: {u8 type, vector {min, max, weight}})
        pick a range by weight with rb_1000 as above (none: 0…0); min > max → assert "Min/Max error", min = max
        s.optionlist[k] = { type, min + rb_largerandom(max − min + 1) }
    s.optionnumber = (s.optionnumber & 1) | n << 1
    # optionlist has 8 elements but n is capped at 50 (original bug) Z18-B14, latent: RandomOptionCount.shn counts are 1…5
```

`RandomOptionTable::operator[](name)` FUN_00493ff0 (lookup by `rol_Index`, shared `returnstr` result) is Z11 §9.3.
Callers of `rot_FillOption`: mob drops and `itemdrop` (Z09 §11.2 / §24.1), treasure chests (Z09 §10.10), `&makeitem` (Z11 §4.3, Z11-B13).

### 4.6 Upgrade helpers

```pseudo
Item_GetUpgradeLimit(itemID)                            @ FUN_0053b2a0
    ItemInfo.UpLimit (+0xf0); unknown / mismatching id → 0 (assert on mismatch)
    # callers Item_Upgrade FUN_0053ca10 (Z04 §9.4), Item_ForcedUpgrade FUN_0053c510
Item_AdjUpgradeLevel(SHINE_ITEM_STRUCT* it, s8 delta)   @ FUN_0053b560
    by ItemInfo.Class: amulet / bracelet: amulet.upgrade (attr +8) += delta; weapon / shield / armor / boot:
        upgrade (attr +0) += delta; other classes: 0, unchanged.  returns the new level
Item_AdjFailCount(it, n, set)                           @ FUN_0053b700
    same classes: set ? upgradefailcount = n : += n   (amulet / bracelet attr +0xa, the others attr +2); returns it
    # both: an id without ItemDataBox row dereferences a null index (original bug) Z18-B12, latent (callers pass items
    # they already looked up). Callers: the three UPGRADE handlers (Z04 §9.1–9.3), Item_ForcedUpgrade, MIX_ITEM (§12.12)
```

### 4.7 Item use broadcasts and use-effect table

```pseudo
ShinePlayer::sp_ItemUseBroadcast(UIE_Functions* f, itemID)      @ FUN_0053f840
    f.broadcast == 0: nothing
    broadcast to the sight range: 0x3029 NC_ITEM_SOMEONEUSE_CMD { u16 user = p.handle, SHINE_XY_TYPE useloc = p.position,
        u16 useditem = itemID }   (12 bytes, 2016 PDB struct)
    # only caller smo_ply_ItemUse FUN_0053fd10 (the use path of Z04 §6.1)
    # client On_NC_ITEM_SOMEONEUSE_CMD FUN_004af820: char by handle, ItemInfo row of useditem → char vt 0xc4, then
    # EffectMgr::CreateEffect(the row's InxName): plays the item's use effect on that character; useloc is not read

Send_SETITEMHEALEFFECT(ShineObject* o, isheal, amount)        @ FUN_005cfbb0
    o null: nothing;  broadcast around o: 0x206F NC_ACT_SETITEMHEALEFFECT { u16 who = o.handle, u8 flag (bit 0 isheal),
        u16 hpchange = amount (truncated to 16 bits) }   (5 bytes)
    # caller RecoverTypeEffect::_execute FUN_005cfc70 (Z09 §28.8: HP recover kinds 0 / 1 isheal 1, HP-damage kinds 4 / 5 isheal 0)
    # client On_NC_ACT_SETITEMHEALEFFECT FUN_0049bd20: TextEffMgr::AddNumTextEff(who, hpchange, isheal·4 | 1): a floating number
```

`UseEffect::UsedItemEffect` (`g_ItemUseTable`, Z04 §6.1): `uie_FuncStruct[uie_MaxItemID]` of `UIE_Functions {ItemUseEffect*
useeffectstruct, UseItemBase* useitemclass, SkillDataIndex* useskill, u8 broadcast}`. `operator[](id)` FUN_004878e0 (id ≥
max → entry 0); `uie_SetChargedBuffer(id, actor, skill)` FUN_005963e0 (default effect struct, actor, skill: how the charged
item tables of 11 loaders register their items); `uie_UseSkillID(name)` FUN_0059cba0 (Z20 §7 table: skill by name, active only).

### 4.8 Small state holders, set items and the rest

| Function | Address | What it does / where it plugs in |
|---|---|---|
| `CSellItemManager::CSellItemManager` | FUN_0050eb60 | the buy-back list `p+0x2ac38` (Z04 §2.5): `List<SellItemInfo>` of 42 (`l_MakeList(0x2a)`) over `simg_SellItemNode[42]`, each item cleared (key −1, itemid 0xFFFF); built by the player ctor FUN_0055bc80 |
| `ItemAccountStorage::ItemAccountStorage` / `ItemRewardStorage::ItemRewardStorage` | FUN_00644910 / FUN_00644c20 | 576 (0x240) / 24 inventory cells of 0x74 bytes: account storage `p+0x18258` and reward inventory `p+0x28760` (Z04 §1.1) |
| `InventoryCellLockList::icll_ClearItem` | FUN_00440d20 | `icll_AllLock = 0` and erase every `LockedCell` of `icll_List`; at login complete (no reservation survives a map change) |
| `ItemBag::ib_GetItemLot(id)` | FUN_00642e80 | sum of lots (attr vt 0x1c) of `id` over the whole bag; via `so_GetItemLot` FUN_0055da60 and the minimon auto-use routines (Z07 §3.6) |
| `ItemBoxIterEmpty::ItemBoxIterEmpty(bag, effect)` | FUN_0043c050 | an iterator over empty cells; limit = `bag.vt[4](effect)` (usable size with the extra-inventory effect) or `bag.vt[8]()` (full size); 18 users (`sp_GetEmptyItemInventoryCount` FUN_00560910, EQUIP, RELOC, chests …) |
| `ItemTotalInformation::iti_clear` | FUN_00470cf0 | key = −1, item struct zero, itemid 0xFFFF |
| `ItemTotalInformation::iti_fill2buffer_whole(cls, inven, buf)` | FUN_006407d0 | writes `{u64 key, u16 inven}` then the class's item bytes (attr vt 4) and returns the end; the record of the inventory / storage / chest lists (`ci_FillBufferTotal` FUN_006444b0, `ci_FillBufferInventoryTotal` FUN_00644220, `simg_FillBuffer_Server` FUN_0050e4d0, `tcm_PutInto` FUN_00595f50, `ilm_PutInto` FUN_00595890, `isb_FullBufferItem2Server` FUN_00455860) |
| `ItemInform_ActionItem::sii_Export` | FUN_00643440 | §4.4 (small-item cell → ItemTotalInformation); also the small-bag lists of Z12 §6.7 |
| `ShinePlayer::sp_GetAutoPick` | FUN_00560370 | `sp_MiscFlag.IsAutoPickUp` (Z12 §7.1, Z07 §3.6) |
| `ShinePlayer::sp_GetItemWhoEquip_ClassGroup` | FUN_005630f0 | class mask of the player's class line for `sp_KQReward` FUN_0052da70 → `tcm_ItemMake(…, 7, row, mask)`: `smo_CharClass.cc_ClassType` (vt 0x48, the line's base class 1 / 6 / 11 / 16 / 21 / 26) → bits base…base+4 (Sentinel 26…27); no class object or another value → 1 |
| `SetItemData::SkillEffect::operator[](i)` / `se_Clear` | FUN_00510010 / FUN_005105e0 | `se_Argument[17]` (per `SetIndex`, base 1000 = ×1; i ≥ 17 → 1000) / all 17 = 1000; the set-item skill multipliers read by heal-over-time, enchant, cooldown, SP check (Z03, Z12) and cleared by `smo_ply_SetItemEffect` FUN_00510c80 and `so_Routine` |
| `SetItemData::SetItemAbstateEffect` ctor | FUN_00510350 | Z11 §9.2 (4 slots `{index 0, Argument_Base1000 1000}`) |
| `SetItemData::EffectDescription::ed_Compare` | FUN_004a2ed0 | `*(u16*)a − *(u16*)b`; a folded comparator shared by 12 sorted tables (`siel_AppendEffect` FUN_005104c0, MiscDataTable, MagicContainer, MobAttackSequence) |
| `ItemLotInspector` ctor / `ili_Clear` / `ili_Reset` | FUN_00490be0 / FUN_00490c30 / FUN_0043bf90 | below |

**`ItemLotInspector`** (`sp_ItemLotInspector`, the `p+0x1ea8` of Z05 §1.1): a 64-entry ring (`ili_ArrayPointer` mask 0x3f)
of `InspectNote {ili_Action, ili_ItemID, ili_From[2], ili_To[2] {Activ, Locate, Item}, ili_MoveLot, ili_TotalLot,
ili_StorageCount}` recording each RELOC / SPLIT (Z04 §4) as a dupe check. The handlers fill the current note
(`ili_SetTo(k, inven)` FUN_005317b0, `ili_TotalLotFrom(p)` FUN_005317e0 = `so_ply_CalcTotalLot` vt 0x970 FUN_00490c60:
lots in inventory + account storage when it is open); the DB answer calls `so_ply_ItemLotInspecting(check)` FUN_00491f90
(Z05 §1.1 / §4, named `ItemLotInspector_CheckAndReset` there): `check` → `ili_Check` FUN_00491c30, then advance the ring and
clear the new note. `ili_Check`: no action → ok; mini-house / reward-box moves are skipped; otherwise `ili_ItemCheck`
FUN_004919d0 (each "from" item id = the note's id) and the total lot must equal the recorded one; any mismatch writes
`ItemMSLog` (" ItemID not match ", " From0 Null ", " TotalItemNumber Not Match ") and `ili_History` FUN_00490cf0 (dumps
all 64 notes: `Act`, `From0/1`, `To0/1`, `MoveLot`, `TotalLot`). Nothing else happens (Z05-B3: the result is ignored).
ctor: mask 0x3f, pointer 1, note cleared; `ili_Clear` (all 64 notes: item 0xFFFF, action 0) and `ili_Reset` (advance +
clear) run at login complete (Z01 §6).

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

## 6. Z07: character titles, collection cards

Z07 §1.3 covers the title list arriving from the WM (0x1031 → client 0x1049), Z08 §7.2 the client's "set current
title" request 0x6001 and the title → abstate table, Z09 §17.8 the Lua counter `cCharTitleAddValue`, W04 §7 / D04 §4.2
the WM and DB side of dept 24 (NC_CT). This section adds the zone's title objects, the unlock check and the Lua grant.

### 6.1 Title objects

`ShinePlayer::sp_CharacterTitle` (`p+0x29638`, returned by vt 0x420 `so_GetCharacterTitle`) is a
`CCharacterTitleZone : CCharacterTitle` (0xcd0 bytes *(pdb2016)*):

| Offset | Member | Meaning |
|---|---|---|
| +0 | `m_pCharacterTitleData` | → `gCharacterTitleData` (`CharacterTitleData.shn`, rows `CHARACTER_TITLE_DATA` 0xac: Type, Permit (0 `TPT_PERMIT`), Refresh, then 4 × {Title[32], Value, Fame}) |
| +4 | `m_Titles[128]` | `CT_TITLE`, one byte per title type: 2 bits per element 0–3 = `CT_ELEMENT_VALUE` (0 UNKNOWNED, 1 KNOWNED, 2 USABLE, 3 USE) |
| +0x84 / +0x88 | `m_NumOfView` / `m_ViewArray[512]` | `CT_VIEW {Type, ElementNo}` list of the elements the player has (what 0x1049 and the save send) |
| +0x488…+0x48c | `m_CurrentTitle`, `m_CurrentTitleElement`, `m_CurrentTitleMobID`, `m_pTitle` | the title worn and its display string |
| +0x490 | `m_pPlayer` | owner |
| +0x498 | `m_TitleValues[128]` | `TitleValueStruct {u64 TitleValue, int bTitleSave}`: the per-type progress counters (Z09 §17.8 `TitleAddValue`) |
| +0xc98… | money give / beg, killed-by-mob, party join, booth / auction seller, upgrade item | anti-farming memory of the `CT_*` counter functions (the 30 s rules, Z06 §1.4) |

| Function | Address | What it does |
|---|---|---|
| `CCharacterTitleZone::CCharacterTitleZone(data)` | FUN_005ca5c0 | base ctor `CCharacterTitle(data)` FUN_0062e4e0, `m_pPlayer = null`, `m_TitleValues` zeroed (0x800 bytes); from the player ctor and the static `ShineObject` default object |
| `CCharacterTitleZone::ctz_SetObject(p)` | FUN_005ca610 | `m_pPlayer = p`; from the player ctor and `FieldMap::fm_Init` FUN_00464bc0 |
| `CCharacterTitleData::GetGroupData(type)` | FUN_0062df60 | row `type` of `CharacterTitleData.shn` or null (`type ≥ nNumOfRecord`) |
| `CCharacterTitleData::GetTitleValue(type, e)` / `GetTitleFame(type, e)` / `GetTitleString(type, e)` | FUN_0062e000 / FUN_0062e070 / FUN_0062df90 | `Value<e>` / `Fame<e>` (0 when out of range) / `Title<e>` (`szCTNull` when out of range) of the row |
| `CCharacterTitleData::IsTitlePermit(type)` | FUN_0062e0e0 | `row.Permit == TPT_PERMIT` |
| `CCharacterTitle::GetTitleStatus(type, e)` | FUN_0062e180 | the 2-bit element value (UNKNOWNED for type ≥ 128 or e > 3) |
| `CCharacterTitle::IsUnknownedTitle(type, e, mob)` / `IsKnownedTitle(type, e, mob)` | FUN_0062e1f0 / FUN_0062e220 | for type 0 and 10 (weapon title): 0 / 1; else status == 0 / status **> 0** (`mob` unused) |
| `CCharacterTitle::SetTitleStatus(type, e, v)` | FUN_0062e440 | writes the 2 bits, then `AddView(type, e)` FUN_0062e280 (append `{type, e}` to `m_ViewArray` unless present; at most 128 × 4 = 512 distinct pairs fit) |
| `CCharacterTitleDataStateServer::GetStateData(type, e)` | FUN_005ca9b0 | `&m_CT_DataState[type × 4 + e]` (type < 128, e < 4, else null): the title → abstate rows (Z08 §7.2 `DAT_1328c128`); read by `sp_NC_MAP_LOGINCOMPLETE_CMD` and `sp_ReviveNow` FUN_0057d290 to apply the worn title's abstates |
| `ShinePlayer::sp_SetCharTitleChangeAvailableTime(t)` | FUN_00560900 | `sp_NextCharTitleChangeTime` (`p+0x2aa48`) = t: login complete sets 0, 0x6001 sets `g_Now + 100` (Z08 §7.2, 10 s) |

```pseudo
CCharacterTitleDataStateServer::Read(file, …)             @ FUN_005ca790
    # gCharacterTitleDataStateServer = 512 × CT_DataState {u8 nStateNum; 6 × {u8 nStrength, AbStateStr* pAbStateDic,
    #   pAbStateMainDic}} (0x4c each) + the reader; file ../9Data/Shine/CharacterTitleStateServer.shn
    #   (loaded at start-up, "Fail to read CharacterTitleStateServer.shn"); columns Type, TitleLV, StateName[32], Strength
    read the file (failure: return 0); clear all 512 entries
    for each row: d = &m_CT_DataState[row.TitleLV + row.Type × 4]       # neither index is range-checked
        n = d.nStateNum; if n > 6: return 0                              # n == 6 passes (original bug) Z18-B20
        d.StateData[n] = { nStrength = row.Strength, pAbStateDic = as_FromName(row.StateName) }
        unknown state: assert "CCharacterTitleDataStateServer::Read : pAbStateDic is NULL. …"; return 0
        if its MainStateInx is not "-": pAbStateMainDic = as_FromName(MainStateInx) (unknown: return 0)
        d.nStateNum = n + 1
```

The 2016 table has 823 rows for 299 (type, level) pairs, at most 6 per pair and types ≤ 127, levels ≤ 3, so neither
gap is reached by the shipped data.

### 6.2 Unlocking titles: `CheckNewTitle`

Every progress change ends here: `TitleAddValue` / `TitleSetValue` FUN_005cbc20 and the 21 `CT_*` counter functions
(`CT_LevelUp` Z11 §7.3, `CT_ItemUpSuccess` Z05 §8.1, the money / booth counters Z06 §1.4, `CT_Chatting` / `CT_AddFrined` Z08
§7.2, …).

```pseudo
CCharacterTitleZone::CheckNewTitle(t, type) → int          @ FUN_005cb5f0
    row = GetGroupData(type); if !row or !IsTitlePermit(type): return 0
    V[e] = GetTitleValue(type, e), e = 0..3;  S[e] = GetTitleStatus(type, e);  x = m_TitleValues[type].TitleValue (u64)
    switch type:
      9 ID_NOKILLED_BY_MOB:  if x ≠ 0: return 0                 # died to a mob at least once
                             x = p.so_GetLevel (vt 0x4d8)        # then "reach level V[e] without dying"
      6 ID_MONEY_GIVE:       threshold = V[e] × 1 000 000       # values in gold (copper × 10⁶)
      7 ID_MONEY_BEG:        threshold = V[e] × 1 000
      0x2b ID_CHAR_TITLE:    x = x × 100 / 512                  # owned elements in percent of 128 × 4
      15 ID_MY_GUILD_GRADE:  as below, for all four elements, and then for each element with x < V[e] and S[e] ≥ 2:
                             SetTitleStatus(type, e, KNOWNED)   # the title is taken back when the grade drops
      3, 4, 8, 11–14, 16–42, 45–56, 58–116, 120–127 (counters): threshold = V[e]
      0, 1 EXP, 2 CLASS, 5 MONEY, 10 WEAPON_TITLE, 44 FAME_COUNT, 57 CLBETA_TITLE, 117–119 OLYMPIC_MEDAL_*: return 0
                             # never unlocked here: granted by other code or by script (§6.3)
    for e in 0..3: if x ≥ threshold[e] and S[e] < 2: r = SetTitleUsable(type, e)
    return r of the last call (0 when none ran)

CCharacterTitleZone::SetTitleUsable(t, type, e)            @ FUN_005cb0b0
    fame = GetTitleFame(type, e); if fame ≠ 0: p.so_GainFame (vt 0x20)(fame); p.so_ply_SaveFame (vt 0x450)()
    return SetTitleStatus(type, e, USABLE)

CCharacterTitleZone::SetTitleStatus(t, type, e, v) → 0/1   @ FUN_005caf70
    old = GetTitleStatus(type, e); if !CCharacterTitle::SetTitleStatus(type, e, v): return 0
    if old ≠ v:
        info = CT_INFO { Type = type, ElementNo = e, ElementValue = v }
        p ← 0x6004 NC_CT_SET_CMD { CT_INFO Info }                                        @ Send_NC_CT_SET_CMD FUN_005cab90
        Character DB ← 0x6005 NC_CT_DB_SET_CMD { u16 handle, u32 charNo, CT_INFO Info } @ Send_NC_CT_DB_SET_CMD FUN_005cac90
            (charNo −1 or 0: assert "Send_NC_CT_DB_SET_CMD : invalid charregistnumber" / "… charregistnumber ", not sent)
        if p has a name and charNo ≠ −1:
            CAnnounceSystem::AnnounceSystem_CharacterTitle(gAnnounceSystem, name, type, e)   @ FUN_005b9100
                row 6 of the announce table; if e ≥ row+0x104 (minimum element):
                    WM ← 0x6401 NC_ANNOUNCE_Z2W_CMD type 6, text = sprintf(row+4, name, GetTitleString(type, e))
                    (Send_PROTO_NC_ANNOUNCE_Z2W_CMD FUN_005b8d30, as the megaphone in Z04 §6.4)
    return 1
```

`SetTitleStatusZone` FUN_005ca6d0 (Z07 §1.3, Z08 §7.2) writes the bits without any packet; 0x6001 calls it first so the
following `SetTitleStatus` sees no change and stays silent.

The client's `On_NC_CT_SET_CMD` FUN_004a97f0 appends `{Type, ElementNo}` to its title list (no duplicate check), prints
TextData 0x3564277a "Character Title [%s] acquired." with the title string, opens play guide 0x2c and refreshes
`CharTitleWin`. It ignores `ElementValue`. So every status change reaches the player as "acquired", including the
guild-grade take-back to KNOWNED, which is also announced world-wide when the element passes the announce minimum
(original bug) Z18-B17.

### 6.3 Lua `cAddCharacterTitle(charNo, type, element)`

```pseudo
cAddCharacterTitle(L)                                      @ FUN_005eb310   (registered by ls_FuncSet, Z09 §14.9)
    arg 1 nil or charNo == −1: return nothing
    p = som_FindPlayer(charNo); e = element & 0x3f; info = CT_INFO { type, e, ElementValue = 2 (USABLE) }
    if type == 0 or !GetGroupData(type) or e ≥ 4: return false
    if p is not on this zone:
        WM ← 0x6009 NC_CT_LUASCRIPT_SET_WORLD_CMD { u32 nCharNo, CT_INFO CTInfo }   (W04 §7; relay bug W04-B19)
    else:
        t = p.so_GetCharacterTitle
        if !IsUnknownedTitle(type, e) and !IsKnownedTitle(type, e): return true     # unreachable: one test always holds
        t.SetTitleStatus(type, e, USABLE)                 # 0x6004 / 0x6005 / announce when it changed (§6.2)
    Character DB ← 0x6005 NC_CT_DB_SET_CMD { u16 0xFFFF, u32 charNo, CT_INFO info }
    return true
```

`IsKnownedTitle` is "status > 0", so one of the two tests always holds: a script grant of a title the player is
**wearing** (USE) sets it back to USABLE while `m_CurrentTitle` still names it; the client is told "acquired" again and
the DB stores USABLE. For a fresh grant the DB gets 0x6005 twice (once from `SetTitleStatus`, once at the end), and
for an already usable title once although nothing changed (original bug) Z18-B18. Fame is not given on this path
(`SetTitleStatus`, not `SetTitleUsable`).

### 6.4 The weapon title after `so_ply_EquipmentChange` (answers §8 / Z18-B9)

`CCharacterTitle::SetCurrentTitle(type, e, mob, text)` FUN_0062e2e0 checks the status only for types other than 0 and
10, so for the weapon title it always stores `m_CurrentTitle = 10`, `m_CurrentTitleElement = e`,
`m_CurrentTitleMobID = mob` and `m_pTitle = GetTitleString(10, e)` (`szCTNull` for e > 3). With the garbage of Z18-B9
the server keeps a wrong mob id and display string; nothing is sent to the client at that point. The next
`so_SaveCharTitle` FUN_00453f30 (Z12) writes `CurrentTitleMobID` into the character's title save (the element is forced
to 0 for type 10), so after the next login the WM's 0x1031 and the client's 0x1049 carry the garbage mob id (Z07 §1.3);
the client then shows the weapon title of that mob, or none *(inferred: client lookup not opened)*.

### 6.5 Collection cards

Z07 §7 covers the COLLECT handlers and §4.5 of this file the card drops (`g_CardCollectMake`).

```pseudo
ShinePlayer::sp_CardCollectionSend(p)                      @ FUN_0044cc30   (from sp_NC_MAP_LOGINCOMPLETE_CMD, Z01 §6)
    p ← 0x10E4 NC_CHAR_CLIENT_CARDCOLLECT_CMD { u32 chrregnum (not written), u16 number,
            CardInform[number] { long RegistTime, u32 SerialNumber, u16 CardID, u8 StarNumber } (11 bytes) }  = album p+0x2aa94
    p ← 0x10E7 NC_CHAR_CLIENT_CARDCOLLECT_BOOKMARK_CMD { u32 (not written), u16 number, {u16 Slot, u16 CardID}[number] }  = p+0x2aaa4
    p ← 0x10EA NC_CHAR_CLIENT_CARDCOLLECT_REWARD_CMD { u32 (not written), u16 number, u16 RewardID[number] }  = p+0x2aab4
    # each through so_GetDataSocketStream (vt 0x2f8); length 8 + n × entry; "Packet Too Long" assert otherwise
    # the 4 header bytes keep whatever the shared send buffer held (original bug) Z18-B19
```

Client: `On_NC_CHAR_CLIENT_CARDCOLLECT_CMD` FUN_0049cbb0 (`CollectWin::SetCard(CardID, Star, Serial, RegistTime)` +
`SetNewest`), `…_BOOKMARK_CMD` FUN_0049cc30 (`SetBookmark(Slot, CardID)`), `…_REWARD_CMD` FUN_0049cca0
(`SetReward(id, 1)`); all three read the count at +4 and do nothing while the collection window object
(`GameFrameWork+0x1314`) does not exist. None reads the first 4 bytes. The album count is not capped here; a list longer than the send buffer fails the
length assert and that packet is not sent.

| Function | Address | What it does |
|---|---|---|
| `CardCollection::CardCollectionReward::CardCollectionReward` | FUN_00629150 | zero three pointers (an empty STL vector); the same code builds the album, bookmark and reward vectors in the player ctor and is shared (identical-code folding) by `ShineMover`, `SlotMachineScreenManager` and `gStateItemDataBox` |
| `SHND::CommonData<CollectCard,…>::cd_Load(v)` | FUN_00629840 | `cd_Data = v` (the card table vector, Z07 §7 `CollectCard.shn`); the folded code is also called from the player ctor |
| `BinaryDataBox<CollectCardMobGroup>::bdb_ReadData(path)` | FUN_00648d50 | `CDataReader::Read(path, 0x12, 0x24)`, fatal on failure; identical-code folding with the `ActiveSkillGroup.shn` reader (Z20 §2.1), which is its only caller seen |

---

## 7. Original-server bugs

| ID | Owner / handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z18-B1 | Z01 `csm_AddClientSessionToIPGroup` FUN_0045c720 | when the 10th not-yet-logged-in session of one IP arrives, the 10-slot group is erased from the vector without `delete[]` | 40 bytes leaked per event (a flood from one IP leaks steadily) | `delete[] g` as `csm_Remove…` does |
| Z18-B2 | Z01 0x0806 `sp_NC_MISC_SEED_REQ` FUN_00451a30 | reachable only with session mode 2 and player mode 0 (mode mask 0x01), i.e. after a 0x1803 that bailed out before `mode = 1`; it then sends a new seed from its own counter `newseed` without moving `sp_Encryption` | in practice dead; if reached the client switches its XOR index and every later packet decrypts wrong | drop the handler (the seed is sent at accept, §1.3), or set `pe_point` as `so_EncSeedSet` does |
| Z18-B3 | Z01 `ClientSession::zbs_Parsing` FUN_004fb9f0 | in session mode 1 (and −1) an out-of-sequence packet is only logged to `InvalidSessionCutLog`; in mode 0 it is dropped silently | a client can send anything before 0x1803 without being cut | close the session, as Login and WM do |
| Z18-B4 | Z03 `ShinePlayer::so_mobile_ICanDamageTo` FUN_004361a0, §3.9 | in the type-4 kingdom-quest branch the "same raid" test compares the attacker's raid number with itself | two players who are each in any raid count as raid mates there: they cannot hit each other unless their guilds are at war | compare with the target's raid (as the normal branch does); twin of Z09-B31 |
| Z18-B5 | Z03 `ActorCluster::ActorCluster` FUN_00405a10, §3.1 | slot 67 KNOCKBACK gets the Poison actor (the register still holds `&ac_POISON`); the `ac_DOTWCRATE` actor (`SubAbnormalStateActorDmgState`) is constructed but put in no slot | the DmgState actor (its `sasa_Routine` FUN_0040dc60) is dead code; the 17 knock-back rows run Poison's routine (what that does with rows that have only `SAA_AWAY*` actions: Z22) | 67 → the base actor or `ac_DOTWCRATE`; intent unknown |
| Z18-B6 | Z03 `so_Dispel` FUN_0042bf70, `so_SkillCure` FUN_0042c440, §3.4 | every element is guarded by `well512_GetRandom(1000) < 1001` | the guard is always true (dead check) | a per-state dispel / cure chance |
| Z18-B7 | Z03 `smo_SkillBash_Blast_Trap(Obj)` FUN_005838a0, 0x2442, §3.6 | a single-target trap skill hits `o.smo_SkillCast.scs_BattleSkill.target` with `scs_Empower`, not the target and empower it was given; `Last` = ENEMYUSER is not handled (assert, no blast) | `blastMode` 2 / 4 single-target traps hit the servant's stale cast target (or nobody); 0x2442 still names the given target. ENEMYUSER trap skills on an object do nothing (the Loc version handles them) | use `t` and `empower`; add the ENEMYUSER scanner |
| Z18-B8 | Z04 `ItemAttrCls_Armor::iac_DropItemMake` FUN_0063fa60 / `ItemAttrCls_Weapon::iac_DropItemMake` FUN_0063f9d0, §4.5 | the upgrade picked from `ig_upgraderate[16]` is overwritten with 0 right after (and the pick tests each weight alone, not cumulatively) | the `Upgrade00…15` weights of `ItemDropGroup` never apply; dropped armour / weapons get only `dilig_Drop`'s upMin…upMax upgrade | keep the picked level (cumulative weights) |
| Z18-B9 | Z04 `so_ply_EquipmentChange` FUN_0052ce60, §4.3 | with the weapon title (type 10) active, `SetCurrentTitle(10, level, mob)` is called with two stack variables that only the weapon builder writes | equipping / clearing any non-weapon view slot sets the server-side weapon title to garbage mob / level (title string from `GetTitleString(10, garbage)`) | update the title only for the weapon class |
| Z18-B10 | Z04 `ItemAttrCls_Weapon::iac_equipbriefinfo` FUN_0063f820, 0x1C05 | `upgradeinfo.nSlotNum` (payload +5) is not written | one stale `g_buf` byte on the wire; the client does not read it | write the slot as the armour builder does |
| Z18-B11 | Z05 `so_ply_ViewSlot_EquipInfoSend` FUN_0052b5e0, §4.3 | the item id variable is set only for slots in use and not reset per slot | a slot marked for re-send without a view item is re-sent with the previous marked slot's item | reset to 0xFFFF per slot (send the real item) |
| Z18-B12 | Z04 `Item_AdjUpgradeLevel` FUN_0053b560 / `Item_AdjFailCount` FUN_0053b700, §4.6 | an item id without `ItemDataBox` row leaves the index pointer null and reads `->data->Class` | crash; latent (callers pass items they looked up) | return 0 as for other classes |
| Z18-B13 | Z04 `sp_DestroyItem` B FUN_00527b60, `sp_ItemInvenDelete` FUN_0051c590, §4.4 | key count in 7 bits (as Z11-B8) | more than 127 keys wrap the count (latent) | a wider count or several requests |
| Z18-B14 | Z04 `RandomOptionTable::rot_FillOption` FUN_00493590, §4.5 | the option count is capped at 50 while `ItemOptionStorage` has 8 elements | a count > 8 would overwrite the attribute bytes after the options; latent (2016 counts 1…5) | cap at 8 |
| Z18-B15 | Z02 `BriefInfoExchangeAbstate::bixa_Exchange` FUN_00440510 / `bixa_Send` FUN_0043df50, §2.2 | 28 buffers, flush only at count > 28, and `bixa_Send` refuses count 29 | in a full exchange (login, teleport, layer change) with ≥ 29 players or ≥ 29 mobs / NPCs / servants / movers in sight, the 29th list overwrites the 28th and all 29 abstate packets are dropped (repeats every 29 objects) | flush at count ≥ 28 (`> 27`, like the other batches) |
| Z18-B16 | Z02 `BriefInfoExchangeItem::bixi_Exchange` FUN_004401a0, §2.1 | calls vt 0x538 on the receiving player (an empty stub) instead of on the drop item | batched 0x1C0B entries carry the `looting` bit last computed for another player: the client shows items as pickable / not pickable wrongly until the next 0x1C0A | `item.so_drpitm_CanLootingBitSet(me)` |
| Z18-B17 | Z07 `CCharacterTitleZone::SetTitleStatus` FUN_005caf70 via `CheckNewTitle` type 15, §6.2 | any status change sends 0x6004 and the world announce, also the take-back to KNOWNED | when the guild grade drops, the player reads "Character Title [..] acquired." and the world may be told they earned it | send 0x6004 / announce only for USABLE (or send the new value and let the client remove the title) |
| Z18-B18 | Z07 Lua `cAddCharacterTitle` FUN_005eb310, §6.3 | `IsKnownedTitle` is "status > 0", so the grant always runs; the trailing 0x6005 is unconditional | a granted title that is worn (USE) is set back to USABLE while still current; a fresh grant is saved twice, an unchanged one once | test `status < USABLE`; send 0x6005 only from `SetTitleStatus` |
| Z18-B19 | Z07 `ShinePlayer::sp_CardCollectionSend` FUN_0044cc30, §6.5 | the `chrregnum` header (payload +0..3) of 0x10E4 / 0x10E7 / 0x10EA is not written | 4 stale bytes of the shared send buffer go to the client (it ignores them) | write the character number or 0 |
| Z18-B20 | Z07 `CCharacterTitleDataStateServer::Read` FUN_005ca790, §6.1 | `nStateNum > 6` is refused but 6 is accepted, and Type / TitleLV are not range-checked | a 7th state row for one title (or a type ≥ 128 / level ≥ 4) writes past `StateData[6]` / the 512 entries; latent, the 2016 table has at most 6 rows per title | refuse `nStateNum ≥ 6`; check the indices |

## 8. Not reconstructed / uncertain

- `sp_GhostBan` (§1.1): `AxialListGhostBan::ali_Work` does not skip the caller, so whether `so_AllInMap` passes the
  logging-in player itself decides whether it logs itself out of sight. It runs late in the login burst, and nothing
  reports a missing self in practice, so the map walk probably skips the caller *(inferred)*. The walker's map
  function (`fm_BroadFunc.fm_fp_AllInMap1`) was not opened.
- `sp_KeepFromDoubleLogin`: the text of the "empty list" log line is a `"%.255s"` with a lost argument.
- `zs_connect`'s client path: the ClientSessionManager's take function (vt 0) was not opened; the pool size is Z01's.
- The three "skip only" opcodes of the session filter (0x200B, 0x304D, 0x3848) are those the 2016 client may send while
  loading; only 0x3848 has a name in `opcodes.json`.
- §3.4 `so_Dispel`: the return value of the DISPELRANDOM-only path (the decompiler shows a byte of a reused argument);
  `smo_Dispel` ignores it; whether `smo_SkillBlast` (the other vt 0x5a8 caller) reads it was not re-read.
- §3.3: whether `so_KilledBy` clears a re-claimed shelter buffer before storing (not re-read; Z03 §7.2 describes the store).
- §3.1: Silencetoone ends at the first `smo_SkillBlastOption` query; whether the item-use and mob-AI queries were meant to
  consume it is unknown (design or bug).
- §3.6: the visible effect of 0x2442 / 0x2443 on the client (`Char::ActSkill` animation path) was not followed beyond
  the vtable names *(pdb2017)*.
- §4.2: the two "Old" conflict scans count a worn / view item without `ItemInfoServer` or equip row as covering every
  slot; whether that is a deliberate safety net or an oversight is open (no such item in the 2016 tables).
- §4.3 / Z18-B9: answered in §6.4 (wrong mob id / string on the server, saved and shown after the next login); how the
  client renders a weapon title with an unknown mob id was not opened.
- §4.4: lock-list slots 0x44 (small-cell replace) and 0x6c (`LinkInformTemplete` carried with the lock) were read only
  from their call sites; the `0x345A` side that applies them is Z05 §6.4.
- §4.8: `ili_Check` skips notes whose first target is type 3 / 12–16 or whose first source is type 2 (mini-house and
  reward boxes); type 12 is not a box Z04 §1.1 lists *(inferred: a reserved mini-house type)*.
- §2.1: the opcode writes of the item (0x1C0B) and mini-house (0x1C14) batch buffers were not located (no init function
  in the export; the names come from the PDB pointer types and agree with the client handlers' entry sizes).
- §2.2: whether a receiver with `smo_GetMode == 0` ever reaches `bixa_Send` (which would carry its batch to the next
  player's exchange) was not checked; login complete sets the mode before the exchange.
- §6.2: what unlocks types 1 EXP, 2 CLASS, 5 MONEY, 44 FAME_COUNT, 57, 117–119 (no `CheckNewTitle` case) was not
  searched beyond the Lua grant (§6.3); `CT_*` counters other than those named in §6.2 are documented by their callers.
- §6.2: after the type-15 take-back the worn title (`m_CurrentTitle`) is not cleared; whether its abstates stay until
  the next 0x6001 / login was not followed *(inferred: they stay)*.
