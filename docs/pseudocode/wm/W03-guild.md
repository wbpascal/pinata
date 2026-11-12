# World Manager: guild and guild academy (W03)

Source: `Files/Server/2016/w00_WorldManager/4WorldManagerServer2.exe` (export `re-data/exports/wm`). Read code with
`python3 -I tools/protocol-re/clean.py re-data/exports/wm tools/protocol-re/names/wm <addr>`; names added by this item are
in `tools/protocol-re/names/wm/W03.json` (all "ours" unless they come from a log string; log-string names are
`CGuildManager::…` / `fc_NC_…`). Verified layouts: `docs/protocol/annotations/W03.json`. Facts for other items:
`docs/knowledge/W03.md`. Evidence markers as in `CLAUDE.md`: *(pdb2017)*, *(db-backup)*, *(inferred)*; plain = read in
the 2016 code.

Reading notes for this binary:

- Many guild replies are built as raw byte headers `{len, opLo, opHi, payload…}` and sent with `SendRaw`. Ghidra often
  merges the 5-byte `{4, op, op, errLo, errHi}` store into one dword plus a lost byte (it shows e.g. `0x1740804`); the
  real bytes were checked with `objdump` (e.g. `FUN_00445950` sends `04 08 74 00 0d` = 0x7408 {0x0D00}).
- Several result-returning callees are typed `void` by Ghidra although callers use the value; their return codes were
  read from the machine code (`mov eax, imm` before each `ret`). Such functions are marked "(returns …, from the asm)".
- `s` = the client session (`CWMClientSession`, W01-core §1.1). `s.CHARDATA` = cached char blob at `+0x560`
  (+0 charNo, +4 name[20], +0x19 level, +0x42 map[12], +0x62 prison). `G` = the guild manager singleton
  `g_GuildManager` (`DAT_006c4cc0`, class name `CGuildManager` from log strings).
- Result code 0x0C41 is the universal "OK" of these packets.

## 1. Data structures

### 1.1 Guild manager `g_GuildManager` (DAT_006c4cc0)

| Offset | Field (ours) | Notes |
|---|---|---|
| +0x00 | allGuildsLoaded | set to 1 by the last 0x7457 NC_GUILD_DB_ALL_ACK chunk (flag bit 2); W01 start-up state machine waits on it (`FUN_0040b820` → CharDB link state 7) |
| +0x04 | tokensLoaded | set by the last 0x74BD NC_GUILD_DB_TOKEN_ALL_ACK chunk (`FUN_0040b870` → CharDB link state 0xB) |
| +0x20 | guildCount | list length; 0x7405 refuses when ≥ 0x4000 |
| +0x24 / +0x28 | head / tail | doubly linked list of guild entries (§1.2), next at entry+0x1BAA0, prev at +0x1BA9C |
| +0x2C | tournament object `g_GuildTournament` (DAT_006c4cec) | §8 |
| … | academy timers (`m_NextAcademyRankBalanceTime`), reward tables | §6 |

Lookups: `Guilds_FindByNo` FUN_0043dca0 (by entry+0x788, 0 → NULL), `Guilds_FindByName` FUN_0043dcd0 (16-byte
`Name4` compare of entry+0x10), `Guilds_Add` FUN_00450060 (malloc 0x1BAA8, copy, append), `Guilds_Remove`
FUN_004501b0 (unlink + free, count−1).

### 1.2 Guild entry (`CGuildServer` + members + academy, 0x1BAA8 bytes)

Class names from RTTI: `CGuild` / `CGuildServer` (vftable shared, 20 slots), `CGuildMember` / `CGuildMemberServer`,
`CGuildAcademyMember` / `CGuildAcademyMemberServer`.

| Offset | Field | Notes |
|---|---|---|
| +0x000 | vftable `CGuildServer` | |
| +0x008 | loaded | 1 after construction |
| +0x00C | `GUILD_CLIENT` *(pdb2017 layout, offsets confirmed by the 2016 code)* (0x42B bytes) | +0x0C nNo, +0x10 sName (`Name4`, 16), +0x20 u64 nMoney, +0x28 nType, +0x29 nGrade, +0x2A nFame, +0x2E nStoneLevel, +0x30 u64 nExp, +0x38 dCreateDate, +0x60 **nNumMembers**, +0x62 **nMaxMembers** (new guild: 1 / 200 = `0xC80001`), +0x64 nWarStatus (3 = refuses war), +0x65 dWarRequestDate, +0x69 dWarStartDate, +0x6D dWarEndDate, +0xDD nWarEnemy, +0xE1 sWarEnemyName, +0xF1 nWarEnemyGrade, +0xF2 MyScore, +0x11C EnemyScore, +0x146 win, +0x14A lose, +0x14E draw, **+0x152 nDismissStatus** (1 = dismissal scheduled), +0x153 dDismissDate, +0x17B sIntro[128], +0x1FB dNotifyDate, +0x223 sNotifyCharID, +0x237 sNotify[512] |
| +0x438 | CGuild internal member-info list (`FUN_0045bf20` clear, `FUN_0045bc80` add, 0xEA-byte `GUILD_MEMEBER_INFO`) | only used by the vtable slot `FUN_0045c190`; the WM's own member table is +0x7A0 |
| +0x448 | u64 nGuildToken | from 0x74BD at start-up, decreased by 0x74C0 (§3.8) |
| +0x450 | `GT_COND_INFO` *(pdb2017)*: +0x450 nMyGTCondition, +0x451 nMatchTime, +0x455 tm, +0x479 nGTGrade, +0x47A bIsJoin | tournament state of this guild (§8); nMatchTime = createDate at make time |
| +0x47C | academyExists | 1 after `FUN_0045aa90` |
| +0x480 | `GUILD_ACADEMY_CLIENT` *(pdb2017)* (0x2E0) | +0x480 sAcademyMasterName[20], +0x494 nNumAcademyMembers, +0x496 nMaxAcademyMembers (=100), +0x498 nAcademyPoint, +0x49C nAcademyRank, +0x4A0 dAcademyBuffUntilTime, +0x4A4 sIntro, +0x524 dNotifyDate, +0x54C sNotifyCharID, +0x560 sNotify |
| +0x760..+0x770 | academy reward / money fields (§6) | |
| +0x774 | `GUILD_EMBLEM_INFO` {u8 nPTFileNo, u8 nPTIconNo}; 0xFFFF = none | §3.11 |
| +0x778 | emblem state `GUILD_EMBLEM_STATE` *(pdb2017)*: 0 ON, 1 OFF_LIMIT_MEMBER, 2 DELETED, 3 ON_LIMIT_DATE, 4 NULL_LIMIT_MEMBER, 0xFF NULL | §3.11 |
| +0x77C / +0x780 | emblem save date / emblem delete date | §3.11 |
| +0x788 | `GUILD_SERVER` {u32 nNo, Name3 sPassword[12], i32 dCreateDate} *(pdb2017)* | **+0x788 is the key all lookups use** |
| +0x7A0 | member table `M` (`CGuildMemberServer`, §1.3) | |
| +0x17BA4 | academy member table `A` (`CGuildAcademyMemberServer`, §1.4) | |
| +0x1BA9C / +0x1BAA0 | prev / next | |

### 1.3 Member table `M` (entry+0x7A0)

| Offset in M | Field | Notes |
|---|---|---|
| +0x004 | u16 count | max 400 |
| +0x006 + i·0x6E | `GUILD_MEMBER_CLIENT` *(pdb2017)*: +0 sName[20], +0x14 nGrade, +0x15 nFlags, +0x19 nExpRatio, +0x1B sIntro[64], +0x5B dLogonInfo (bit0 = online), +0x5F nClassID, +0x60 nLevel, +0x61 bIsParty, +0x62 sMap[12] | sorted as received from the DB; removal shifts |
| +0xABE8 | loadState | 0 not loaded, 1 loading (0x7454 sent), 2 loaded (0x7455 last chunk) |
| +0xABEC / +0xABF0 | waiting-handle queue head / tail | 8-byte nodes {u16 wmHandle, next}; filled by `Members_QueueHandle` FUN_0043c7c0 while loading |
| +0xABF4 + i·0x7C | `GUILD_MEMBER_SERVER` *(pdb2017)*: +0 nMemberCharNo, +4 dJoinDate, +8 dCanLeaveTime, +0xC dCanBanishTime, + three `tm` | |
| +0x16DB4 + i·4 | session pointer of member i while online, else 0 | |

Grades: 0 = master, 1 = sub-master, 2 elder, 3 guard *(pdb2017 `GUILD_HISTORY_MSG_TYPE` names)*; new members get
grade 6 (*meaning of 4..6 not reconstructed*). `Members_IsGradeAtMost(M, charNo, g)` FUN_0043c8a0 = member found and
`grade ≤ g`. `Members_FindByCharNo` FUN_0043c850 (→ member client record), `Members_IndexByName` FUN_0045a810.

Send helpers: `Members_Broadcast(M, pkt, …)` FUN_0043cc50 sends to every online member (session pointer set; with
`(…,1,0)` it skips sessions whose +0x1E280 == 1); `Members_BroadcastRaw` FUN_0043cbc0 does the same for a raw buffer.

### 1.4 Academy member table `A` (entry+0x17BA4)

| Offset in A | Field |
|---|---|
| +0x004 | u16 count (max 100) |
| +0x006 + i·0x6D | `GUILD_ACADEMY_MEMBER_CLIENT` *(pdb2017)*: +0 sName, +0x14 nGrade, +0x15 sIntro[64], +0x55 dLogonInfo (bit0 online), +0x59 nClassID, +0x5A nLevel, +0x5B bIsParty, +0x5C sMap, +0x68 dJoinInfo, +0x6C nJoinLevel |
| +0x2A9C | loadState (0/1/2, as M) |
| +0x2AA0 / +0x2AA4 | waiting-handle queue |
| +0x2AA8 + i·0x30 | `GUILD_ACADEMY_MEMBER_SERVER` *(pdb2017)*: +0 nAcademyMemberCharNo, +4 dCanLeaveTime, +8 tm, +0x2C tChatBan_RestTime |
| +0x3D68 + i·4 | session pointers |

`AcademyMembers_Broadcast` FUN_00441170, `AcademyMembers_BroadcastRaw` FUN_004410e0.

### 1.5 Client-session fields used here

| Offset | Field (ours) | Set by |
|---|---|---|
| +0x114 | wmHandle | W01 |
| +0x1DF7C | **guildNo** | CharDB 0x1012 (W01 table), make / join ACKs; cleared on leave / kick / guild delete |
| +0x1DF80 | guild entry pointer | as guildNo |
| +0x1DF84 | guildInfoPending | 1 after 0x1012 / join; consumed by `Client_SendGuildInfo` (§4.2) |
| +0x1DF88 / +0x1DF8C | **academyGuildNo** / academy guild entry pointer | CharDB 0x1097 (§4.1), academy join (§6.2) |
| +0x1DF90 | academyInfoPending | 1 after 0x1097 / joins; consumed by `Client_SendAcademyInfo` (§4.2) |
| +0x1DF94 | **isAcademyMember** (1 = the academy of +0x1DF88) | 0x1097, academy join / leave |
| +0x1DF98 | academy chatBanUntil (time) | 0x9888 / 0x988E (§6.3); 0 on 0x1097 |
| +0x1DF9C | emblemOffNoticePending | 1 after 0x1012; consumed by `Guild_SendEmblemToSession` FUN_00430bc0 |
| +0x1E278 | last 0x7403 time | guild list flood guard |
| +0x1ED98 / +0x1ED9C / +0x1EDA0 | next allowed 0x74FD / 0x988F time, last 0x7424 time | history and war-able-list flood guards |
| +0x1E28C | u32 charNo | used to find the academy master (`FUN_004360f0`) |
| +0x1ECC0 | **pendingGuildInvite** (guildNo, 0 = none) | `Client_SetGuildInvite` FUN_004310b0 / `Client_ClearGuildInvite` FUN_00431130 / `Client_HasGuildInvite` FUN_00431100 |

`Client_SetGuildInvite(s, guildNo)` (returns): 0x0949 when guildNo = 0, 0x1C59 when the same invitation is already
pending, 0x1C5A when another one is pending, else stores and returns 0x0C41.

### 1.6 Helper index (small callees, named here so other items can cite them)

| Function | What it does |
|---|---|
| FUN_00426770 | copy a `GUILD_CLIENT` (0x42B bytes, field by field) |
| FUN_00430d50 | copy a `GUILD_ACADEMY_CLIENT` (0x2E0) |
| FUN_0043cb30 | copy a `GUILD_MEMBER_CLIENT` (0x6E) |
| FUN_00441050 | copy a `GUILD_ACADEMY_MEMBER_CLIENT` (0x6D) |
| FUN_0043e200 | copy a `PROTO_NC_GUILD_MAKE_REQ` (0x1D) |
| FUN_0044a2b0 | zero the name/password block of a make request |
| FUN_00407b10, FUN_00402140, FUN_00409790, FUN_00428170 | Name5 / Name4 copy and string-assign helpers |
| Name5_NotEqual FUN_00402100, Name5_Equal, FUN_00424c30, FUN_00428140, FUN_0042d390 (→ FUN_004281a0) | Name5 / Name4 / Name3 compare (0 = equal for the "NotEqual" forms) |
| FUN_00408370, FUN_00408510, FUN_00408600, FUN_00408700 | `std::string` construct / assign (used to build ServerParam keys) |
| FUN_00459d00 | `std::map<string,u16>` lookup behind `ServerParam_GetInt` |
| FUN_0046a2bb | CRT `localtime` into a caller `tm` |
| FUN_0046c658 / FUN_0046c646 | CRT `rand` / `srand` (tournament map choice) |
| FUN_00469836 / FUN_00469883 | throw `length_error` / `out_of_range` (vector helpers) |
| FUN_0044fd90, FUN_0044fce0 | `vector<{charNo, since, until}>` push_back / reserve (academy re-join block) |
| FUN_0045c200 / FUN_0045c300 | `CGuild` constructor / destructor |
| FUN_0045b3b0 / FUN_0045a7f0, FUN_00443c40 | `CGuildMember(Server)` constructor / destructors |
| FUN_0044fec0 / FUN_0044fe20 | guild entry (0x1BAA8) constructor / destructor |
| FUN_0043dac0 | copy a `CGuildServer` into a new entry (header, GUILD_CLIENT, GT_COND, academy, emblem) |
| FUN_00445580 | copy a member table (client rows, server rows, sessions) |
| FUN_0045aa90 | initialise the academy block (master "Unknown"/first master, max 100) |
| FUN_00440e90 / FUN_00440ef0 | academy member online flag + session / queue a waiting handle (like FUN_0043c7c0) |
| FUN_0043dd10 | name of a guild by number (→ entry+0x10) |
| FUN_0045b220, FUN_0045aee0 | tournament entry-list find by guild / write a bracket slot name |
| FUN_004462d0 | 0x7480 NC_GUILD_TOURNAMENT_TYPE_CMD to the guilds of bracket slots [a, b) |
| FUN_00444c20 | log helper for the bracket dump (FUN_004498e0) |
| FUN_0043d580 / FUN_0043d5a0 / FUN_0043d5c0 | GuildTournamentRequire row: nMinLevel / nMinMember / nProposalMoney |
| FUN_0043fe50 | build and broadcast 0x74E3 (§8.2) |
| FUN_00445c80 / FUN_00445c90 / FUN_0044c550 / FUN_0044c560 / FUN_00448d60 / FUN_00448f00 | one-line forwarders (war-able list, war list, history relays) |
| FUN_00448f10 / FUN_00443700 | academy history: relay 0x9892 → 0x9890 / send 0x9891 |
| FUN_004437d0 / FUN_00443640 | 0x9890 / 0x74FE error replies |
| FUN_00433d40 / FUN_00433d60, FUN_00433d50 / FUN_00433d70, FUN_00433d80 / FUN_00433d90 | session flood-guard accessors (+0x1ED98, +0x1ED9C, +0x1EDA0) |
| FUN_00442a20, FUN_00442ad0, FUN_004422b0, FUN_00442570, FUN_004427a0, FUN_00442830, FUN_0044ddc0, FUN_00442000, FUN_00442060 | raw error replies 0x9832, 0x9836, 0x983A, 0x983E, 0x9842, 0x9846, 0x984A, 0x986A, 0x9825 |
| FUN_004429c0, FUN_00442a70, FUN_004427d0, FUN_00442860 | CharDB 0x9833, 0x9837, 0x9843, 0x9847 { u16 hWMChar, u32 guildNo } |
| FUN_00442900, FUN_00442940, FUN_00442980, FUN_004428c0 | relay 0x983E, 0x9842, 0x9846, 0x983A results |
| FUN_004440d0 | Members_Broadcast 0x7432 |
| FUN_00440b40 / FUN_00447cc0 | 0x982E to guild / academy members |
| FUN_004406c0 / FUN_00447580 | 0x9860 to guild / academy members |
| FUN_00440a90 / FUN_00447c10 | 0x9881 to guild / academy members |
| Party_IsValidNo FUN_00464820 | W02 helper, called (result unused) when a member is added |

Academy CharDB handlers registered as thin wrappers (each `CharDB_CheckAlive` + `Clients_GetByHandle` + the manager
function named in §6): 0x9834 FUN_0040cf90, 0x9838 FUN_0040cfe0, 0x983C FUN_0040d030, 0x9840 FUN_0040d080, 0x9844
FUN_0040d0d0, 0x9848 FUN_0040d120, 0x984C FUN_0040d170, 0x9850 FUN_0040d1c0, 0x9855 FUN_0040d250, 0x9858 FUN_0040d210,
0x985D FUN_0040cd40, 0x9880 FUN_0040d2f0, 0x9882 FUN_0040d330, 0x9815 FUN_0040ce50, 0x981A FUN_0040cea0, 0x981E
FUN_0040cef0, 0x9828 FUN_0040cd20, 0x9830 FUN_0040cf40, 0x9810 FUN_0040cd90, 0x9802 FUN_0040cc90, 0x9804 FUN_0040ccc0,
0x9806 FUN_0040ccf0, 0x9892 FUN_0040e200.

## 2. Guild: client handlers (CParserClient, dept 29) and their CharDB round trips

All client handlers start with `Client_CheckAlive` (W01). "prison" below = `s.CHARDATA.prison != 0` (W01 §… "EldPri").
Opcodes registered to the stub `LAB_00414e40` (`mov eax,1; ret`, no effect): 0x7401 NC_GUILD_INFO_REQ, 0x7412
NC_GUILD_MONEY_SUB_REQ, 0x7414 NC_GUILD_GRADE_REQ, 0x741E NC_GUILD_MONEY_ADD_REQ, 0x7420 NC_GUILD_MEMBER_INTRO_REQ,
0x747C NC_GUILD_TOURNAMENT_LEAVE_REQ, and on the CharDB parser 0x7453 NC_GUILD_DB_ACK, 0x745F NC_GUILD_DB_MONEY_ADD_ACK,
0x7461 NC_GUILD_DB_MONEY_SUB_ACK, 0x746E NC_GUILD_DB_MEMBER_INTRO_ACK. A client sending them gets no answer.

### 2.1 0x7403 NC_GUILD_LIST_REQ (no payload)

```pseudo
Client_GuildListReq(s):                                                          @ FUN_00414cc0
    if !s.CHARDATA: return
    if prison: SendRaw(s, 0x7404 { u16 Error = 0x0D08 })                         # only 2 payload bytes (PDB size 7)
    else Guilds_SendList(G, s)                                                   @ FUN_00445660

Guilds_SendList(G, s):
    wait = clamp(G.guildCount / 100, 30, 60) seconds
    if now < s.lastGuildList(+0x1E278) + wait:
        Send 0x7404 NC_GUILD_LIST_ACK { Error=0x1C30, PartMask=3, TotalNumOfGuild=0, nGuildListCnt=0 }; return
    s.lastGuildList = now
    for each guild entry g (list order), chunked:
        row SHINE_GUILD_LIST_NEW (0x2E) = { u32 g.nNo, Name4 g.sName, Name5 masterName, u8 g.nType, u8 g.nGrade,
                                           u16 g.nNumMembers, u16 g.nMaxMembers }
            # masterName = name of the first member with grade 0; "Unknown" when none (e.g. member list not loaded yet)
        when 7 + n·0x2E > 0x1E6A: Send 0x7404 { Error=0x0C41, PartMask (bit0 = first chunk), Total=guildCount, n, rows }
    Send last chunk with PartMask |= 2
```

Client (`GuildListTask::Recv_NC_GUILD_LIST_ACK` FUN_006b0880): 0x0C41 fills the list window (bit0 clears it, bit1 =
complete); 0x1C30 is accepted silently (no text); 0x0D08 is ignored.

### 2.2 0x7405 NC_GUILD_MAKE_REQ { Name4 Name; Name3 Password; u8 Type }  (0x1D)

```pseudo
Client_GuildMakeReq(s, p):                                                        @ FUN_0041d380
    if !s.CHARDATA: return
    if prison: reply 0x0CC7                                                       # (see reply note)
    else Guild_MakeReq(s, p)                                                      @ FUN_0044cf10 ("CGuildManager::Recv_NC_GUILD_MAKE_REQ")

reply(code) = SendRaw(s, 0x7406 NC_GUILD_MAKE_ACK { Error=code, No=?, Name=p.Name, Type=p.Type, dCreateDate=? })
    # No and dCreateDate are uninitialised stack bytes (original bug) W03-B1     @ FUN_0044a2e0

Guild_MakeReq(s, p):
    if !s.CHARDATA: reply 0x3186
    if s.guildNo != 0 and s.isAcademyMember == 0: reply 0x0CC5                    # already in a guild
    if s.academyGuildNo != 0 and s.isAcademyMember == 1: reply 0x0CC8             # still in an academy
    if s.CHARDATA.level < 20: reply 0x0CC2
    if !Guild_IsValidName(p.Name): reply 0x1A28                                   @ FUN_0043dee0
        # 1..16 chars, first and last char not ' ', 0xA1, '\t', '\r', '\n', and the forbidden-name list
        # FUN_0043a400(&DAT_006c5220, name) != 1 (same filter as W01 character names)
    if G.guildCount > 0x3FFF: log "Max Guild Count Over!!"; reply 0x1A29
    Send CharDB 0x7458 NC_GUILD_DB_MAKE_REQ { u16 hWMChar=s.wmHandle, u32 nCharNo, Name5 sCharID, MAKE_REQ Make=p }
```

The money/item cost of founding is not checked here; the codes 0xC9A/0xC9C ("no item" / "You do not have 50 gold")
come back from the Character DB (D-items). The guild password `Make.Password` is stored by the DB and kept in
`GUILD_SERVER.sPassword` (entry+0x78C); 0x7407 compares it.

```pseudo
CharDB 0x7459 NC_GUILD_DB_MAKE_ACK { u16 hWMChar, u32 nCharNo, MAKE_REQ Make, i32 dCreateDate, u32 nNo, u16 Error }
                                                                                   @ FUN_0040b9d0 → FUN_00450750
    s = Clients_GetByHandle(hWMChar); if !s or !s.CHARDATA: return
    reply = 0x7406 { Error, No=nNo, Name=Make.Name, Type=Make.Type, dCreateDate }
    if 0x0C98 <= Error <= 0x0C9E: send reply; return                              # DB refusal passed through
    build a guild entry: GUILD_CLIENT zeroed, nNo, sName, nType, nGrade=1, nNumMembers=1, nMaxMembers=200,
        all dates = dCreateDate, emblem 0xFFFF / state 0xFF; GUILD_SERVER { nNo, Make.Password, dCreateDate }
                                                                                   @ FUN_0043ccf0, FUN_0045bf60
    add s as the first member (Members_AddSession FUN_0044e200, see below), then set its grade to 0 (FUN_0045b560)
    if either step or Guilds_Add fails: send reply with Error=0x0CC6
    else:
        send reply (Error = 0x0C41 from the DB)
        entry.M.loadState = 2
        Members_Broadcast 0x7436 NC_GUILD_MEMBER_JOIN_CMD { GUILD_MEMBER_CLIENT of s }  @ FUN_004444f0
        s.guildNo = nNo; s.guildEntry = entry
        Zones_Broadcast 0x7448 NC_GUILD_ZONE_MAKE_CMD { u32 masterCharNo, GUILD_ZONE {nNo, sName, nMoney, nType,
            nGrade, nFame, nStoneLevel, nExp, nWarStatus, nWarEnemy} }             @ FUN_0043edb0
        Guild_SendEmblemToSession(s)                                               @ FUN_00430bc0 (§3.11)
    # on every path that got this far: re-rank all academies (§6.4 Academies_Rank, FUN_00442ca0 qsort)

Members_AddSession(M, s):                                                          @ FUN_0044e200
    M.vtbl[7](s)  → appends GUILD_MEMBER_CLIENT { name, grade, class, level, map, online } (CGuildMember slot)
    server record: charNo, dJoinDate = now,
        h = ServerParam "Guild_CannotLeaveTime" (hours); dCanLeaveTime = dCanBanishTime = (h ? now + h·3600 : 0)
    session pointer stored
```

Client (`FUN_006b7aa0`, GuildTask case 6): 0x0C41 → `CGuild::Recv_NC_GUILD_MAKE_ACK` + "%s guild has been created.";
0x0C99 "The name has been taken by another guild. Please try other name."; 0x0C9A/0x0CC4 "You do not have the item to
create the guild."; 0x0C9C/0x0CC3 "You do not have 50 gold. Check your money."; 0x0CC2 "Cannot create a guild due to
level limit of creation."; 0x0CC8 "You must leave any previous Guild Academy…"; 0x0C98/0x0C9B/0x0C9D/0x0C9E/0x0CC5/
0x0CC6/0x1A28/0x3185/0x3186 "Failed to create the guild."; **0x0CC7 (prison) and 0x1A29 (guild limit) show nothing**.

### 2.3 0x7407 NC_GUILD_DISMISS_REQ { Name4 Name; Name3 Password }  (0x1C)

```pseudo
Client_GuildDismissReq(s, p):                                                     @ FUN_00414d40
    if prison: SendRaw(s, 0x7408 { Error=0x0D08 })
    else Guild_DismissReq(G, s, p)                                                @ FUN_00445950

reply(code) = SendRaw(s, 0x7408 NC_GUILD_DISMISS_ACK { u16 Error=code })           @ FUN_0043e240
Guild_DismissReq(G, s, p):
    if s.guildNo == 0: reply 0x0D01
    g = guild with nNo == s.guildNo, else reply 0x0D00
    m = Members_FindByCharNo(g.M, myCharNo), else reply 0x0D04
    if m.nGrade != 0: reply 0x0D02                                                 # only the master (FUN_0045aa60)
    if g.nDismissStatus == 1: reply 0x0D05
    if Name3 compare(g.sPassword, p.Password) != 0 or Name4 compare(g.sName, p.Name) != 0: reply 0x0D03
    if g.GTCond.bIsJoin (+0x47A) != 0: reply 0x0D09                                # joined the guild tournament
    if Guild_IsAtWar(g): reply 0x0D0A                                              @ FUN_0043dd40
    if any guild h has Guild_IsAtWarWith(h, s.guildNo): reply 0x0D0A               @ FUN_0043ddc0
    t = localtime(now); t.mday += 1; t.min = t.sec = 0 → dismissDate = mktime(t)   # tomorrow, same hour
    Send CharDB 0x745C NC_GUILD_DB_DISMISS_REQ { u16 hWMChar, u32 nNo, u8 nDismissStatus=1, i32 dDismissDate }
                                                                                   @ FUN_0043f530
    # no reply now; 0x745D answers
```

entry+0x450 is the guild's `GT_COND_INFO` *(pdb2017 layout: +0x450 nMyGTCondition, +0x451 nMatchTime, +0x455 tm,
+0x479 nGTGrade, +0x47A bIsJoin)*; the client text for 0x0D09 matches ("…during Guild Tournament").

```pseudo
CharDB 0x745D NC_GUILD_DB_DISMISS_ACK { u16 hWMChar, u32 nNo, u8 nDismissStatus, i32 dDismissDate, u16 Error }
                                                                                   @ FUN_0040ba70 → FUN_0044a480
    s = Clients_GetByHandle(hWMChar) (must exist); g = Guilds_FindByNo(nNo) (else nothing)
    if Error != 0x0C41: SendRaw(s, 0x7408 { Error }); return
    g.nDismissStatus = nDismissStatus; g.dDismissDate = dDismissDate (+ tm)
    SendRaw(s, 0x7408 { 0x0C41 })
    Members_Broadcast 0x742F NC_GUILD_DISMISS_CMD { Name4 Name, u8 nDismissStatus, i32 dDismissDate, tm }  @ FUN_00444390
    AcademyMembers_Broadcast 0x985E NC_GUILD_ACADEMY_DISMISS_CMD { same 0x39 bytes }                       @ FUN_004472c0
        # client-bound only; the 2016 client has no handler for 0x985E (academy members are not told)
```

The guild is not deleted here: once dDismissDate has passed, the hourly tick asks the Character DB with 0x745A and the
answer 0x745B removes it (§7, §9.2).
Client (`GuildDismissTask::OnProcessNetMsg` FUN_005bc580): 0x0D00/01/02/04/06/07 "An error has ocurred while
dismissing the guild."; 0x0D03 "Incorrect password." (re-opens the password box); 0x0D05 "The Guild is scheduled to be
dismissed."; 0x0D09 "You cannot dismiss your guild during Guild Tournament."; 0x0D0A "You cannot dismiss your guild
during Guild War."; 0x0D08 (prison) shows nothing.

### 2.4 0x7409 NC_GUILD_MEMBER_INVITE_REQ { Name5 ToCharID }  (0x14)

```pseudo
Client_GuildInviteReq(s, p):                                                       @ FUN_0041d450 ("fc_NC_GUILD_MEMBER_INVITE_REQ")
    code =
      prison                                       → 0x0CD6
      s.guildNo == 0                               → 0x0CD0
      g = Guilds_FindByNo(s.guildNo) is NULL       → 0x0CD1
      Guild_IsAtWar(g)                             → 0x0CD7  (log "Guild War ( IsWar )")
      any guild at war with s.guildNo              → 0x0CD7  (log "Guild War ( IsWarTarget )")
      Tournament_IsFighting(s.guildNo)             → 0x1BD0  (§8.1, FUN_0043e170)
      Tournament_IsEntered(s.guildNo)              → 0x1BD2  (§8.1, FUN_0043e180)
      g.nDismissStatus == 1                        → 0x1BC8
      t = Clients_FindByCharName(p.ToCharID); !t or !t.CHARDATA → 0x0CD2
      else Members_Invite(g.M, s, t)                                              @ FUN_00449150 (returns, from the asm)
    SendRaw(s, 0x740A NC_GUILD_MEMBER_INVITE_ACK { Name5 ToCharID = p.ToCharID, u16 Error = code })   # also on success

Members_Invite(M, s, t):
    i = index of s in M, else 0x0CD0
    if M[i].nGrade > 1: 0x0CD3                                                     # master or sub-master only
    if t.guildNo != 0 and t.isAcademyMember == 0: 0x0CD5                           # t already in a guild
    g = guild of s.guildNo, else 0x0CD1
    if g.nMaxMembers <= M.count: 0x0CD4
    if t.academyGuildNo != 0 and t.isAcademyMember == 1 and t.academyGuildNo != g.nNo: 0x18D0
    r = Client_SetGuildInvite(t, g.nNo); if r != 0x0C41: return r                  # 0x1C59 / 0x1C5A
    SendRaw(t, 0x740B NC_GUILD_MEMBER_JOIN_REQ { Name4 GuildName = g.sName, Name5 FromCharID = s name })
    return 0x0C41
```

An academy member of the same guild can be invited (path continues in §2.5 with 0x982F). Client
(`GuildJoinReqTask::OnProcessNetMsg` FUN_00498fc0): 0x0CD0/0x0CD1/0x0CD3 "Failed to invite."; 0x0CD2 "%s can not
accept the invite."; 0x0CD4 "Guild member capacity has been exceeded."; 0x0CD5 "%s is already a member of a guild.";
0x0CD6 "Cannot send guild invitation in the area."; 0x18D0 "%s is already a member of Guild Academy"; 0x1BC8 "Lunar Our
guild is scheduled for dismissal. We cannot accept new members."; 0x1BD0 "Guild Tournament in progress. Cannot invite
member."; 0x1BD2 text 0x08597E70 (empty string in TextData); 0x1C59 "Already reserved to a guild addition request.";
0x1C5A "Already reserved to add to the other guild."; 0x0CD7 → "Cannot invite during Guild War." (FUN_006b14b0).
The invitee's client opens the join dialog on 0x740B (`GuildMemberTask`).

### 2.5 0x740C NC_GUILD_MEMBER_JOIN_ACK { Name4 GuildName; u8 JoinAck }  (0x11, invitee answers)

```pseudo
Client_GuildJoinAck(s, p):                                                         @ FUN_00419db0
    err(code) = SendRaw(s, 0x740D NC_GUILD_MEMBER_JOIN_ERR { Name4 GuildName = p.GuildName, u16 code })   @ FUN_0044a340
    if p.JoinAck == 0: Client_ClearGuildInvite(s); return                          # refusal: the inviter is NOT told
    if s.guildNo != 0: err 0x0CD8
    g = Guilds_FindByName(p.GuildName), else err 0x0CD9
    Tournament_IsFighting(g.nNo) → err 0x1BD1;   Tournament_IsEntered(g.nNo) → err 0x1BD3
    g.nDismissStatus == 1 → err 0x0CDD
    g.nMaxMembers <= g.nNumMembers → err 0x0CDA
    !Client_HasGuildInvite(s, g.nNo) → err 0x0CDE                                  # must match the pending invite
    Client_ClearGuildInvite(s)
    if s.academyGuildNo == 0 or s.isAcademyMember != 1:
        Send CharDB 0x7469 NC_GUILD_DB_MEMBER_JOIN_REQ { u16 hWMChar, u32 nNo=g.nNo, u32 nCharNo, Name5 sCharID,
                                                         u8 nGrade=6 }            @ FUN_0044aa30
    else:                                                                          # academy member joins its own guild
        if s.academyGuildNo != g.nNo: err 0x0CD8
        Send CharDB 0x982F NC_GUILD_ACADEMY_DB_MEMBER_GUILD_JOIN_REQ { u16 hWMChar, u32 nNo, Name5 sInviteCharID = own
            name (the inviter is not known here), u32 nTargetCharNo, Name5 sTargetCharID, u8 nGrade=6 }   @ FUN_0044c2d0
        # answer: 0x9830 (§5)
    # both send helpers return the opcode (non-zero); the trailing "err 0x0CDB on 0" is dead code
```

```pseudo
CharDB 0x746A NC_GUILD_DB_MEMBER_JOIN_ACK { u16 hWMChar, u32 nNo, u32 nCharNo, u8 nGrade, u16 Error }
                                                                                   @ FUN_0040bbd0 → FUN_0044eb70
    s = Clients_GetByHandle(hWMChar); g = Guilds_FindByNo(nNo) (else nothing)
    if Error != 0x0C41: SendRaw(s, 0x740D { Name4 g.sName, u16 Error }); return
    if !Members_AddSession(g.M, s): return                                         # silently
    Members_Broadcast 0x7436 NC_GUILD_MEMBER_JOIN_CMD { GUILD_MEMBER_CLIENT of s }  (s included)
    s.guildNo = nNo; s.guildEntry = g; s.+0x1DF84 = 1; s.+0x1DF90 = 1
    Client_RefreshGuildState(s)                                                    @ FUN_004360f0 (§4.2)
    Zones_Broadcast 0x744A NC_GUILD_ZONE_MEMBER_JOIN_CMD { u32 nNo, u32 nCharNo }   @ FUN_0043ef00
    g.nNumMembers = g.M.count
    emblem re-check (§3.11): state 1 → if Emblem_HasEnoughMembers(g): CharDB 0x750D NC_GUILD_EMBLEM_STATE_DB_REQ
            { u32 nGuildNo, i32 EmblemDeleteDate = 0, u8 EmblemState = (Emblem_PeriodOver(g) == 1 ? 0 : 3) }
        state 4 → if enough members: state = 0xFF; Guild_BroadcastEmblemInfo(g) (0x750A)
        other  → s.emblemOffNoticePending = 0; Guild_SendEmblemToSession(s)
```

Client (`GuildMemberTask::Recv_NC_GUILD_MEMBER_JOIN_ERR` FUN_006b11a0): 0x0CD8–0x0CDC "Failed to join % guild.";
0x0CDD "Lunar This guild is scheduled for dismissal. You cannot join the guild."; 0x0CDE "Target guild is not the
guild addition target."; 0x1BD1 "Guild Tournament in progress. Cannot join guild."; 0x1BD3 empty text 0x08597E70.

### 2.6 0x740E NC_GUILD_MEMBER_VANISH_REQ { Name5 CharID }  (kick, 0x14)

```pseudo
Client_GuildVanishReq(s, p):                                                       @ FUN_0041d6f0
    reply(code) = SendRaw(s, 0x740F NC_GUILD_MEMBER_VANISH_ACK { Name5 CharID, u16 code })   @ FUN_0044a410
    if prison: reply 0x0CF7 (CharID copied with FUN_00402140)
    s.guildNo == 0 → 0x0CF1;  guild not found → 0x0CF0
    Tournament_IsFighting → 0x0CF9;  Tournament_IsEntered → 0x0CFA
    r = Members_VanishReq(g.M, s, p.CharID)                                        @ FUN_0044e3f0 (returns)
    if r != 0x0C41: reply r                                                        # success answers come with 0x7472

Members_VanishReq(M, s, name):
    !s or !s.CHARDATA → 0x0CE0;  name NULL → 0x3196
    i = my index, else 0x0CF1;  M[i].nGrade >= 2 → 0x0CF3                          # master / sub-master only
    j = Members_IndexByName(name), else 0x0CF1;  j == i → 0x0CF4
    if M[j].nGrade <= M[i].nGrade: 0x0CF3                                           # only lower grades
    h = ServerParam "Guild_CannotLeaveTime"
    if h == 0 or now < M.server[j].dCanBanishTime: return 0x3197                   # (original bug) W03-B2 when h == 0
    Send CharDB 0x7471 NC_GUILD_DB_MEMBER_VANISH_REQ { u16 hWMChar, Name5 sCharID=name, u32 nNo=s.guildNo,
                                                       u32 nCharNo = M.server[j].charNo }   @ FUN_00445f60
    return 0x0C41
```

```pseudo
CharDB 0x7472 NC_GUILD_DB_MEMBER_VANISH_ACK { u16 hWMChar, Name5 sCharID, u32 nNo, u32 nCharNo, u16 Error }
                                                                                   @ FUN_0040bcc0 → FUN_0044f1e0
    s = Clients_GetByHandle(hWMChar) (requester)
    if Error != 0x0C41: SendRaw(s, 0x740F { sCharID, Error }); return
    g = Guilds_FindByNo(nNo), else 0x740F { sCharID, 0x0CF0 }
    m = Members_FindByCharNo(g.M, nCharNo), else 0x740F { …, 0x0CF1 }
    if m is the academy master (name == g.sAcademyMasterName, FUN_0045ab70):
        master = first member with grade 0
        Send CharDB 0x987F NC_GUILD_ACADEMY_DB_SET_MASTER_BY_LEAVE_REQ { u32 nNo, u32 requester charNo,
            Name5 requester name, u32 masterCharNo, Name5 master name }           @ FUN_0044c4c0 (§6.2, 0x9880)
    if Members_RemoveAt(g.M, index of m.name) (FUN_00443da0: vtbl[8] removes the client record, clears the online
       session's guildNo / guildEntry, shifts server records and session pointers):
        SendRaw(s, 0x740F { sCharID, 0x0C41 })
        Members_Broadcast 0x7437 NC_GUILD_MEMBER_VANISH_CMD { Name5 CharID }        @ FUN_004445a0
        Zones_Broadcast 0x744B NC_GUILD_ZONE_MEMBER_LEAVE_CMD { u32 nCharNo }       @ FUN_0043efb0
        g.nNumMembers = g.M.count
        t = Clients_FindByCharNo(nCharNo); if t: send 0x7437 { CharID } to t too  # the kicked player learns it
        emblem re-check (§3.11): state 0 or 3 and not enough members →
            CharDB 0x750D { nNo, dDeleteDate = today + "GE_Delete_Term_Date" days, u32 state = 1 }
          state 0xFF and not enough members → state = 4; Guild_BroadcastEmblemInfo(g)
    else SendRaw(s, 0x740F { sCharID, 0x0CF0 })
```

Client (`GuildMemberVanishTask::OnProcessNetMsg` FUN_005c2a90): 0x0C41 "%s has been banned from the guild.";
0x0CF9 "Guild Tournament in progress. Cannot ban member."; 0x3197 "A guild member can be kicked %d hours after joining
…"; every other code "Failed to ban the member from the guild.".

### 2.7 0x741C NC_GUILD_MEMBER_LEAVE_REQ (no payload)

```pseudo
Client_GuildLeaveReq(s):                                                           @ FUN_00415070
    reply(code) = SendRaw(s, 0x741D NC_GUILD_MEMBER_LEAVE_ACK { u16 code })          @ FUN_0043f310
    prison → 0x0CE4;  s.guildNo == 0 → 0x0CE0;  guild not found → 0x0CE1
    Tournament_IsFighting → 0x0CE6;  Tournament_IsEntered → 0x0CE7
    r = Members_LeaveReq(g.M, s)                                                   @ FUN_0044e580 (returns)
    if r != 0x0C41: reply r

Members_LeaveReq(M, s):
    i = my index, else 0x0CE0
    M[i].nGrade == 0 → 0x0CE3                                                      # the master cannot leave
    h = ServerParam "Guild_CannotLeaveTime"
    if h == 0 or now < M.server[i].dCanLeaveTime: 0x3190                           # (original bug) W03-B2
    Send CharDB 0x746B NC_GUILD_DB_MEMBER_LEAVE_REQ { u16 hWMChar, u32 nNo, u32 nCharNo, Name5 sCharID }   @ FUN_00445e50
    return 0x0C41 (0x0CE2 if the send helper returned 0 — it never does)
```

```pseudo
CharDB 0x746C NC_GUILD_DB_MEMBER_LEAVE_ACK { u16 hWMChar, u32 nNo, u32 nCharNo, u16 Error }
                                                                                   @ FUN_0040bc20 → FUN_0044ee20
    s = Clients_GetByHandle(hWMChar)
    Error != 0x0C41 → 0x741D { Error };  guild not found → 0x741D { 0x0CE1 };  s not a member → 0x741D { 0x0CE0 }
    if s is the academy master: CharDB 0x987F { nNo, s.charNo, s.name, masterCharNo, master name }  (as §2.6)
    if Members_RemoveSession(g.M, s) (FUN_00443c80: vtbl[9] by name; clears s.guildNo / s.guildEntry):
        SendRaw(s, 0x741D { 0x0C41 })
        Members_Broadcast 0x7438 NC_GUILD_MEMBER_LEAVE_CMD { Name5 CharID = s name }  @ FUN_00444650
        Zones_Broadcast 0x744B { u32 nCharNo }
        g.nNumMembers = g.M.count; emblem re-check as in §2.6 ("GE_Delete_Term_Date")
```

Client (`GuildLeaveTask::OnProcessNetMsg` FUN_005ba840): 0x0C41 "You left % guild."; 0x0CE6 "Guild Tournament in
progress. Cannot leave guild."; 0x3190 "In order to leave or exile from a Guild Academy, you must be a member for more
than %d hours." (the academy text is also used for the guild); any other code "Failed to quit from the guild.".
The leaving member is not in the member table any more when 0x7438 is broadcast, so its own client only gets 0x741D.

### 2.8 0x7410 NC_GUILD_NOTIFY_REQ { u16 nNotifyLength; char sNotify[] }

```pseudo
Client_GuildNotifyReq(s, p):                                                       @ FUN_00414dc0 → FUN_00445b90
    reply(code) = SendRaw(s, 0x7411 NC_GUILD_NOTIFY_ACK { u16 code })
    prison → 0x0D14;  s.guildNo == 0 → 0x0D11;  guild not found → 0x0D10
    !Members_IsGradeAtMost(g.M, myCharNo, 2) → 0x0D12                              # master, sub-master, elder
    Send CharDB 0x7462 NC_GUILD_DB_NOTIFY_REQ { u16 hWMChar, u32 nNo, Name5 sNotifyCharID = my name,
        u16 nNotifyLength = p.nNotifyLength, sNotify copied with strcpy }          @ FUN_0043f590
        # payload length = nNotifyLength + 0x1C, but the copy stops at the first NUL: the length field is trusted and
        # the bytes are not bounded by the 0x2000 packet buffer (original bug) W03-B3
    (0x0D13 is sent when that helper returns 0; it always returns 0x2008)
```

```pseudo
CharDB 0x7463 NC_GUILD_DB_NOTIFY_ACK { u16 Error, u16 hWMChar, u32 nNo, i32 dNotifyDate, Name5 sNotifyCharID,
                                       u16 nNotifyLength, char sNotify[] }         @ FUN_0040bb10 → FUN_00445ca0
    s = Clients_GetByHandle(hWMChar) (may be gone)
    if Error != 0x0C41: if s: 0x7411 { Error }; return
    g = Guilds_FindByNo(nNo) (else nothing)
    if s: 0x7411 { 0x0C41 }
    cmd = NC_GUILD_NOTIFY_CMD { dNotifyDate, tm, sNotifyCharID, nNotifyLength, sNotify (strcpy) }
    g.vtbl[11](cmd)                                                               # CGuild::SetNotify (FUN_0045acd0 slot)
    Members_Broadcast 0x742D NC_GUILD_NOTIFY_CMD (size 0x3E + nNotifyLength)        @ FUN_00444020
```

Client: `GuildNotifyTask::OnProcessNetMsg` FUN_005bb6f0: any code ≠ 0x0C41 → "Failed to write the guild notice.".

### 2.9 0x7416 NC_GUILD_MEMBER_GRADE_REQ { Name5 CharID; u8 MemberGrade }  (0x15)

```pseudo
Client_GuildGradeReq(s, p):                                                        @ FUN_0041d8e0 ("fc_NC_GUILD_MEMBER_GRADE_REQ")
    reply(code) = SendRaw(s, 0x7417 NC_GUILD_MEMBER_GRADE_ACK { Name5 CharID, u8 MemberGrade, u16 code })  @ FUN_0044a3a0
    prison → 0x0CED;  s.guildNo == 0 → 0x0CE9;  guild not found → 0x0CE8
    Guild_IsAtWar(g) → 0x0CEE (log "Guild War ( IsWar )");  Tournament_IsFighting → 0x0CEF
    r = Members_GradeReq(g.M, s, p)                                                @ FUN_00449360 (returns)
    if r != 0x0C41: reply r

Members_GradeReq(M, s, p):
    i = my index, else 0x0CE9;  M[i].nGrade != 0 → 0x0CEB                         # master only
    j = Members_IndexByName(p.CharID), else 0x0CEA
    if M[i].nGrade > M[j].nGrade: 0x0CEB                                           # never true for the master
    if p.MemberGrade == 0 and M[j].nLevel < 20: 0x0CFB                             # new master must be level 20+
    Send CharDB 0x746F NC_GUILD_DB_MEMBER_GRADE_REQ { u16 hWMChar, Name5 sCharID, u32 nNo, u32 nCharNo = target,
        u8 MemberGrade, u32 nSetCharNo = my charNo, u8 MemberGrade_Old = M[j].nGrade }   @ FUN_00445ed0
    return 0x0C41
```

The master may set any value 0..255 for `MemberGrade`; there is no range check (original bug) W03-B4 (the DB
procedure decides). Setting oneself is allowed (j == i).

```pseudo
CharDB 0x7470 NC_GUILD_DB_MEMBER_GRADE_ACK { u16 hWMChar, Name5 sCharID, u32 nNo, u32 nCharNo, u8 MemberGrade,
                                             u16 Error, u32 nSetCharNo }           @ FUN_0040bc70 → FUN_0044aae0
    s = Clients_GetByHandle(hWMChar) (the requester)
    if Error != 0x0C41: 0x7417 { sCharID, MemberGrade, Error }; return
    g = Guilds_FindByNo(nNo), else 0x7417 { …, 0x0CE8 }
    if MemberGrade == 0:                                                           # master transfer
        g.M.vtbl[10]({ s name, grade 6 }) (set grade by name); if it fails: stop silently
        Members_Broadcast 0x7439 NC_GUILD_MEMBER_GRADE_CMD { Name5 s name, u8 6 }   @ FUN_00444700
        Zone(s) ← 0x9886 NC_GUILD_ACADEMY_REWARDSTORAGE_GRADE_INFO_CMD { u32 charNo, u32 guildNo, u8 6 }   @ FUN_0043c6c0
    if g.M.vtbl[10]({ sCharID, MemberGrade }) succeeds:
        if s.charNo != nCharNo: 0x7417 { sCharID, MemberGrade, 0x0C41 }             # not when changing oneself
        Members_Broadcast 0x7439 { sCharID, MemberGrade }
        t = Clients_FindInGameByCharNo(nCharNo); if t: Zone(t) ← 0x9886 { t.charNo, t.guildNo, MemberGrade }
```

0x9886 goes to the zone the member is on (`Zones_Get(s.zoneNo)`), so the zone can apply the reward-storage
withdraw rights of the new grade (Z-item for guild storage). Client (`GuildMemberGradeSetupTask::OnProcessNetMsg`
FUN_005c1a70): 0x0CE8–0x0CEC "Failed to assign the guild member."; 0x0CEE "Cannot assign during Guild War."; 0x0CEF
"You cannot assign master rights while Guild Tournament…"; 0x0CFB "Guild Master only can transfer "Guild Master Right"
to level %d or above character."; 0x0C8A (DB) "Guild master can be transfered after a week(7 days) from the last master
change."; 0x0CED (prison) shows nothing.

### 2.10 0x7418 NC_GUILD_MY_GUILD_INFO_REQ (no payload)

```pseudo
Client_MyGuildInfoReq(s):                                                          @ FUN_004217b0
    if s.guildNo == 0: SendRaw(s, 0x7419 NC_GUILD_MY_GUILD_INFO_ACK { u16 Error=0x0CCB })
    elif guild not found: SendRaw(s, 0x7419 { 0x0CCA })
    else: Send 0x7419 { Error=0x0C41, GUILD_CLIENT GuildInfo = g+0x0C (0x42B bytes) }   @ FUN_00444970
```

No prison check. The whole `GUILD_CLIENT` goes out, including war data and the notice. The guild password is not in
`GUILD_CLIENT` (it is in `GUILD_SERVER`), so it does not leak.

### 2.11 0x741A NC_GUILD_MEMBER_LIST_REQ (no payload) and the member-table load

```pseudo
Client_GuildMemberListReq(s):                                                      @ FUN_004218c0
    if s.guildNo and g = Guilds_FindByNo(s.guildNo): Members_RequestList(g.M, s); return   @ FUN_004494a0
    SendRaw(s, 0x741B NC_GUILD_MEMBER_LIST_ACK { TotalMemberCount=0, MemberIndex=0, MemberCount=0 })

Members_RequestList(M, s):
    switch M.loadState:
      0: M.loadState = 1; queue s.wmHandle; Send CharDB 0x7454 NC_GUILD_DB_MEMBER_REQ { u32 nNo = s.guildNo }
      1: queue s.wmHandle                                                          # answered when the load ends
      2: i = my index; if found: M[i].dLogonInfo |= 1 (online); M.session[i] = s
         Members_SendList(M, s)                                                    @ FUN_00443e80
         # not a member (e.g. stale guildNo) → nothing is sent

Members_SendList(M, s):  0x741B { u16 TotalMemberCount = M.count, u16 MemberIndex, u16 MemberCount,
                                   GUILD_MEMBER_CLIENT[MemberCount] }
    chunks of ≤ 18 rows (flush when 6 + n·0x6E > 0x7FD and n > 1); MemberIndex = index of the last row of the
    previous chunk + 1 *(the field is the running "rows already sent" counter)*
```

```pseudo
CharDB 0x7455 NC_GUILD_DB_MEMBER_ACK { u32 nNo, u16 Error, u8 PartMask, u16 count, GUILD_MEMEBER_INFO[count] (0xEA) }
                                                                                   @ FUN_0040b800 → FUN_0044d460
    if Error != 0x0C41 or guild not found: log "FAILED - CGuildManager::Recv_NC_GUILD_DB_MEMBER_ACK…"; return
    if PartMask & 1: M.count = 0
    for each record (until M.count reaches 400): append client part (0x6E) and server part (0x7C); session = NULL
    if PartMask & 2:
        g.nNumMembers = M.count; M.loadState = 2
        Members_OnLoaded(M)                                                        @ FUN_0044c5f0 (§2.11.1)
```

#### 2.11.1 Members_OnLoaded (FUN_0044c5f0)

See §4.3: it pops every queued handle, marks those members online and sends each the member list; it is the same
routine the login path uses.

## 3. Guild: war, lists, chat, name lookup, tokens, history, emblem

### 3.1 War state (in the requesting guild's entry only)

| nWarStatus (+0x64) | Meaning (ours, from the timer) | Time window |
|---|---|---|
| 0 | none | |
| 1 | requested, waiting for start | dWarRequestDate ≤ now < dWarStartDate (= request + 5 min) |
| 2 | at war | dWarStartDate ≤ now < dWarEndDate (= request + 65 min) |
| 3 | cooldown after the war | until dWarEndDate, which the war end resets to end-time + 120 min |

`Guild_IsAtWar(g)` FUN_0043dd40 = nWarEnemy ≠ 0 and request ≤ now < end; `Guild_IsAtWarWith(h, no)` FUN_0043ddc0 = the
same with `h.nWarEnemy == no`. `Guild_GetWarStatusNow` FUN_00445600: 1 inside [request, start), 2 inside [start, end)
(FUN_0043dd80), else clears nWarEnemy and returns 0. `Guild_WarRemainSec` FUN_0043e090 = seconds to start (status 1)
or to end (2, 3).

**Only the requester's entry holds the war** (nWarEnemy, dates, both scores). The target guild's entry is not changed;
every "is X at war" check therefore scans all guilds for `nWarEnemy == X` as well (0x7407, 0x7409, 0x7422).

### 3.2 0x7422 NC_GUILD_WAR_REQ { Name4 TargetName }  (0x10)

```pseudo
Client_GuildWarReq(s, p):                                                          @ FUN_00414e50 → FUN_0044dba0
    reply(code) = SendRaw(s, 0x7423 NC_GUILD_WAR_ACK { u16 code })                   @ FUN_0043e9d0
    prison → 0x0D28
    s.guildNo == 0 → 0x0D21;  my guild g not found → 0x0D20
    !Members_IsGradeAtMost(g.M, me, 1) → 0x0D22                                    # master / sub-master
    Guild_IsAtWar(g) → 0x0D23
    g.nWarStatus == 3 → 0x0D24                                                     # cooldown
    t = Guilds_FindByName(p.TargetName), else 0x0D25
    (g or t at status 1/2 and paired with each other, FUN_0043de60) → 0x0D23
    (t at status 3 and paired, FUN_0043dea0) → 0x0D23
    !Guild_CanDeclareWar(g, t) (FUN_0043de00): false when g == t, when g is at war, when g.nWarStatus == 3,
        or when g.nType == 0 or t.nType == 0                                       → 0x0D29
    g.nDismissStatus == 1 → 0x1BC0;  t.nDismissStatus == 1 → 0x1BC1
    Guild_StartWarRequest(s, t.nNo)                                                @ FUN_0044d5b0 (0x0D26 if it returned 0; it returns 1)

Guild_StartWarRequest(s, enemyNo):
    now = time(); fake = PROTO_NC_GUILD_DB_WAR_ACK { Error=0x0C41, hWMChar=s.wmHandle, nNo=s.guildNo,
        nWarEnemy=enemyNo, dWarRequestDate=now, dWarStartDate=now+5 min, dWarEndDate=now+65 min }
    Guild_OnWarAck(G, fake)                                                        # no CharDB round trip at all
```

The WM never sends 0x7466 NC_GUILD_DB_WAR_REQ; it builds the answer itself and runs the 0x7467 handler code. The war
is therefore not persisted at request time (the result is written at the end with 0x7468). Neither guild's
`nType` (guild type / combat propensity, set by 0x74B7, §9.4) may be 0.

```pseudo
CharDB 0x7467 NC_GUILD_DB_WAR_ACK { u16 Error, DB_WAR_REQ { u16 hWMChar, u32 nNo, u32 nWarEnemy, i32 dWarRequestDate,
                                     i32 dWarStartDate, i32 dWarEndDate } }        @ FUN_0040bb90 → FUN_0044a660
Guild_OnWarAck(G, a):                                                              # also reached from §3.2
    s = Clients_GetByHandle(a.hWMChar)
    if a.Error != 0x0C41: if s: SendRaw(s, 0x7423 { a.Error }); return
    g = Guilds_FindByNo(a.nNo) (else return); e = Guilds_FindByNo(a.nWarEnemy) (NULL if 0 / unknown)
    if s: 0x7423 { 0x0C41 }
    g.nWarEnemy = e.nNo; g.sWarEnemyName = e.sName; g.nWarEnemyGrade = e.nGrade     # e == NULL → crash (original bug) W03-B5
    g.dWarRequestDate/StartDate/EndDate = a.…; g.nWarStatus = Guild_GetWarStatusNow(g); clear MyScore and EnemyScore
    Members_Broadcast(g.M) 0x7432 NC_GUILD_WAR_TARGET_CMD { SHINE_GUILD_WAR_INFO = e.nNo, e.sName, e.nGrade,
        g.nWarStatus, remainSec, g's 3 dates + tm, nRequestNo = g.nNo, MyScore = g.MyScore, EnemyScore = g.EnemyScore }
    Members_Broadcast(e.M) 0x7432 { g.nNo, g.sName, g.nGrade, g.nWarStatus, remainSec, dates, nRequestNo = g.nNo,
        MyScore = g.EnemyScore, EnemyScore = g.MyScore }
```

Client (`GuildTask::Recv_NC_GUILD_WAR_ACK` FUN_006b3cb0): 0x0D20/21/25/26/27 and 0x0D29 "Cannot request a Guild War.";
0x0D22 "You do not have the authority to request a Guild War."; 0x0D23 "You can register after current Guild War
ends."; 0x0D24 "Please wait to begin another Guild War."; 0x0D28 "Cannot begin a Guild War in the area."; 0x1BC0 "We
cannot apply for Guild War as our guild is scheduled for dismissal."; 0x1BC1 "The guild you selected cannot apply for
Guild War as it is scheduled for dismissal.".

### 3.3 War timer `Guilds_WarTick` (FUN_0044ce00, from the guild manager tick §7)

```pseudo
Guilds_WarTick(G):                                                                 @ FUN_0044ce00
    if now < g_NextWarTick (DAT_006d4c90): return; g_NextWarTick = now + 1 s
    for each guild g:
        status 1: now ≥ end → clear scores (FUN_0045aa30); Guild_WarEnd(g)
                  else now ≥ start → Guild_WarStart(G, g)
        status 2: now ≥ end → Guild_WarEnd(g)
        status 3: now ≥ end → g.nWarStatus = 0; Members_Broadcast 0x7435 NC_GUILD_WAR_COOLDOWN_DONE_CMD { u8 ? }
                  # the 1-byte payload is an uninitialised stack byte (original bug) W03-B6  @ FUN_004442e0

Guild_WarStart(G, g):                                                              @ FUN_00449e10
    e = Guilds_FindByNo(g.nWarEnemy); if !e: g.nWarEnemy = 0; g.nWarStatus = 0; return
    clear scores; g.nWarStatus = 2
    Zones_BroadcastRaw 0x7443 NC_GUILD_ZONE_WAR_START_CMD { u32 g.nNo, u32 e.nNo }
    Members_Broadcast(g.M) 0x7433 NC_GUILD_WAR_START_CMD { Name4 WarGuildName = e.sName, u32 RequestNo = g.nNo,
        i32 EndDate = g.dWarEndDate, tm }
    AcademyMembers_Broadcast(g.A) 0x987D NC_GUILD_ACADEMY_WAR_START_CMD { u32 e.nNo, u8 2 }   @ FUN_00447d70
    Members_Broadcast(e.M) 0x7433 { g.sName, g.nNo, EndDate, tm }; AcademyMembers_Broadcast(e.A) 0x987D { g.nNo, 2 }

Guild_WarEnd(g):                                                                   @ FUN_00449f80
    g.dWarEndDate = now + 120 min (+ tm); g.nWarStatus = 3
    Zones_BroadcastRaw 0x7444 NC_GUILD_ZONE_WAR_END_CMD { u32 g.nNo, u32 g.nWarEnemy }
    e = Guilds_FindByNo(g.nWarEnemy); if !e: g.nWarEnemy = 0; g.nWarStatus = 0; return
    r = Guild_WarResult(g) (FUN_0043cd70): Σ MyScore.nKillScore[7] vs Σ EnemyScore.nKillScore[7]:
        greater → 0 (win), smaller → 1 (lose), equal → 2 (draw); rE = mirrored (0↔1, 2 stays)
    Guild_ApplyWarResult(r, g, rE, e)                                              @ FUN_0043dfb0
        winner: nWarWinCount++ and nFame += (Σ of its own kill score) / 100;  loser: nWarLoseCount++;  draw: nWarDrawCount++
        (the enemy's fame gain uses g.EnemyScore, i.e. the kills the enemy made)
    Members_Broadcast(g.M) 0x7434 NC_GUILD_WAR_END_CMD { Name4 EnemyGuildName = e.sName, u32 RequestNo = g.nNo,
        u32 EnemyGuildFameAdd = 0, u32 GuildFameAdd = 0, u32 GuildTotalFame = g.nFame, u8 WarResult = r, u8 WarStatus = 3 }
    AcademyMembers_Broadcast(g.A) 0x987E NC_GUILD_ACADEMY_WAR_END_CMD { u32 e.nNo, u8 3 }      @ FUN_00447e20
    Members_Broadcast(e.M) 0x7434 { g.sName, g.nNo, 0, 0, e.nFame, rE, 3 }; AcademyMembers_Broadcast(e.A) 0x987E { g.nNo, 3 }
    SendRaw(CharDB, 0x7468 NC_GUILD_DB_RESULT_WRITE_CMD { u32 g.nNo, u32 g.nFame, u32 g.win, u32 g.lose, u32 g.draw,
        u32 e.nNo, u32 e.nFame, u32 e.win, u32 e.lose, u32 e.draw })               # 0x28 bytes, PDB GUILD_DB_RESULT_WRITE ×2
```

Both fame-add fields of 0x7434 are always 0 although fame was just added *(the client shows only the total)*.
The guild war timer runs every second; the 0x7433 / 0x7434 client handlers are `FUN_00430550` / `FUN_0069ae20`
(GuildTask). There is no guild-war item for the zone side here: zones learn start / end from 0x7443 / 0x7444.

### 3.4 War scoring: zone 0x7445 NC_GUILD_ZONE_WAR_KILL_CMD { u16 hWMKiller, u16 hWMTarget }

```pseudo
Zone_GuildWarKill(z, p):                                                           @ FUN_0042ac50 → FUN_0044d1b0
    k = Clients_GetByHandle(hWMKiller), t = Clients_GetByHandle(hWMTarget); both need CHARDATA, a guildNo and a
    loaded guild entry, else log "CGuildManager::Recv_NC_GUILD_ZONE_WAR_KILL_CMD - …" and stop
    Guild_AddWarKill(k, t)                                                         @ FUN_0044c7f0
Guild_AddWarKill(k, t):
    kg, tg = guild entries of k and t; km, tm = their member records (both must exist)
    pts = GradeScore[km.nGrade][tm.nGrade] (GuildGradeScoreData.shn, 7×7, FUN_0043c410)
        + LevelScore(k.level, t.level) (GuildLevelScoreData.shn rows 0..2, FUN_0043c450):
            target higher by ≤ row0.CheckLevel (5) → row0.Add (3); killer higher by ≤ row2.CheckLevel (5) → row2.Add (0);
            otherwise (equal, or gap above the limit) → row1.Add (2)
    if kg.nWarEnemy == tg.nNo: kg.MyScore.nKillCount[tm.nGrade]++; kg.MyScore.nKillScore[tm.nGrade] += pts; sync(kg)
    else: tg.EnemyScore.nKillCount[tm.nGrade]++; tg.EnemyScore.nKillScore[tm.nGrade] += pts; sync(tg)
        # assumes tg is the requester of a war against kg; not checked (the zone only sends kills between warring guilds)
Guild_SendWarScore(g) (FUN_004497c0): Members_BroadcastRaw to g and to g.nWarEnemy:
    0x742A NC_GUILD_WAR_SCORE_CMD { Name4 GuildName1 = g.sName, SHINE_GUILD_SCORE GuildScore1 = g.MyScore,
                                    Name4 GuildName2 = g.sWarEnemyName, SHINE_GUILD_SCORE GuildScore2 = g.EnemyScore }
```

The war state is not checked by the WM: a kill outside the war window still counts. 0x742A has no 2016 client
handler (C01 inventory), so the live war score is never shown. 0x742A is client-bound only
(answer to the C01 question: it goes to the online members of both guilds, never to a zone or the DB).

### 3.5 War lists and zone war queries

```pseudo
0x7424 NC_GUILD_WAR_ABLE_LIST_REQ (no payload)                                     @ FUN_004151b0 → FUN_0043e270
    if now ≤ s.lastWarAbleList(+0x1EDA0) + 5: Error 0x0D1C (nothing else)
    else s.lastWarAbleList = now; s.guildNo == 0 → 0x0D1A; guild g not found → 0x0D1B
    else for every guild h other than g, except the one g is currently at war with:
        row SHINE_GUILD_WAR_ABLE_INFO { h.nNo, h.sName, h.nType, h.nGrade, h.nWarStatus, h.nNumMembers,
            u8 nWarable = Guild_CanDeclareWar(g, h), Name4 sTargetName = name of h.nWarEnemy if h.nWarStatus is 1/2
            ("" if that guild is gone), else "" }
    0x7425 NC_GUILD_WAR_ABLE_LIST_ACK { u16 Error, u8 PartMask, u16 NumOfWarInfo, rows }, chunks of ≤ 48 rows
        (flush when 5 + n·0x2A > 0x7FD); the error replies carry 0 rows

0x7426 NC_GUILD_WAR_LIST_REQ (no payload)                                          @ FUN_004151f0 → FUN_0043e590
    s.guildNo == 0 → 0x0D19; guild not found → 0x0D18
    rows SHINE_GUILD_WAR_INFO (0xEA): first my own war if g is at war (enemy name/grade, g's dates/scores,
        nRequestNo = g.nNo), then one row for every guild h with h.nWarEnemy == my guildNo inside its window
        (h's name, dates, nRequestNo = h.nNo, MyScore = h.EnemyScore, EnemyScore = h.MyScore)
    0x7427 NC_GUILD_WAR_LIST_ACK { u16 Error, u8 PartMask, u16 NumOfWarInfo, rows } (chunks: 5 + n·0xEA > 0x7FD)
```

Client: 0x7425 → `GuildTask::Recv_NC_GUILD_WAR_ABLE_LIST_ACK` FUN_006b3e00: 0x0D1C "Please try later."; 0x0C41 and
0x3198 fill the list; 0x0D1A/0x0D1B are ignored silently. 0x7427 goes to the guild window listener (C01 §2).

Zone queries (CParserZone; answers go to the asking zone or to all zones):

```pseudo
0x7446 NC_GUILD_ZONE_LIST_REQ (no payload)                                         @ FUN_0042ac90 → FUN_0043ea00
    z ← 0x7447 NC_GUILD_ZONE_LIST_ACK { u8 PartMask, u16 NumOfList, GUILD_ZONE[n] (0x31: nNo = entry+0x788, sName,
        nMoney, nType, nGrade, nFame, nStoneLevel, nExp, nWarStatus, nWarEnemy) }, chunks 3 + n·0x31 > 0x7FD
0x7478 NC_GUILD_GUILDWARCONFIRM_REQ { u32 guildA, u32 guildB }                     @ FUN_0042acd0 → FUN_0043ebd0
    for X in (A, B): enemyX = X.nWarEnemy if X is in [start, end) else 0 (unknown guild → log "Not fount [A]/[B]")
    Zones_Broadcast 0x7479 NC_GUILD_GUILDWARCONFIRM_ACK { {u32 guildA, u32 enemyA}, {u32 guildB, u32 enemyB} }
        # to every zone, not only the asking one
0x7495 NC_GUILD_GUILDWARSTATUS_REQ (no payload)                                    @ FUN_0042ad50 → FUN_0043f060
    z ← 0x7496 NC_GUILD_GUILDWARSTATUS_ACK { u16 warnumber, {u32 guildNo, u32 enemyNo}[warnumber] } for every guild
        with nWarStatus == 2 (no chunking; > 1023 wars would overflow the 0x2000 buffer)
```

### 3.6 0x7473 NC_GUILD_CHAT_REQ { u8 itemLinkDataCount; u8 len; content[len]; links[count]·0x67 }

```pseudo
Client_GuildChatReq(s, p):                                                         @ FUN_00415230
    err(code) = SendRaw(s, 0x7475 NC_GUILD_CHAT_ACK { u16 code })                   @ FUN_0043f6b0
    prison → 0x0D2E;  s.guildNo == 0 → 0x0D2C;  guild not found → 0x0D2D
    Members_Chat(g.M, s, p)                                                        @ FUN_004447b0
Members_Chat(M, s, p):
    cmd = 0x7474 NC_GUILD_CHAT_CMD { u32 nGuildNo = s.guildNo, Name5 talker = s name, u8 itemLinkDataCount, u8 len,
        content[len], links (count · 0x67 bytes) }        # len and count are not checked against the packet size
    if s.singleOption.nChatBan (+0x658 → +10) != 0: send cmd to s only             # chat-banned: only the sender sees it
    else Members_Broadcast(M, cmd, 1, s.+0x1E280)                                  # skip members with +0x1E280 == 1 when
                                                                                   # the sender's own +0x1E280 is 0
```

No success ACK. Client (`GameFrameWork::On_NC_GUILD_CHAT_ACK` FUN_004a9f50): 0x0D2C "You are currently not registered
in any guild."; 0x0D2B nothing; any other code (incl. 0x0D2D, 0x0D2E) "Failed in Guild Chat.". 0x7474 is shown by
`FUN_004a1a80`. The copy reads `len + count·0x67` bytes from the request without a length check (original bug) W03-B7.

### 3.7 0x7476 NC_GUILD_NAME_REQ { u32 nNo }

```pseudo
Client_GuildNameReq(s, p):                                                         @ FUN_004152f0 → FUN_0044ace0
    name = Guilds_FindByNo(p.nNo)'s sName, or "" when unknown
    SendRaw(s, 0x7477 NC_GUILD_NAME_ACK { u32 nNo, Name4 Name, GUILD_EMBLEM_INFO EmblemInfo })
        EmblemInfo = 0xFFFF when the emblem state is 1, 4 or 0xFF, else entry+0x774
        # unknown guild (or nNo = 0): EmblemInfo is an uninitialised stack word (original bug) W03-B8
```

Client: `GuildNameCache` (`FUN_004c3bf0`) caches the name and emblem by guild number. OPTool 0x2824 also sends 0x7477
(W04).

### 3.8 Guild tokens

```pseudo
CharDB 0x74BD NC_GUILD_DB_TOKEN_ALL_ACK { u16 Error, u8 PartMask, u16 n, GUILD_TOKEN_DB[n] { u32 nNo, u64 nGuildToken } }
                                                                                   @ FUN_0040b870 → FUN_0043f3c0
    Error != 0x0C41 → log "FAILED - CGuildManager::Recv_NC_GUILD_DB_TOKEN_ALL_ACK"
    for each row: entry(nNo).nGuildToken = row.nGuildToken (unknown guild → log)
    PartMask & 2 → G.tokensLoaded = 1; then (FUN_0040b870) CharDB link state = 0xB (W01 start-up sequence)

0x74BE NC_GUILD_MY_GUILD_TOKEN_INFO_REQ (no payload)                               @ FUN_00414ec0
    s.guildNo == 0 → SendRaw 0x74BF { Error 0x0CCB, u64 garbage };  not found → 0x74BF { 0x0CCA, garbage }
        # raw 13-byte reply with only the code set: the 8 token bytes are uninitialised (original bug) W03-B9
    else 0x74BF NC_GUILD_MY_GUILD_TOKEN_INFO_ACK { 0x0C41, u64 nGuildToken }        @ FUN_0043cdd0

Zone 0x74C0 NC_GUILD_ZONE_USE_GUILD_TOKEN_CMD { u32 nGuildNo, u64 nDecrease }      @ FUN_0042ad90 ("fc_NC_GUILD_ZONE_USE_GUILD_TOKEN_CMD")
    nGuildNo == 0 or unknown → log, stop
    if nDecrease ≤ g.nGuildToken: g.nGuildToken -= nDecrease
    else log "…WorldKnownToken…"; g.nGuildToken = 0
    Zones_BroadcastRaw 0x74C1 NC_GUILD_WORLD_USE_GUILD_TOKEN_CMD { u32 nGuildNo, u64 nDecrease, u64 nGuildToken }
    Members_Broadcast(g.M) 0x74C2 NC_GUILD_WORLD_SET_GUILD_TOKEN_CMD { u64 nDecrease, u64 nGuildToken }   @ FUN_00443060
```

Tokens are spent by the zones (guild token shop, D/Z items); the WM only mirrors the balance; it never writes it to
the DB itself. Client: 0x74BF → `GuildTask::Recv_NC_GUILD_MY_GUILD_TOKEN_INFO_ACK` FUN_006b36e0 (only 0x0C41 is used);
0x74C2 → FUN_006b3940.

### 3.9 0x74C3 NC_GUILD_MY_GUILD_TOURNAMENT_MATCH_TIME_REQ (no payload)

```pseudo
                                                                                   @ FUN_00414fa0
    s.guildNo == 0 → SendRaw 0x74C4 { Error 0x1B69, GT_COND_INFO garbage (0x2B uninitialised bytes) }
    guild not found → 0x74C4 { 0x1B6A, garbage }                                    # (original bug) W03-B9
    else 0x74C4 NC_GUILD_MY_GUILD_TOURNAMENT_MATCH_TIME_ACK { Error = 0x1B68, GT_COND_INFO of the guild }   @ FUN_0043cea0
```

0x1B68 is the success code of this packet. Client (`GuildTask::Recv_…_MATCH_TIME_ACK` FUN_006b5270) acts only on
0x1B68: nMyGTCondition 0 "There is no Guild Tournament schedule"; 1 "It is time to join the Guild Tournament" (bIsJoin
0) / "You have joined the Guild Tournament" (bIsJoin 1); 2 "Next Match: %m/%d %H:%M"; 3 "Guild Tournament in
Progress"; 4 with nGTGrade ≠ 0 "You won %d place in the Guild Tournament".

### 3.10 Guild history 0x74FD NC_GUILD_HISTORY_LIST_REQ (no payload)

```pseudo
Client_GuildHistoryReq(s):                                                         @ FUN_004189c0 ("fc_NC_GUILD_HISTORY_LIST_REQ")
    if now < s.nextHistory(+0x1ED98): log "ERROR - CParserClient::fc_NC_GUILD_HISTORY_LIST_REQ(CharRegNum:%d)"; return
    s.nextHistory = now + 1
    err(code) = 0x74FE NC_GUILD_HISTORY_LIST_ACK { u16 code, Total=0, Count=0, Index=0 }   @ FUN_00443640
    prison → 0x3184;  s.guildNo == 0 → 0x3182;  guild not found → 0x3183
    Send CharDB 0x74FF NC_GUILD_HISTORY_DB_LIST_REQ { u16 hWMChar, u32 nGuildNo }   @ FUN_00448d60 → FUN_00443580

CharDB 0x7500 NC_GUILD_HISTORY_DB_LIST_ACK { u16 Error, u16 hWMChar, u16 Total, u16 Count, u16 Index, GUILD_HISTORY[Count] }
                                                                                   @ FUN_0040e1a0 → FUN_00448d70
    s = FUN_00438180(hWMChar) (Clients_GetByHandle variant that also needs s.+0x704 inGame)
    Error == 0x3180 (= success code of this packet): s ← 0x74FE { 0x3180, Total, Count, Index, rows (0x20 each) }
    else s ← 0x74FE { Error } (zeros)
```

`GUILD_HISTORY` *(pdb2017)* = { u32 nHistoryNumber, GUILD_HISTORY_DATE {u16 year, u8 mon, u8 day}, Name5 sCharName,
i32 nMessageType (`GUILD_HISTORY_MSG_TYPE`: 0 created, 1 join, 2 leave, 3 vanish, 10–13 grade to master / sub-master
/ elder / guard; 100–103 the academy equivalents) }. The WM never writes history rows; the Character DB procedures do.
Client (`GuildTask::Recv_NC_GUILD_HISTORY_LIST_ACK` FUN_006b6f50): 0x3180 fills the list; 0x3182 "You are not the
Guild Member"; 0x3183 "Information of your Guild cannot be found"; 0x3184 "You cannot view Guild history from this
field.".

### 3.11 Guild emblem

State `GUILD_EMBLEM_STATE` at entry+0x778 (§1.2). Server parameters (read once, cached): "GE_Member_60Lv",
"GE_Member_100Lv" (member-count thresholds), "GE_Change_Month", "GE_Delete_Term_Date" (days).

- `Emblem_HasEnoughMembers(g)` FUN_0044e6a0: count members with level ≥ 60 and with level ≥ 100 (from the member
  table); 1 when both counts reach the thresholds.
- `Emblem_PeriodOver(g)` FUN_0044e800 (returns, from the asm): 1 when "GE_Change_Month" is 0, or when the (year, month)
  of `emblemSaveDate(+0x77C) + GE_Change_Month months` is before the current (year, month); else 0.
- `Emblem_Refresh(g)` FUN_0044e910 (on each `Guild_SendEmblemToSession`):

  | state | not enough members | enough members |
  |---|---|---|
  | 0xFF NULL | → 4 | stays |
  | 4 NULL_LIMIT_MEMBER | stays | → 0xFF |
  | 0 ON | → 1 | → 3 if saveDate > 0 and !PeriodOver, else stays |
  | 1 OFF_LIMIT_MEMBER | stays | → 0 if saveDate > 0 and PeriodOver, else → 3 |
  | 3 ON_LIMIT_DATE | → 1 | → 0 if saveDate > 0 and PeriodOver, else stays |

  These are memory-only changes; the DB is not told (the member-change paths below do tell it).
- `Guild_SendEmblemToSession(s)` FUN_00430bc0: Emblem_Refresh; if s.emblemOffNoticePending == 1: if state == 1 and
  now < deleteDate(+0x780): s ← 0x7509 NC_GUILD_EMBLEM_OFF_MSG_CMD { u8 nMonth, u8 nDay of deleteDate }; pending = 0.
  Always s ← 0x750A NC_GUILD_EMBLEM_INFO_CMD { GUILD_EMBLEM_INFO, u8 EmblemState }.
- `Guild_BroadcastEmblemInfo(G, guildNo)` FUN_00443a40: Members_Broadcast 0x750A.
- `Guild_BroadcastEmblemNotice(G, guildNo)` FUN_00443b20: 0x750B NC_GUILD_EMBLEM_INFO_NOTICE_CMD { u32 nGuildNo,
  GUILD_EMBLEM_INFO (0xFFFF when state 1/4/0xFF) } to **every in-game client** (list at g_Clients+0x10).

```pseudo
0x7501 NC_GUILD_EMBLEM_CHECK_AVAILABILITY_REQ (no payload)                         @ FUN_00418f30 → FUN_00443890
    no CHARDATA / no guild / not a member → no answer
    grade != 0 → 0x7502 NC_GUILD_EMBLEM_CHECK_AVAILABILITY_ACK { 0x3704 }
    state 0, 2, 0xFF → 0x3700;  1, 4 → 0x3702;  3 → 0x3703

0x7505 NC_GUILD_EMBLEM_SAVE_REQ { GUILD_EMBLEM_INFO { u8 nPTFileNo, u8 nPTIconNo } }   @ FUN_00418f70 → FUN_0044f840
    no CHARDATA / guild / membership → no answer
    grade != 0 → 0x7506 NC_GUILD_EMBLEM_SAVE_ACK { 0x3704 };  either byte == 0xFF → 0x3701
    state 1 or 4: enough members → no answer at all (original bug) W03-B10; else 0x3702
    state 3: PeriodOver → no answer (original bug) W03-B10; else 0x3703
    else Send CharDB 0x7507 NC_GUILD_EMBLEM_SAVE_DB_REQ { u32 nCharNo, u32 nGuildNo, GUILD_EMBLEM_INFO, i32 now }

CharDB 0x7508 NC_GUILD_EMBLEM_SAVE_DB_ACK { u32 nCharNo, GUILD_EMBLEM_INFO, i32 EmblemCreateDate }
                                                                                   @ FUN_0040e6d0 → FUN_0044fae0
    s = Clients_FindByCharNo(nCharNo) (gone → ignored); g = entry of s.guildNo
    g.emblem = EmblemInfo; g.saveDate = EmblemCreateDate
    if g.state is 1 or 4:
        Send CharDB **0x110D** { u32 guildNo, i32 today + GE_Delete_Term_Date days, u8 1 }   # wrong opcode: should be
            0x750D NC_GUILD_EMBLEM_STATE_DB_REQ (original bug) W03-B11
    else: g.state = PeriodOver ? 0 : 3; Guild_BroadcastEmblemInfo; Guild_BroadcastEmblemNotice
    s ← 0x7506 { 0x3700 }

CharDB 0x750E NC_GUILD_EMBLEM_STATE_DB_ACK { u32 nGuildNo, i32 EmblemDeleteDate, u8 EmblemState }   @ FUN_0040e730
    unknown guild → ignored
    state 2 (DELETED): g.state = enough ? 0xFF : 4; emblem = 0xFFFF; saveDate = 0; deleteDate = 0
    state 0 or 3: if g.state is 0xFF or 4 (no emblem): saveDate = 0;
                      Send CharDB 0x750D { nGuildNo, 0, enough ? 0xFF : 4 }; stop (no broadcast)
                  else g.state = state; deleteDate = EmblemDeleteDate
    other: g.state = state; deleteDate = EmblemDeleteDate
    Guild_BroadcastEmblemInfo; Guild_BroadcastEmblemNotice

CharDB 0x7504 NC_GUILD_EMBLEM_INFO_DB_ACK { u8 PartMask, u16 n, GUILD_EMBLEM_INFO_DB[n] (0xF: u32 nNo,
    GUILD_EMBLEM_INFO, i32 saveDate, i32 deleteDate, u8 state) }                   @ FUN_0040e640 (start-up)
    PartMask == 2 → CharDB link state 9 (W01 start-up)
    each row: g = Guilds_FindByNo(nNo) — not checked for NULL (unknown guild crashes the WM, original bug W03-B12);
              emblem, saveDate, deleteDate set; state = row.state if 0/1/2, else 0xFF (FUN_0043d080)

Zone 0x750C NC_GUILD_EMBLEM_LEVELUP_CMD { u32 nCharNo }                             @ FUN_0042d220
    character's guild g: state 1 and enough → CharDB 0x750D { nGuildNo, 0, PeriodOver ? 0 : 3 }
                         state 4 and enough → g.state = 0xFF; Guild_BroadcastEmblemInfo
```

Member losses (0x7472, 0x746C) in state 0 or 3 without enough members send 0x750D { nGuildNo, today +
GE_Delete_Term_Date days, 1 }; in state 0xFF they switch to 4 and broadcast 0x750A. Member gains (0x746A) and level-ups
(0x750C) do the opposite. Client: 0x7502 → `GuildTask::Recv_NC_GUILD_EMBLEM_CHECK_AVAILABILITY_ACK` FUN_006b5be0 and 0x7506 →
`…EMBLEM_SAVE_ACK` FUN_006b5da0: 0x3701 "No Emblem has been selected."; 0x3702 "You can only set a Guild Emblem when you
have more than 20 (Lv60), and 5 (Lv100) members or higher in your guild." (the client's idea of the GE_Member
defaults); 0x3703 "You can change the Guild Emblem once per month."; 0x3704 "You can change the Guild Emblem next
month." — but the WM uses 0x3704 for "not the guild master", so a non-master gets the wrong text (code / text
mismatch, original bug W03-B30). 0x750A / 0x750B go to GuildTask handlers without code texts. Note 0x7504 NC_GUILD_EMBLEM_INFO_DB_ACK starts with PartMask, no Error field *(pdb2017 agrees)*.

## 4. Guild and academy hooks in the character life cycle (W01 handlers, guild parts)

W01 registers these handlers and left their guild parts to this item (W01-core §… "W03").

### 4.1 Character login data from the Character DB

```pseudo
CharDB 0x1012 NC_CHAR_GUILD_CMD { u16 handle, u32 guildNo }                         @ FUN_0040a700
    s = Clients_GetByHandle(handle) (else ignored)
    s.guildNo = guildNo; s.guildEntry = Guilds_FindByNo(guildNo); s.guildInfoPending(+0x1DF84) = 1
    s.emblemOffNoticePending(+0x1DF9C) = 1

CharDB 0x1097 NC_CHAR_GUILD_ACADEMY_CMD { u16 handle, u32 academyGuildNo }          @ FUN_0040cdb0
    s.academyGuildNo = s.academyEntry = s.isAcademyMember = s.+0x1DF98 = s.academyInfoPending(+0x1DF90) = 0
    if academyGuildNo != 0: s.academyEntry = Guilds_FindByNo(academyGuildNo)
        if found: s.academyGuildNo = academyGuildNo; s.isAcademyMember = 1; s.academyInfoPending = 1
```

Both only fill the session; nothing is sent until the character enters a map (§4.2). An unknown academy guild leaves
the character without academy.

### 4.2 Map login: `Client_RefreshGuildState` (FUN_004360f0)

Called from zone 0x180C map login (`FUN_0042d8d0`, W01), from 0x746A guild join (§2.5) and from the academy join
path (FUN_0044f660, §5).

```pseudo
Client_RefreshGuildState(s):                                                       @ FUN_004360f0
    Client_SendAcademyInfo(s)                                                      @ FUN_00434eb0
    if s.academyEntry: Academy_BroadcastMemberMap(A) 0x9863 NC_GUILD_ACADEMY_MEMBER_MAP_CMD { Name5 name, Name3 map }
                       to the academy members (FUN_004477b0) and to the guild members (FUN_0044b030)
    Client_SendGuildInfo(s)                                                        @ FUN_00434ab0
    if s.guildEntry:
        Members_BroadcastRaw(M) 0x7441 NC_GUILD_MEMBER_MAP_CMD { Name5 CharID, Name3 sMap = CHARDATA.map }   @ FUN_00449720
        if the member whose charNo is s.+0x1E28C is the academy master (FUN_0045ab70 == 0):
            0x9863 { name, map } to the academy members as well

Client_SendGuildInfo(s):                                                           @ FUN_00434ab0
    if !s.guildInfoPending: return; s.guildInfoPending = 0
    if s.guildNo and s.guildEntry:
        s ← 0x1012 NC_CHAR_GUILD_CMD { u32 guildNo, GUILD_CLIENT } (0x42F bytes)
        Members_RequestList(g.M, s)        # loads the table or marks s online and sends 0x741B (§2.11)
        Guilds_SendWarList(G, s)           # 0x7427 (§3.5)
        Members_BroadcastRaw 0x743D NC_GUILD_MEMBER_LOGON_CMD { Name5 CharID }        @ FUN_004495a0
        Tournament_SendList(s)             # 0x747F (§8.2)
    else: (guildNo set but entry missing → log, clear both) s ← 0x1012 { u32 0 } (4 bytes)

Client_SendAcademyInfo(s):                                                         @ FUN_00434eb0
    if not ((s.academyInfoPending == 1 and s.isAcademyMember == 1) or (s.guildInfoPending == 1 and s.isAcademyMember == 0)):
        return
    s.academyInfoPending = 0
    if s.academyGuildNo:                    # academy member
        a = s.academyEntry (missing → log, clear academy fields, send 5-byte form)
        s ← 0x1097 NC_CHAR_GUILD_ACADEMY_CMD { u32 academyGuildNo, u8 1, GUILD_ACADEMY_CLIENT of a } (0x2E5)
    elif s.guildNo and s.guildEntry:        # guild member: its own guild's academy
        s ← 0x1097 { u32 guildNo, u8 0, GUILD_ACADEMY_CLIENT with dAcademyBuffUntilTime turned into seconds left (0 if past) }
    else: s ← 0x1097 { u32 0, u8 0 } (5 bytes)
    Academy_SendWarInfo(G, s)                                                      @ FUN_00441630
        # academy members only: 0x987C NC_GUILD_ACADEMY_WAR_INFO_LIST_CMD { u16 n, {u32 guildNo, u8 warStatus}[n] }:
        # the academy's guild's own enemy (if at war) and every guild at war with it
    if the session is in an academy or a guild (see code for the exact flag test):
        AcademyMembers_RequestList(a.A, s, …)                                      @ FUN_0044b890 (§5)
        0x9861 NC_GUILD_ACADEMY_MEMBER_LOGON_CMD { Name5 } to the academy (FUN_00447630) and to the guild (FUN_0044b0d0)
```

The 0x1097 sent to the client reuses the opcode the Character DB uses for the WM (different payload). For a plain
guild member, the "academy" block describes its own guild's academy (master name, member count, notice…).

### 4.3 Members_OnLoaded (FUN_0044c5f0), the end of a member-table load

```pseudo
Members_OnLoaded(M):
    for each member i: for each queued handle h: if Clients_GetByHandle(h).charNo == member i: online bit = 1, session[i] = s
    for each queued handle h (popped and freed):
        s = Clients_GetByHandle(h); if s: r = Members_SendList(M, s)
            if r == 0 (send failed) and s.CHARDATA: member of s goes offline: session = 0,
                dLogonInfo = { login 0, year, month, day, hour } = now (FUN_0043c990 layout); Members_BroadcastRaw 0x743E
```

`SHINE_GUILD_MEMBER_LOGON_INFO` *(pdb2017)*: bit0 login, bits 1–11 year, 12–15 month, 16–20 day, 21–25 hour (the top
6 bits are kept).

### 4.4 Logout (`CharacterLogout` FUN_00436d50, W01 §5.4) → `Guild_OnLogout` (FUN_0044ccf0)

```pseudo
    if s.isAcademyMember == 0:
        g = guild of s.guildNo; i = member index of s (none → nothing)
        Members_SetOffline(M, i) (FUN_0043c990: session 0, logon info = now, login bit 0)
        Members_BroadcastRaw 0x743E NC_GUILD_MEMBER_LOGOFF_CMD { Name5 CharID }        @ FUN_00449620
    elif s.academyGuildNo:
        g = guild of s.academyGuildNo; i = A.vtbl[12](charNo) (index by charNo)
        AcademyMembers_SetOffline(A, i) (FUN_00440d00); 0x9862 NC_GUILD_ACADEMY_MEMBER_LOGOFF_CMD { Name5 } to the
        academy (FUN_004476b0) and to the guild members (FUN_0044b150)
```

The guild / academy fields of the session are not cleared at logout (the session is recycled by W01).

### 4.5 Character delete: guild check (0x1407 → 0x1413 → 0x1414 / 0x1416)

The 2016 delete request 0x1407 (W01 `FUN_00412fa0`) sends CharDB **0x1413 NC_AVATAR_GUILD_DATA_REQ** { u16 handle,
u32 charNo, u8 slot } (W01-core §4.1 says 0x1408; the code sends 0x1413, header bytes `09 13 14`). The answers:

```pseudo
CharDB 0x1414 NC_AVATAR_GUILD_DATA_ACK { u16 handle, u32 nGuildNo, u32 chrregnum, u8 slot }   @ FUN_0040c6e0
    s = Clients_GetByHandle(handle) (else ignored)
    if nGuildNo != 0:
        g = Guilds_FindByNo(nGuildNo); if !g: log; SendRaw(s, 0x140A NC_AVATAR_ERASEFAIL_ACK { u16 0x00C9 }); return
        i = member index of chrregnum (FUN_0043c820)
        if i == -1 (member table not loaded): SendRaw(CharDB, 0x1415 NC_AVATAR_GUILD_MEMBER_DATA_REQ { u16 handle,
            u32 chrregnum, u32 nGuildNo, u8 slot }); return                         # answer 0x1416
        if M[i].nGrade == 0: SendRaw(s, 0x140A { 0x00C7 }); return                 # 199: the guild master
    SendRaw(CharDB, 0x1408 NC_AVATAR_ERASEDATA_REQ { u16 handle, u32 usrregnum = s.userNo(+0x124), u32 avatar =
        chrregnum, u8 slot, u32 nNo = nGuildNo })                                  # continue the delete (W01)

CharDB 0x1416 NC_AVATAR_GUILD_MEMBER_DATA_ACK { u16 handle, u32 chrregnum, u8 slot, u32 nNo, u16 Error, u8 PartMask,
    u16 NumOfMember, GUILD_MEMEBER_INFO[n] }                                        @ FUN_0040c880 → FUN_00440220
    s = Clients_GetByHandle(handle) (else ignored)
    Error != 0x0C41 → log "FAILED - CGuildManager::Recv_NC_AVATAR_GUILD_MEMBER_DATA_ACK (%d)"; s ← 0x140A { Error }
    g = Guilds_FindByNo(nNo), else log "…Not found Guild"; s ← 0x140A { 0x00C3 }
    load the rows into g.M exactly like 0x7455 (PartMask bit0 resets, ≤ 400)
    if PartMask & 2: g.nNumMembers = M.count; M.loadState = 2
        i = member with charNo == chrregnum; none → 0x140A { 0x00C3 }; grade 0 → 0x140A { 0x00C7 }
        else SendRaw(CharDB, 0x1408 { handle, s.userNo, chrregnum, slot, nNo })
```

The second path loads the member table without running `Members_OnLoaded`: queued handles of a concurrent
0x741A stay in the queue until the next load *(inferred from the code; no flush here)*. Client texts (W01): 199 "You
may not delete guild leader."; any other code "Unable to delete a Guild Master character.".

### 4.6 Rename / delete of a character: `CWMClientSession::CharIDChange` (FUN_00431dd0, W01)

Guild part, for the first guild whose member table holds the charNo with the old name:

```pseudo
    if the character is the academy master (Name5 equal to entry+0x480):
        delete → academy master name = name of the first grade-0 member (FUN_00443110); rename → new name
        Members_Broadcast and AcademyMembers_Broadcast 0xB40E { Name5 sMasterID }
            # PROTO_NC_USER_CONNECTION_CHANGE_CHAR_ID_ACADEMY_MASTER_CMD (pdb2017 struct name; dept 45 cmd 14)
    delete → remove the member (FUN_00449100), nNumMembers = count;  rename → member name = new name
    log "DEBUG - CWMClientSession::CharIDChange : Guild - sOldCharID(%s), sNewCharID_char(%s)"
    else, if the academy table holds the charNo with the old name:
        delete → remove (FUN_0044b840), nNumAcademyMembers = A.count;  rename → name = new name
```

Nothing is sent to the zones or the DB here (the DB already applied the change). The academy index bound check
compares with 400 instead of 100 (dead: the lookup returns −1 when absent).

### 4.7 Level change: zone 0x1074 NC_CHAR_LEVEL_CHANGED_CMD (FUN_0042e160, W01 §7.5), guild part

```pseudo
    if s in a guild: M[i].nLevel = level; Members_BroadcastRaw 0x7440 NC_GUILD_MEMBER_LEVEL_CMD { Name5, u8 level }  @ FUN_004496a0
    if s is an academy member (isAcademyMember == 1):
        A[i].nLevel = level
        0x9866 NC_GUILD_ACADEMY_MEMBER_LEVEL_CMD { Name5, u8 level } to the guild (FUN_0044b1d0) and the academy (FUN_00447730)
        if level == 60: SendRaw(CharDB, 0x9851 NC_GUILD_ACADEMY_DB_GRADUATE_JOIN_REQ { u16 handle, u32 charNo,
                            u32 academyGuildNo, Name5 name, u8 class, u8 level })   # graduation (§6.2, 0x9852)
        if level ≤ 60 and GuildAcademyLevelUp.shn has a row for level (FUN_0043c670):
            SendRaw(CharDB, 0x9854 NC_GUILD_ACADEMY_DB_LEVEL_UP_REQ { u16 handle, u32 academyGuildNo, u32 Point,
                            u32 BuffTime })                                        # answer 0x9855 (§6.4)
```

Level 60 sends both the graduation and the level-up request. Above 60 nothing academy-related is sent.

## 5. Guild academy: client handlers (CParserClient, dept 38)

Every guild has one academy (entry+0x480 `GUILD_ACADEMY_CLIENT`, member table A, §1.4). Academy members are
characters below level 60 that are *not* guild members (`s.isAcademyMember = 1`, `s.academyGuildNo`); the academy
master is a guild member named in `sAcademyMasterName` (default: the guild master). "Owner guild of s" below means
`s.guildNo` for guild members and `s.academyGuildNo` for academy members. Success code of most academy packets is
0x1780; each reply has its own error range. Academy-specific helpers: `AcademyMembers_IndexByName` FUN_0045b270,
A.vtbl[12] = index by charNo, `Academy_IsMaster(g, member)` FUN_0045ab70 (0, else 0x17FF "Not a Guild Academy Master").

Academy re-join block: entry+0x17B94 is a `vector<{u32 charNo, i32 since, i32 until}>`; a kick (0x9816) appends the
kicked charNo with `until = now + "Academy_CannotJoinNotTime" minutes` (FUN_0044ff90); `Academy_CanJoin` FUN_0044c570
scans from the newest entry backwards and refuses while a matching entry has not expired.

```pseudo
0x9807 NC_GUILD_ACADEMY_MY_GUILD_ACADEMY_INFO_REQ (no payload)                      @ FUN_00421f40
    owner guild missing → SendRaw 0x9808 { Error 0x19B9 } (no guild) / { 0x19BA } (guild not found)
    else 0x9808 NC_GUILD_ACADEMY_MY_GUILD_ACADEMY_INFO_ACK { Error 0x19B8, GUILD_ACADEMY_CLIENT with the buff end
        turned into seconds left }                                                   @ FUN_00444a30

0x9809 NC_GUILD_ACADEMY_MY_ACADEMY_RANK_INFO_REQ (no payload)                        @ FUN_00415ce0
    no owner guild → SendRaw 0x980A NC_GUILD_ACADEMY_MY_ACADEMY_RANK_INFO_ACK { Error 0x1899, 12 uninitialised bytes }
    guild missing → 0x980A { 0x189A, garbage }
    else Send **0x9808** { Error 0x1898, u32 nAcademyPoint, u32 nAcademyRank, i32 buff seconds left }   @ FUN_0043cf90
        # the success answer uses the opcode of MY_GUILD_ACADEMY_INFO_ACK with the RANK_INFO layout (original bug) W03-B20

0x980B NC_GUILD_ACADEMY_LIST_REQ (no payload)                                        @ FUN_00422060
    prison → SendRaw 0x980C { Error 0x18A9 … }; else Academies_SendList (FUN_00447ed0): 0x980C NC_GUILD_ACADEMY_LIST_ACK
    { u16 Error, u8 PartMask, u32 Total, u32 n, SHINE_GUILD_ACADEMY_LIST[n] (0x2A) } in chunks (flood guard like 0x7403
    not present) *(row fields per pdb2017; per-field copy not traced)*

0x980D NC_GUILD_ACADEMY_MEMBER_LIST_REQ (no payload)                                 @ FUN_00422120
    guild member: academy of its own guild; academy member: its academy; both set or none → 0x980E { 0, 0, 0 }
    AcademyMembers_RequestList(A, s) (FUN_0044b890): loadState 0 → 1, queue, CharDB 0x980F NC_GUILD_ACADEMY_DB_MEMBER_REQ
        { u32 guildNo }; 1 → queue; 2 → mark s online if academy member, send 0x980E NC_GUILD_ACADEMY_MEMBER_LIST_ACK
        (FUN_00447110, GUILD_ACADEMY_MEMBER_CLIENT rows)

0x9811 NC_GUILD_ACADEMY_MEMBER_JOIN_REQ { Name4 sGuildName }                          @ FUN_00415dc0
    reply(code) = SendRaw(s, 0x9812 NC_GUILD_ACADEMY_MEMBER_JOIN_ACK { Name4 GuildName, u16 Error })   @ FUN_0044bb10
    in a guild → 0x1789; in an academy → 0x178A; class byte (SHAPE & 0x7C) == 0x68 → 0x1782 *(class not decoded)*
    level ≥ 60 → 0x1781; guild unknown → 0x178B; academy full (≥ 100) → 0x178C; Academy_CanJoin false → 0x31B8
    SendRaw(CharDB, 0x9814 NC_GUILD_ACADEMY_DB_MEMBER_JOIN_REQ { u16 hWMChar, u32 nGuildNo, u32 charNo, Name5 name,
        u8 class, u8 level, … })                                                    @ FUN_0044bb70 (0x178D if it failed; it cannot)
    # no invitation and no consent of the academy is needed: any low-level guildless character can join any academy

0x9816 NC_GUILD_ACADEMY_MEMBER_VANISH_REQ { Name5 name }                              @ FUN_0041e700
    reply(code) = SendRaw(s, 0x9817 NC_GUILD_ACADEMY_MEMBER_VANISH_ACK { Name5, u16 code })   @ FUN_0044bfb0
    prison → 0x179F; s.guildNo 0 → 0x1799; guild missing → 0x1798; not grade 0 → 0x179B (guild master only)
    i = academy index by name; < 0 → 0x179A; ≥ 100 → 0x31B9 (cannot happen with 100 slots; the client text for
        0x31B9 is a time limit "You can't exile this member from academy yet." — the 2016 WM has no academy kick delay;
        0x179C "may not ban yourself" is never sent; code-semantics mismatch, original bug W03-B31)
    add A.server[i].charNo to the re-join block; r = AcademyMembers_VanishReq (FUN_0044ba80) → CharDB 0x9819
        NC_GUILD_ACADEMY_DB_MEMBER_VANISH_REQ (FUN_00448120); r != 0x1780 → reply r (0x179A / 0x179D)
    # the block entry is added before the DB answers, also when the DB then fails (original bug) W03-B26

0x981B NC_GUILD_ACADEMY_MEMBER_LEAVE_REQ (no payload)                                 @ FUN_00415f30
    prison → 0x981C { 0x17A3 }; no academy → 0x17A0; academy guild missing → 0x17A1
    r = AcademyMembers_LeaveReq(A, s) (FUN_0044b990): not in A → 0x17A0; "can leave" time (server record +4) not
        reached → 0x17A4 (time from GuildAcademy.shn LeastJoinTime *(inferred)*); else CharDB 0x981D
        NC_GUILD_ACADEMY_DB_MEMBER_LEAVE_REQ (FUN_004481a0); 0x17A2 on send failure
    r != 0x1780 → 0x981C { r }                                                       @ FUN_00441fa0

0x981F NC_GUILD_ACADEMY_MASTER_TELEPORT_REQ { Name5 sTargetCharID }                    @ FUN_00416010
    reply(code) = SendRaw(s, 0x9820 NC_GUILD_ACADEMY_MASTER_TELEPORT_ACK { code })   @ FUN_00441fd0
    prison → 0x17A8; no guild → 0x17AA; guild missing → 0x17AB; s is not the academy master (name) → 0x17AE
    i = academy index of the target; > 100 → 0x17AC; target offline → 0x17AD; target in prison → 0x17A9
    Zones_Broadcast 0x9878 NC_GUILD_ACADEMY_ZONE_MASTER_TELEPORT_CMD { u32 masterCharNo, Name5 target }   @ FUN_00441ed0
        # every zone gets it; the zone holding the target moves it to the master (Z-item); no success ACK from the WM

0x9821 NC_GUILD_ACADEMY_MEMBER_CHAT_BAN_REQ { Name5 sChatBanTargetCharID }               @ FUN_004161b0
    err(code) = 0x9822 NC_GUILD_ACADEMY_MEMBER_CHAT_BAN_ACK { code }                  @ FUN_00442030
    prison → 0x17B5; s not a guild member (or an academy member) → 0x17B2; guild missing → 0x17B4
    grade > 3 → 0x17B1;  academy index ≥ 0x65 → 0x17B3;  target offline → 0x17B7;  target already banned
    (target +0x1DF98 > now) → 0x17B6
    Send CharDB 0x9887 NC_GUILD_ACADEMY_MEMBER_DB_CHAT_BAN_REQ { u32 guildNo, u32 myCharNo, u32 targetCharNo,
        u32 seconds = 0x1C20 (2 h) }

0x988A NC_GUILD_ACADEMY_MEMBER_CHAT_BAN_CANCEL_REQ { Name5 target }                     @ FUN_00418720 ("fc_…CHAT_BAN_CANCEL_REQ")
    err(code) = 0x988B NC_GUILD_ACADEMY_MEMBER_CHAT_BAN_CANCEL_ACK { code }           @ FUN_00443290
    prison → 0x31AD; not a guild member → 0x31AA; guild missing → 0x31AC (log); grade > 3 → 0x31A9
    index < 0 → 0x31AB; ≥ 100 → 0x31B0 (log "…OVER_MAX_MEMBER"); target offline → 0x31AF; not banned → 0x31AE
    Send CharDB 0x988D NC_GUILD_ACADEMY_MEMBER_DB_CHAT_BAN_CANCEL_REQ { u32 guildNo, u32 myCharNo, u32 targetCharNo }

0x9824 NC_GUILD_ACADEMY_NOTIFY_REQ { u16 len; char text[] }                            @ FUN_004163a0 → FUN_004483e0
    prison → 0x9825 { 0x0D14 } (the guild code); otherwise (FUN_004483e0): needs a guild member with grade ≤ 2 (else
    0x9825 error), then CharDB 0x9827 NC_GUILD_ACADEMY_DB_NOTIFY_REQ (FUN_00442090; same unbounded strcpy as W03-B3)

0x9829 NC_GUILD_ACADEMY_MEMBER_GUILD_INVITE_REQ { Name5 target }                       @ FUN_0041e930 ("fc_…MEMBER_GUILD_INVITE_REQ")
    reply = SendRaw(s, 0x982A NC_GUILD_ACADEMY_MEMBER_GUILD_INVITE_ACK { Name5 target, u16 code }) (also on success)
    prison → 0x17C0; not a guild member → 0x17C1; guild missing → 0x17C2; my guild at war / attacked → 0x17C3 (log)
    tournament fighting → 0x17CA, entered → 0x17CB; dismissing → 0x17CC; target not in the academy (index ≥ 0x65)
    → 0x17C7; target offline → 0x17C8
    code = Members_InviteAcademyMember(M, s, t) (FUN_0044b300, returns 0x17C1…0x17C9 / 0 on success):
        my grade ≤ 1, t not in a guild, t is an academy member of my guild, guild not full;
        SendRaw(t, 0x982B NC_GUILD_ACADEMY_MEMBER_GUILD_JOIN_REQ { Name4 guild name, Name5 my name })
    # no pending invitation is stored (unlike 0x7409)

0x982C NC_GUILD_ACADEMY_MEMBER_GUILD_JOIN_ACK { Name4 GuildName, Name5 …, u8 JoinAck @+0x24 }   @ FUN_00416420
    JoinAck == 0 → nothing
    err(code) = SendRaw(s, 0x982D NC_GUILD_ACADEMY_MEMBER_GUILD_JOIN_ERR { Name4, u16 code })   @ FUN_0044c3b0
    s not an academy member → 0x17D0; guild unknown → 0x17D1; guild != s.academyGuildNo → 0x17D0
    tournament → 0x17D5 / 0x17D6; dismissing → 0x17D7; guild full → 0x17D2
    CharDB 0x982F { … } (§2.5 layout)                                                @ FUN_0044c2d0
    # there is no check that an invitation (0x982B) was sent: any academy member can promote itself into its guild
    # (original bug) W03-B21

0x9859 NC_GUILD_ACADEMY_SET_MASTER_REQ { Name5 sName }                                 @ FUN_004165a0
    err(code) = SendRaw(s, 0x985A NC_GUILD_ACADEMY_SET_MASTER_ACK { code })          @ FUN_00442230
    not a guild member → 0x17F2; guild missing → 0x17F3; not in M → 0x17F2
    if s is the academy master: target = member by name; index > 100 (or not found) → 0x17F5 (the member table holds 400: members
        at index > 100 can never be appointed, original bug W03-B22); target grade ≥ 4 → 0x17F4; target offline → 0x17F6
    elif s is the guild master (grade 0) and names itself: target = s (take the role back)
    else → 0x17F4
    SendRaw(CharDB, 0x985C NC_GUILD_ACADEMY_DB_SET_MASTER_REQ { u16 hWMChar, u32 guildNo, u32 targetCharNo,
        Name5 targetName })                                                        @ FUN_0044c410 (0x17F1 if it failed)

0x9868 NC_GUILD_ACADEMY_CHAT_REQ { u8 itemLinkDataCount; u8 len; … }                    @ FUN_00416f70
    prison → 0x986A { 0x0D2E }; no owner guild → 0x17F9; guild missing → 0x17FA
    academy member chat-banned (s.+0x1DF98 > now) → 0x17FC
    0x9869 NC_GUILD_ACADEMY_CHAT_CMD (same layout as 0x7474) to the guild members (FUN_00440770) and to the academy
        members (FUN_00447850)

0x988F NC_GUILD_ACADEMY_HISTORY_LIST_REQ (no payload)                                  @ FUN_00418b20
    flood guard s.+0x1ED9C (1 s, log on violation); prison → 0x9890 { 0x318C }; no guild/academy → 0x318A
    guild missing → 0x318B; else CharDB 0x9891 NC_GUILD_ACADEMY_HISTORY_DB_LIST_REQ (FUN_00448f00 → FUN_00443700)
    answer 0x9892 → 0x9890 relay exactly like §3.10 (FUN_0040e200 → FUN_0044c560)
```

Rewards set by the academy master (all require: not in prison, a guild, member of it, `Academy_IsMaster`; the error
of the last check is 0x17FF):

| Request | Handler | Errors (prison / no guild / guild missing / not member / send) | To CharDB |
|---|---|---|---|
| 0x9831 NC_GUILD_ACADEMY_GET_REWARD_MONEY_REQ | FUN_004167a0 | 0x1881 / 0x1882 / 0x1883 / – / 0x1885 (reply 0x9832) | 0x9833 { hWMChar, guildNo } (any member or academy member may ask) |
| 0x9835 NC_GUILD_ACADEMY_GET_REWARD_ITEM_REQ | FUN_00416880 | 0x1889 / 0x188A / 0x188B / – / 0x188D (0x9836) | 0x9837 |
| 0x9839 NC_GUILD_ACADEMY_SET_REWARD_MONEY_REQ { u8 n, GUILD_ACADEMY_REWARD_MONEY[n] {u8 nLevel, u64 nCen} } | FUN_00416960 | 0x18C1 / 0x18C2 / 0x18C3 / 0x18C4 / 0x18C5 (0x983A) | 0x983B { hWMChar, guildNo, u8 count, rows } — each row is expanded to every level of its 5-level band (10–15, 16–20 … 56–60) *(inferred from the band table)*; more than 0x33 rows → log "…OVER MAX PACKET SIZE" and nothing sent (FUN_004422e0) |
| 0x983D NC_GUILD_ACADEMY_SET_REWARD_ITEM_REQ { u8 n, GUILD_ACADEMY_REWARD_ITEM[n] (0x10) } | FUN_00416aa0 | 0x1909 / 0x190A / 0x190B / 0x190C / 0x190D (0x983E) | 0x983F (FUN_004425a0, same band expansion and size check) |
| 0x9841 NC_GUILD_ACADEMY_CLEAR_REWARD_MONEY_REQ | FUN_00416be0 | 0x1951 / 0x1952 / 0x1953 / 0x1954 / 0x1955 (0x9842) | 0x9843 |
| 0x9845 NC_GUILD_ACADEMY_CLEAR_REWARD_ITEM_REQ | FUN_00416d10 | 0x1999 / 0x199A / 0x199B / 0x199C / 0x199D (0x9846) | 0x9847 |
| 0x9849 NC_GUILD_ACADEMY_GET_GRADUATE_REQ { Name4 guild } | FUN_00416e40 | 0x19A9 / – / 0x19AA (guild unknown) / – / 0x19AB (0x984A) | 0x984B (FUN_00442b20) |
| 0x984D NC_GUILD_ACADEMY_GET_RANKING_LIST_REQ { u32 x } | FUN_00416ee0 | prison → 0x984E { 0x19B1 }; x == 0 → 0x984E { 0x19B3, list = 1 } (no DB call) | 0x984F (FUN_00442b90) |

The "set" requests with n == 0 are accepted silently (return without reply). 0x9832 / 0x9836 / 0x983A / 0x983E /
0x9842 / 0x9846 / 0x984A / 0x984E carry the DB result back (§6.3).

Client (texts per code, from the C01 handlers):
- 0x9812 (`GuildAcademyJoinReqTask::On_Recv_…_MEMBER_JOIN_ACK` FUN_006f2190): **0x1788** "You have joined a Guild
  Academy"; 0x31B8 "You can join after %d min because you have been exiled…"; 0x1789/0x178A "You have already joined
  the guild."; 0x178B "%s Guild cannot be found"; 0x178C/0x178E "Unable to join %s Guild Academy. The guild have r…";
  0x178D "Guild Academy enrollment DB error has occurred"; 0x1781/0x1782 no text.
- 0x981C (`GuildAcademyLeaveTask` FUN_006f24b0): 0x1780 "You have left the Guild Academy"; 0x17A0 "You are not part of
  any Guild Academy"; 0x17A1 "There isn't any data available for joined Guild Academy"; 0x17A2/0x1794 "A DB error has
  occurred while leaving a guild"; 0x17A3 "Request cannot be processed at a current location"; 0x17A4 "In order to
  leave or exile from a Guild Academy, you must be a member for more than %d hours."
- 0x9817 (`GuildAcademyMemberVanishTask` FUN_006f73e0): 0x1780 "%s has been banned from the Academy"; 0x31B9 "You can't
  exile this member from academy yet."; 0x1799 "You are currently not registered in any guild."; 0x179A "The target is
  not an Academy Member"; 0x179B "You do not have authority to ban members from the Academy"; 0x179C "You may not ban
  yourself from the Academy"; 0x179D/0x179E "Failed to report. (DB Error)"; 0x179F "Request cannot be processed at a
  current location"; 0x1798 an untranslated Korean text.
- 0x9820 (`GuildAcademyTask::On_Recv_…_MASTER_TELEPORT_ACK` FUN_006f5cc0): 0x17A8/0x17A9 "Request cannot be processed at
  a current location"; 0x17AB "The target is not an Academy Member"; 0x17AD "Your target is currently offline"; 0x17AE
  "Only available to Academy Master"; 0x3E00 (zone) "Unable to Travel to Academy Member due Level Restriction…".
- 0x988B (`GuildAcademyMemberTask::On_Recv_…_CHAT_BAN_CANCEL_ACK` FUN_006f32d0): 0x31A9 "Rating doesn't allow
  restriction authority"; 0x31AA "Please join a guild or an academy in order to continue"; 0x31AB "The target is not an
  Academy Member"; 0x31AC/0x31AE/0x31AF "Cannot find the target."; 0x31AD "Request cannot be processed at a current
  location".
- 0x9822 (FUN_006f30a0, codes 0x17B1–0x17B7) and 0x9832 (FUN_006f55d0, 0x1881–0x1885): all codes fall to one default
  path without a code-specific text.
- 0x985A (`GuildAcademyMasterAppointTask::OnProcessNetMsg` FUN_006f28c0): 0x17FF "Not a Guild Academy Master";
  0x17F0–0x17F6 go to the default path (no code text here). C01 lists FUN_00404a00 for 0x985A, but that function is
  `TextData3::Get` (a callee), not the handler.
- 0x9890 (`GuildAcademyTask::On_Recv_…_HISTORY_LIST_ACK` FUN_006f6550): success code 0x3188 (the WM relays the DB
  code), 0x318A/0x318B/0x318C error texts.
- C01 lists 0x980A / 0x982A / 0x982B / 0x982D, and also 0x742A, 0x982E and 0x985E, as having no 2016 client handler:
  the WM does send them (0x980A only for errors, see W03-B20) and the 2016 client ignores them.

## 6. Guild academy: Character DB answers, zone messages and timers

### 6.1 Start-up (states 0x11–0x18 of §9.1)

```pseudo
CharDB 0x9802 NC_GUILD_ACADEMY_START_DB_ALL_ACK { u16 Error (0x1780 = ok), u8 PartMask, u16 n, GUILD_ACADEMY_DB[n] }
                                                                                   @ FUN_0040cc90 → FUN_004417f0
    each row: entry(nNo).GUILD_ACADEMY_CLIENT ← { master no/name, max members, money, point, ranking, buff end,
        notice date/text, intro, graduate count } *(field copy per pdb2017 GUILD_ACADEMY_DB; not traced byte by byte)*
    last chunk → (FUN_0040cc90) G.+0x0C academyLoaded = 1, CharDB link state 0x13
    error → log "FAILED - CGuildManager::Recv_NC_GUILD_ACADEMY_START_DB_ALL_ACK"
CharDB 0x9804 NC_GUILD_ACADEMY_START_DB_GET_RANKING_LIST_ACK (ok 0x18B8)            @ FUN_0040ccc0 → FUN_00441aa0
    fills the per-guild academy point / rank (GUILD_ACADEMY_START_RANKING_DATA rows), then link state 0x17
CharDB 0x9806 NC_GUILD_ACADEMY_START_DB_RANK_BALANCE_ACK { u16 Error (ok 0x18C8), … }   @ FUN_0040ccf0 → FUN_00441cb0
    every guild: lastRank(+0x76C) = nAcademyRank; nAcademyRank = 1; nAcademyPoint = 0
    G.nextRankBalance(+0x14) += 7 days; G.+0x10 = 1
CharDB 0x9810 NC_GUILD_ACADEMY_DB_MEMBER_ACK { u32 guildNo, u16 Error (0x1780), u8 PartMask, u16 n, GUILD_ACADEMY_MEMEBER_INFO[n] (0x9D) }
                                                                                   @ FUN_0040cd90 → FUN_0044be60
    like 0x7455 for table A (≤ 100 rows, FUN_00441050 per row); last chunk: nNumAcademyMembers = A.count,
    A.loadState = 2, AcademyMembers_OnLoaded (FUN_0044b500: queued handles get 0x980E, members marked online)
```

`Academies_RequestAllMembers` FUN_00441a50 sends 0x980F for every guild at start-up.

### 6.2 Membership answers

```pseudo
CharDB 0x9815 NC_GUILD_ACADEMY_DB_MEMBER_JOIN_ACK { u16 hWMChar, u32 guildNo, u32 charNo, …, u16 Error @+0x10 }
                                                                                   @ FUN_0040ce50 → FUN_0044bc30
    guild unknown → 0x9812 { Name4 read from address 0x10, 0x178B }: the WM reads through a NULL guild pointer and
        crashes (original bug) W03-B23
    Error != 0x1780 → s ← 0x9812 { guild name, Error }
    AcademyMembers_AddSession(A, s, row) (FUN_0044b6c0): fails → 0x9812 { 0x178E }
    s ← 0x9812 { name, 0x1788 } (the success code of this reply)
    0x9813 NC_GUILD_ACADEMY_MEMBER_JOIN_CMD { GUILD_ACADEMY_MEMBER_CLIENT } to the academy (FUN_00447420) and the guild (FUN_00440560)
    s.academyGuildNo = guildNo; s.academyEntry = g; s.academyInfoPending = 1; s.isAcademyMember = 1
    Client_SendAcademyInfo(s) + 0x9863 member map to academy and guild (FUN_004357a0)
    Zones_Broadcast 0x9876 NC_GUILD_ACADEMY_ZONE_MEMBER_JOIN_CMD { u32 guildNo, u32 charNo }   @ FUN_00441d70
    nNumAcademyMembers = A.count

CharDB 0x981A NC_GUILD_ACADEMY_DB_MEMBER_VANISH_ACK { u16 hWMChar, Name5 name, u32 guildNo, u32 charNo, u16 Error }
                                                                                   @ FUN_0040cea0 → FUN_0044c020
    Error != 0x1780 → s ← 0x9817 { name, Error }; guild missing → 0x1798; member missing → 0x179A
    AcademyMembers_RemoveAt (FUN_00447030) fails → 0x1798
    s ← 0x9817 { name, 0x1780 }
    0x9818 NC_GUILD_ACADEMY_MEMBER_VANISH_CMD { Name5 } to the academy (FUN_004474d0) and the guild (FUN_00440610)
    Zones_Broadcast 0x9877 NC_GUILD_ACADEMY_ZONE_MEMBER_LEAVE_CMD { u32 charNo }      @ FUN_00441e20
    nNumAcademyMembers = A.count; the kicked player (if online) also gets 0x9818
    # the kicked session's academy fields are not cleared here (FUN_00447030 removes the row only) *(read in the code;
    # the leave path FUN_00446f20 does clear them)*

CharDB 0x981E NC_GUILD_ACADEMY_DB_MEMBER_LEAVE_ACK { u16 hWMChar, u32 guildNo, u32 charNo, u16 Error }
                                                                                   @ FUN_0040cef0 → FUN_00448220
    Error != 0x1780 → s ← 0x981C { Error }; member missing → 0x981C { 0x17A0 }; guild missing → 0x981C { 0x17A1 }
    AcademyMembers_RemoveSession(A, s) (FUN_00446f20: removes, clears s.academyGuildNo / entry / isAcademyMember)
    s ← 0x981C { 0x1780 }; 0x9860 NC_GUILD_ACADEMY_MEMBER_LEAVE_CMD { Name5 } to the guild and the academy;
    Zones_Broadcast 0x9877 { charNo }; nNumAcademyMembers = A.count

CharDB 0x9830 NC_GUILD_ACADEMY_DB_MEMBER_GUILD_JOIN_ACK { u16 hWMChar, u32 nNo, Name5 sInviteCharID @+6,
    u32 nTargetCharNo @+0x1A, u8 nGrade, u16 Error @+0x1F } (pdb2017 layout, offsets match the code)
                                                                                   @ FUN_0040cf40 → FUN_0044f660
    Error != 0x1780 → s ← 0x982D { guild name, Error }
    Members_AddSession(g.M, s) and AcademyMembers_RemoveSession(g.A, s) (both must succeed, else silence; if the first
        succeeds and the second fails the player stays in both tables and gets no reply, original bug W03-B29)
    0x982E NC_GUILD_ACADEMY_MEMBER_GUILD_JOIN_CMD { Name5 sInviteSourceCharID (= ack +6), GUILD_MEMBER_CLIENT Member }
        (0x82 bytes, pdb2017 agrees) to the guild members (FUN_00440B40) and the academy members (FUN_00447cc0)
        # client-bound only (answers the C01 question); the 2016 client has no handler for 0x982E and ignores it
    s.guildNo = guildNo; s.guildEntry = g; s.guildInfoPending = 1; Client_RefreshGuildState(s)
    Zones_Broadcast 0x9879 NC_GUILD_ACADEMY_ZONE_MEMBER_GUILD_JOIN_CMD { u32 guildNo, u32 charNo }   @ FUN_00442180
    nNumAcademyMembers = A.count; nNumMembers = M.count
    # no 0x7436 / 0x744A as in a normal join: zones learn it from 0x9879

CharDB 0x985D NC_GUILD_ACADEMY_DB_SET_MASTER_ACK { u16 Error (0x17F0 ok), u16 hWMChar, u32 nCharNo @+4, Name5 name @+8, u32 guildNo @+0x1C }
                                                                                   @ FUN_0040cd40 → FUN_00448700
    ok: requester ← 0x985A { 0x17F0 }; sAcademyMasterName = name; 0x985B NC_GUILD_ACADEMY_SET_MASTER_CMD { Name5 } to
        the guild (FUN_004409e0) and the academy (FUN_00447b60);  else requester ← 0x985A { Error }
CharDB 0x9880 NC_GUILD_ACADEMY_DB_SET_MASTER_BY_LEAVE_ACK { u16 Error (0x1780), u32 guildNo, Name5 old @+0xA, …, Name5 new @+0x22 }
                                                                                   @ FUN_0040d2f0 → FUN_00448c50
    sAcademyMasterName = new; 0x9881 NC_GUILD_ACADEMY_SET_MASTER_BY_LEAVE_CMD { Name5 old, Name5 new } to guild and academy
CharDB 0x9852 NC_GUILD_ACADEMY_DB_GRADUATE_JOIN_ACK { …, u32 guildNo }                  @ FUN_0040d2a0
    entry.nGraduateCount(+0x768)++ (no message; the graduate stays an academy member until it leaves)
```

### 6.3 Notice, chat ban, rewards, ranking (DB answers relayed to the requester)

```pseudo
CharDB 0x9828 NC_GUILD_ACADEMY_DB_NOTIFY_ACK                                        @ FUN_0040cd20 → FUN_004484d0
    ok: store the notice in GUILD_ACADEMY_CLIENT (vtbl), requester ← 0x9825 NC_GUILD_ACADEMY_NOTIFY_ACK, 0x9826
        NC_GUILD_ACADEMY_NOTIFY_CMD to the academy (FUN_00447ab0) and the guild (FUN_00440930)
    requester gone → log "DEBUG - CParserCharDB::Recv_NC_GUILD_ACADEMY_DB_NOTIFY_ACK : Cannot Find Client Session After Changing…"
CharDB 0x9888 NC_GUILD_ACADEMY_MEMBER_DB_CHAT_BAN_ACK { u32 guildNo, u32 requester, u32 target, u32 seconds, u16 Error }
                                                                                   @ FUN_0040f540
    requester (by charNo) must be online, else nothing: the ban is stored by the DB but the target's session is not
    updated, so the ban has no effect until relog (original bug) W03-B27
    Error != 0x17B0 → requester ← 0x9822 { Error }; checks as in §5 → 0x17B2 / 0x17B4 / 0x17B1 / 0x17B3 / 0x17B7
    target.+0x1DF98 (chatBanUntil) = now + seconds; A.server[i].tChatBan_RestTime = seconds
    0x9823 NC_GUILD_ACADEMY_MEMBER_CHAT_BAN_CMD to the guild (FUN_0044b250) and the academy (FUN_00447a00)
    # no ACK with 0x17B0 to the requester; it learns from 0x9823
CharDB 0x988E NC_GUILD_ACADEMY_MEMBER_DB_CHAT_BAN_CANCEL_ACK                         @ FUN_0040f740 ("fc_…CHAT_BAN_CANCEL_ACK")
    same shape: clears target.+0x1DF98, 0x988B ACK to the requester and 0x988C NC_GUILD_ACADEMY_MEMBER_CHAT_BAN_CANCEL_CMD
    to guild and academy (FUN_00443340 / FUN_00443460)
Chat-ban persistence: 0x9889 NC_GUILD_ACADEMY_MEMBER_DB_SAVE_CHAT_BAN_TIME_CMD is sent by FUN_00440d00 when an academy
    member goes offline (§4.4) with the remaining seconds.

CharDB 0x9834 / 0x9838 GET_REWARD_MONEY / ITEM ACK  → FUN_00448840 / FUN_00448a30: relay rows to the requester as
    0x9832 { Error 0x1880 …, u8 n, rows } / 0x9836 { …, rows (0x10) }; packet > 0x2000 → log "…OVER MAX PACKET SIZE"
CharDB 0x983C / 0x9840 / 0x9844 / 0x9848 SET / CLEAR … ACK → FUN_004428c0 / 442900 / 442940 / 442980: requester ←
    0x983A / 0x983E / 0x9842 / 0x9846 { Error } (pure relay)
CharDB 0x984C NC_GUILD_ACADEMY_DB_GET_GRADUATE_ACK                                  @ FUN_0040d170 → FUN_0044de80
    error → log "…ERR_GUILD_ACADEMY_GET_GRADUATE_DB_ERR" and 0x984A { 0x19AA }; else 0x984A { …, GUILD_ACADEMY_GRADUATE_CLIENT[n] (0x67) }
CharDB 0x9850 NC_GUILD_ACADEMY_DB_GET_RANKING_LIST_ACK                              @ FUN_0040d1c0 → FUN_0044d9c0
    → 0x984E NC_GUILD_ACADEMY_GET_RANKING_LIST_ACK (FUN_0044d730: rows 0x2C, success 0x19B0)
CharDB 0x9882 NC_GUILD_ACADEMY_DB_REWARD_WANT_CMD { u32 charNo, u32 guildNo, u32 money lo/hi?, u16 item, u32 … }
                                                                                   @ FUN_0040d330 → FUN_00442ed0
    something wanted (money ≠ 0 or item ≠ 0xFFFF): 0x9883 NC_GUILD_ACADEMY_REWARD_WANT_CMD (0xE bytes) to the academy
    master (looked up by name) and to the member (by charNo)
```

### 6.4 Academy points, level-up and the weekly balance

```pseudo
CharDB 0x9855 NC_GUILD_ACADEMY_DB_LEVEL_UP_ACK { u16 Error (0x1890), u16 hWMChar, u32 guildNo, u32 Point, u32 BuffMin }
                                                                                   @ FUN_0040d250 → FUN_00442cd0
    (log name "…Recv_NC_GUILD_ACADEMY_DB_LEVEL_UP_CMD")
    nAcademyPoint += Point; buffEnd = max(buffEnd, now) + BuffMin·60
    Academies_Rank (FUN_00442ca0 qsort): sort all guilds by nAcademyPoint descending, dense rank 1, 2, … → nAcademyRank
    # triggered by the zone level-up hook (§4.7, 0x9854 with GuildAcademyLevelUp.shn Point/BuffTime)

ProcessGuildAcademy(G) (FUN_00441200, once a minute):
    if now ≥ G.nextRankBalance(+0x14): CharDB 0x9857 NC_GUILD_ACADEMY_DB_RANK_BALANCE_REQ (1 byte)
        # repeated every minute until 0x9858 moves the deadline
    Zones_Broadcast 0x987A NC_GUILD_ACADEMY_ZONE_GUILD_BUFF_CMD { char buff[32] = GuildAcademy.shn BuffName
        ("StaAcaGenalBuf"), u32 n, u32 guildNo[n] }: every guild whose buffEnd ≥ now (chunked at 0x1D4C bytes)
    Zones_Broadcast 0x987B NC_GUILD_ACADEMY_ZONE_GUILD_ACADEMY_MASTER_BUFF_CMD { u32 n, { char buff[32], u32 charNo }[n] }:
        per guild, the GuildAcademyRank.shn row whose [rankFrom, rankTo] holds lastRank(+0x76C), for the academy master
        when it is online (e.g. ranks 1 → "StaAcaMsBuf10PMain", 2–3 → "StaAcaMsBuf7PMain")
CharDB 0x9858 NC_GUILD_ACADEMY_DB_RANK_BALANCE_ACK { u16 Error (0x18B0) }            @ FUN_0040d210 → FUN_00442bf0
    every guild: lastRank = nAcademyRank; nAcademyPoint = 0; nAcademyRank = 1; nextRankBalance += 7 days
    else log "ERROR - CGuildManager::Recv_NC_GUILD_ACADEMY_DB_RANK_BALANCE_ACK : Error(%d))"
```

Zones apply both buffs to the characters (Z-item). GuildAcademyRank.shn also has a Fame column that the WM does not
read *(DB side, D-item)*.

## 7. Guild manager tick (`GuildManager_Tick` FUN_0044fd60, called from the W01 main loop FUN_00406760)

```pseudo
GuildManager_Tick(G):
    Guilds_DismissTick(G)          @ FUN_00449d20   once an hour (next full hour, DAT_006d4c8c)
        every guild with nDismissStatus == 1 and dDismissDate ≤ now:
            SendRaw(CharDB, 0x745A NC_GUILD_DB_DELETE_REQ { u32 nNo, Name4 sName })     # answer 0x745B (§9.2)
            # sent again every hour until the DB deletes the guild
    Guilds_WarTick(G)              @ FUN_0044ce00   every second (§3.3)
    Tournament_Tick(G)             @ FUN_00445fe0   every minute (§8.4)
    ProcessGuildAcademy(G)         @ FUN_00441200   every minute (§6.4)
    Emblem_Tick(G)                 @ FUN_0044ea00   every 5 minutes:
        state 1 (OFF_LIMIT_MEMBER) with 0 < deleteDate ≤ now → CharDB 0x750D { nGuildNo, deleteDate, 2 (DELETED) }
        state 3 (ON_LIMIT_DATE) and Emblem_PeriodOver → state 0; Guild_BroadcastEmblemInfo (0x750A)
```

All timers use `time()` and `localtime`/`mktime` (local server time).

## 8. Guild tournament (WM side)

The tournament object `T` is `g_GuildManager + 0x2C` (DAT_006c4cec, class name not in the strings; *ours*
`GuildTournament`). The match itself runs in a zone (Z-item); the WM keeps the schedule, the 31-slot bracket, the entry
list and the per-guild `GT_COND_INFO`, and hands out rewards.

### 8.1 Data

| Offset in T | Field | Notes |
|---|---|---|
| +0x00..+0x20 | MatchTime[9] *(pdb2017 names in `PROTO_NC_GUILD_TOURNAMENT_LIST_ACK`)*: Time_Start, Time_Practic, Time_PracticEnd, Time_Match_161, Time_Match_162, Time_Match_8, Time_Match_4, Time_Match_2, Time_Match_End | from 0x7486; **T+0 (Time_Start) is also used as the tournament number nGTNo** in every request (log "nGTNo : %d" prints it); the DB's own nGTNo field of 0x7486 is ignored |
| +0x24 | nLastWinnerGuildNo | from 0x7486 |
| +0x2E + k·0x15, k = 0..30 | bracket `GUILD_TOURNAMENT_LIST` *(pdb2017)* { u8 nResult, u32 nGuildNo, Name4 sGuildName } | slots 0–15 round of 16, 16–23 quarter-finals, 24–27 semi-finals, 28–29 final, 30 champion; pairs (k, k+1) fight |
| +0x2C0 | phase (`nMatchType`) | 0 not started, 1 entry, 2 practice, 3 practice end, 4 first half of the 16, 5 second half, 6 eight, 7 four, 8 final, 9 ended; 0xB = not loaded / DB error |
| +0x2BC | previous phase | |
| +0x2C8 / +0x2CC / +0x2D0 | entry list count / head / tail | nodes 0x1C { `GT_EnterList` (nGuildNo, bIsChoice, bIsRefundNotice, u64 nRefundMoney), next } (`Tournament_AddEntry` FUN_0045b1a0) |
| +0x2D4 / +0x314 | GuildTournament.shn table / active row (first row with byte0 == 1) | +9 explore min, +0xB wait sec, +0xD play min (used by 0x7481) |
| +0x318 / +0x358 | GuildTournamentReward.shn / first row | rank-indexed rewards (§8.5) |
| +0x35C / +0x39C | GuildTournamentRequire.shn / first row | +0 nMinLevel, +1 u16 nMinMember, +3 u64 nProposalMoney |
| +0x3A4 | loaded | 1 after a good 0x7486 |
| G+0x08 | u16 nGuildTournamentJoinCnt | from 0x7486, +1 per successful entry; scales the 0x74E9 flood guard |

nResult per slot: 0 waiting, 1 won, 2 lost, 4 fighting. `Tournament_IsFighting(guildNo)` FUN_0043d2f0 (`FUN_0043e170`):
the guild sits in a slot of the current round (phase 4: slots 0–7, 5: 8–15, 6: 16–23, 7: 24–27, 8: 28–29) with
nResult 4. `Tournament_IsEntered(guildNo)` FUN_0043d400 (`FUN_0043e180`): phases 2–5 any of slots 0–15, 6: 16–23,
7: 24–27, 8: 28–29, with nResult 0, 1 or 4 (still in the running).

### 8.2 Client requests

```pseudo
0x747A NC_GUILD_TOURNAMENT_JOIN_REQ { u32 nGuildNo }                                @ FUN_00415340 → FUN_00446100
    reply(no, code) = SendRaw(s, 0x747B NC_GUILD_TOURNAMENT_JOIN_ACK { u32 nGuildNo, u16 nTeamPosition (uninitialised, original bug W03-B24),
                                                                        u16 nError })   @ FUN_0043f6e0
    s.guildNo == 0 or its guild missing → 0x0D47;  not the master → 0x0D48
    T.phase != 1 (FUN_0045aed0) → 0x0D43
    the guild named by p.nGuildNo does not exist → 0x0D47;  own guild dismissing → 0x0D4A
    Zones_Broadcast 0x74E3 NC_GUILD_TOURNAMENT_ZONE_JOIN_NEW_REQ { u16 hWMChar, u32 nCharNo, u32 nGTNo = T+0,
        u32 nGuildNo = s.guildNo, u8 nMinLevel, u16 nMinMember, u64 nProposalMoney (Require row; the upper 4 bytes 0) }
        # to every zone; the zone holding the character checks level / members / money and answers 0x74E4
    # p.nGuildNo is only checked for existence; the entry is made for the requester's own guild

Zone 0x74E4 NC_GUILD_TOURNAMENT_ZONE_JOIN_NEW_ACK { u16 Error, u16 hWMChar, u32 nCharNo, u32 nGTNo, u32 nGuildNo,
    u8 nMinLevel, u16 nMinMember, u64 nProposalMoney }                              @ FUN_0042b080 → FUN_0043ff40
    Error == 0x1C40 → G.joinCount++
    session / charNo / guildNo mismatch → log "…JOIN_NEW_ACK - 2…"; guild missing → "- 3"
    Error == 0x1C40 → Tournament_AddEntry { nGuildNo, 0, 0, nProposalMoney }
    s ← 0x747B { nGuildNo, ?, Error }
    # the entry is kept in memory only; the DB learns it from the zone (0x7489 / DB_JOIN_NEW, Z-item)

0x747E NC_GUILD_TOURNAMENT_LIST_REQ (no payload)                                    @ FUN_00415380 → FUN_00449c50
    SendRaw(s, 0x747F NC_GUILD_TOURNAMENT_LIST_ACK, 0x3F8-byte body: { u16 nError = T.loaded ? 0x0D40 : 0x0D41,
        MatchTime[9] + 9 tm, u8 nMatchType = phase, GUILD_TOURNAMENT_LIST[31] })    @ FUN_0043d6b0
        # long-header form (byte 0, then u16 length)

0x74E9 NC_GUILD_TOURNAMENT_JOIN_LIST_REQ (no payload)                               @ FUN_004153b0 → FUN_00446b30
    now outside [Time_Start, Time_Practic] → 0x74EA { Error 0x1C4A, PartMask 3, 0, 0 }   @ FUN_004400c0
    flood guard: clamp(joinCount/100, 30, 60) s since s.+0x1E284 → 0x1C4B
    else SendRaw(CharDB, 0x74EB NC_GUILD_TOURNAMENT_DB_JOIN_LIST_REQ { u16 hWMChar, u32 nGTNo })   @ FUN_00440180

CharDB 0x74EC NC_GUILD_TOURNAMENT_DB_JOIN_LIST_ACK { u16 Error, u8 PartMask, u16 hWMChar, u32 nGTNo, u16 n,
    rows (0x2E, only u32 guildNo used) }                                            @ FUN_0040c010
    rows → SHINE_GUILD_LIST_NEW { guild nNo, sName, master name ("Unknown"), nType, nGrade, nNumMembers, nMaxMembers }
    s ← 0x74EA NC_GUILD_TOURNAMENT_JOIN_LIST_ACK { Error, PartMask, nGTNo, u16 nJoinGuildNum = n (DB count),
        rows found }
    # unknown guilds are skipped but nJoinGuildNum keeps the DB count (original bug) W03-B18;
    # "Packet Size Over" (> 0x1FFB) is only logged, the copy continues past the 0x2000 buffer (original bug) W03-B19
```

Client: 0x747B → `GuildTask` FUN_006b3ee0 (codes 0x1C40–0x1C47 shown; 0x0D43/0x0D47/0x0D48/0x0D4A are not in its
switch → nothing shown); 0x747F → FUN_006b3080; 0x74EA → FUN_006b39e0 (0x1C48 / 0x1C4B handled; 0x1C4A
"Guild tournament application period is currently closed." via the generic table).

### 8.3 Zone requests

```pseudo
Zone 0x74C6 NC_GUILD_TOURNAMENT_ZONE_MEMBERGRADE_REQ { u8 nTournamentSeed, u32 nGuildNo }   @ FUN_0042af80 → FUN_004469f0
    nGuildNo 0 or unknown → z ← 0x74C7 { Error 0x1B59, seed 0, guild 0, n 0 }
    not Tournament_IsFighting → 0x1B5A
    z ← 0x74C7 NC_GUILD_TOURNAMENT_ZONE_MEMBERGRADE_ACK { u16 Error = 7000 (0x1B58), u8 seed, u32 nGuildNo,
        u16 n = min(count, 400), {u32 charNo, u8 grade}[n] }                       @ FUN_0043fa20

Zone 0x74C8 NC_GUILD_TOURNAMENT_ZONE_FIGHTER_ENTER_CMD { u8 seed, u32 nGuildNo, u32 nCharNo }   @ FUN_0042afc0 → FUN_0043fb60
    guild valid, fighting, member online → that session's +0x1E280 (inArena) = 1; else log
    "FAILED - CGuildManager::Recv_NC_GUILD_TOURNAMENT_ZONE_FIGHTER_ENTER_CMD 1..5"
Zone 0x74C9 NC_GUILD_TOURNAMENT_ZONE_FIGHTER_OUT_CMD { same }                        @ FUN_0042b000 → FUN_0043fcf0
    session +0x1E280 = 0
    # +0x1E280 is what guild chat (§3.6) and Members_Broadcast(…,1,x) test: arena fighters only hear arena fighters

Zone 0x74D9 NC_GUILD_TOURNAMENT_ZONE_OBSERVER_ENTER_REQ { u8 nTournamentSeed, u16 nPlayerHnd }   @ FUN_0042b040 → FUN_00446aa0
    seed > 0x1D → z ← 0x74DA { 0x1B61, seed, hnd }
    seed &= ~1; if the pair is in the current round and both slots are fighting (FUN_0043d5e0) → 0x1B60 with the even seed
    else 0x1B62                                                                    @ FUN_0043fd80 (0x74DA NC_GUILD_TOURNAMENT_ZONE_OBSERVER_ENTER_ACK)

Zone 0x7482 NC_GUILD_TOURNAMENT_END_CMD { u8 seed, u16 mapNo, u8 status, u32 nWinnerGuildNo, u32 nLoseGuildNo }
                                                                                   @ FUN_0042ad10 → FUN_00446340
    see §8.5 (also called internally for walk-overs)
```

### 8.4 Schedule and phases

```pseudo
CharDB 0x7486 NC_GUILD_TOURNAMENT_DB_GET_ACK { u16 Error, u32 nGTNo, u8 nMatchType, i32 MatchTime[9],
    GUILD_TOURNAMENT_LIST_DB[31], u32 nLastWinnerGuildNo, u16 nGuildTournamentJoinCnt } @ FUN_0040eff0 ("fc_NC_GUILD_TOURNAMENT_DB_GET_ACK")
    Error == 0x0D40: copy the bracket (names from the guild list, "" if unknown); copy every slot with nResult 1 into
        its next-round slot (k → 16 + k/2 …); phase = nMatchType; MatchTime → T+0..; lastWinner; joinCount
        Tournament_Reset (FUN_0044a270): every guild's GT_COND_INFO condition/time/grade = 0, then FUN_004498e0 (logs the bracket)
        T.loaded = 1
    else T.loaded = 0; log "FAILED - fc_NC_GUILD_TOURNAMENT_DB_GET_ACK, Error=%d"
    CharDB link state = 0xF (§9.1)

CharDB 0x74F7 NC_GUILD_TOURNAMENT_ENTER_LIST_DB_GET_ACK { u16 Error, u8 PartMask, u16 n, GT_EnterList[n] }   @ FUN_0040b8c0
    Error == 0x0D50: Tournament_AddEntry for each; PartMask & 2 → entry list loaded (T+0x2C4 = 1), CharDB link state 0x11
    else log "FAILED - fc_NC_GUILD_TOURNAMENT_ENTER_LIST_DB_GET_ACK, Error=%d"

Tournament_Tick (FUN_00445fe0, once a minute from §7):
    if !T.loaded: prevPhase = phase; phase = 0xB; return
    p = Tournament_PhaseAt(T, now) (FUN_00445440):
        phase 0: Tournament_Schedule(T) (FUN_00444cf0); if it did not move the schedule → p = 0; else p = 1 when
                 now ≥ Time_Start, else 0
        phase k = 1..8: k+1 when now ≥ MatchTime[k], else k
        phase 9, 10, 0xB: **p = 0** (an ended or failed tournament goes back to phase 0, which schedules the next one)
        # with a DB error the loop is 0xB → request 0 → error → 0xB … one 0x748B per minute (original bug) W03-B28

Tournament_Schedule(T) (FUN_00444cf0) — the schedule generator (returns 1 only when it wrote a new schedule):
    row = active GuildTournament.shn row (T+0x314): +1 week of month (0 = any), +2 weekday (0 = any), +3 hour (0x19 =
        keep), +4 minute (0x3C = keep), +5 / +6 hour / minute step, u16 +7 period in minutes (0 = next month),
        u16 +0xF … +0x1B the seven phase lengths in minutes
    start = now with the row's hour / minute (rounded down to the steps), moved to the weekday and week of the month
    next  = start + period (or the same week / weekday of the next month when the period is 0)
    if start > T.Time_Start:
        MatchTime[0] = start; MatchTime[1..7] = start + cumulative phase lengths; MatchTime[8] (Match_End) = next − 2 min
        SendRaw(CharDB, 0x7499 NC_GUILD_TOURNAMENT_DB_SET_MATCH_TIME_REQ { u16 (unset), u32 nGTNo = old T+0,
            i32 MatchTime[9] })                                                    @ FUN_0043f9a0 (0x2C-byte raw packet)
        # the request carries the previous nGTNo (G+0x2C before the update); the answer 0x749A is a no-op (§9.2)
    if p != phase: SendRaw(CharDB, 0x748B NC_GUILD_TOURNAMENT_DB_SET_TYPE_REQ { u32 nGTNo, u8 p, 3 bytes uninitialised }) (original bug) W03-B25
        # PDB 2017 has nMinLevel / nMinMemberCnt there; the 2016 WM leaves them as stack bytes  @ FUN_0043f960

CharDB 0x748C NC_GUILD_TOURNAMENT_DB_SET_TYPE_ACK { u16 Error, u32 nGTNo, u8 nMatchType, … }   @ FUN_0040bda0 → FUN_0044d6b0
    nGTNo == T+0 and nMatchType != phase: prevPhase = phase; phase = (Error == 0x0D40 ? nMatchType : 0xB)
    Tournament_EnterPhase(T) (FUN_0044c900):
        0: FUN_0045b160 (clear);  1: remember the start, clear entries (FUN_0045ae80), joinCount = 0
        2: SendRaw(CharDB, 0x74E7 NC_GUILD_TOURNAMENT_DB_FINAL_SELECTION_REQ { u32 nGTNo, u8 nMinLevel, u16 nMinMember })  @ FUN_004401c0
        3: 0x7480 NC_GUILD_TOURNAMENT_TYPE_CMD { u8 phase } to the members of every bracket guild (FUN_0043f720)
        4/5/6/7/8: same, then for each pair of the round (0–7, 8–15, 16–23, 24–27, 28): clear both results and
            Tournament_StartMatch(pair) (FUN_0044ade0)
        9/10/0xB: 0x7480 to slots 0–15
    Tournament_UpdateGTCond(T) (FUN_00444b20): phase 0 / 2 → every guild condition 0 (FUN_0043e190); phase 1 → condition
        1 with Time_Practic (FUN_0043e1c0); phase 2 → bracket guilds: bIsJoin = 1, condition 2, nMatchTime =
        Time_Match_161 (slots 0–7) or Time_Match_162 (slots 8–15)

Tournament_StartMatch(T, k):                                                       @ FUN_0044ade0
    a, b = slots k, k+1 (both results already set → nothing)
    an empty slot loses (2), the other wins (1); a guild with no online member loses
    both present with online members: Zones_BroadcastRaw 0x7481 NC_GUILD_TOURNAMENT_START_CMD { u8 seed = k,
        u16 nTournamentMapNo = rand() % 3, u16 nExploerTimeMin, u16 nWaitPlayTimeSec, u16 nPlayTimeMin (GuildTournament
        row), u32 nNo1 = a, u32 nNo2 = b }; both results = 4; both guilds' condition = 3 (in progress)
    otherwise: synthetic END_CMD { seed k, map 0, status (1 when both lost or both won, else 0), winner, loser }
        → Tournament_OnEnd (§8.5)

CharDB 0x74E8 NC_GUILD_TOURNAMENT_DB_FINAL_SELECTION_ACK { u16 Error, u32 nGTNo, u8 n, u32 guildNo[n] }   @ FUN_0040c310 → FUN_00446bd0
    joinCount = 0; the first ≤ 16 guilds get a bracket name and their entry is marked chosen (bIsChoice = 1)
    Zones_Broadcast 0x74F4 NC_GUILD_TOURNAMENT_GOLD_REFUND_ZONE_CMD { u8 PartMask, u16 n, GT_EnterList[n] } for the
        entries not chosen (chunks ≤ 7999 bytes)                                    # the zones refund the entry money
    every in-game session: +0x1E288 (refundNoticePending) = 1; Client_SendRefundNotice(s) (FUN_00430e30)
    Tournament_Seed (FUN_00445100):
        srand(time); 16 random swaps of slot i with slot rand() % 16 (i = 0..15); copy slots 0–15, clear the whole
        bracket (31 slots); re-place the non-empty guilds in order into the seats {0, 14, 2, 12, 4, 10, 6, 8, 1, 15, 3,
        13, 5, 11, 7, 9} so that empty slots end up spread over the pairs (byes)
        SendRaw(CharDB, 0x7497 NC_GUILD_TOURNAMENT_DB_SET_MATCH_REQ { u16 Error (unset), u32 nGTNo, 16 × 5-byte rows
            with only the guild number written }) (0xA3-byte body)
    0x7480 { phase } to every bracket guild; Tournament_UpdateGTCond
    Clients_BroadcastInGame 0x74ED NC_GUILD_TOURNAMENT_NOTIFY_CMD { Type 1, nRanking 0, sGuildName "" }

Client_SendRefundNotice(s) (FUN_00430e30, also from map login): phase > 1 and s.+0x1E288: clear it; if s's guild
    has an unchosen entry with a refund not yet noticed: s ← 0x74F8 NC_GUILD_TOURNAMENT_REFUND_NOTICE_CMD { u64 money }
    and CharDB ← 0x74F9 NC_GUILD_TOURNAMENT_REFUND_NOTICE_DB_SET_REQ { u32 nGTNo, u32 guildNo } (entry marked noticed)

CharDB 0x748A NC_GUILD_TOURNAMENT_DB_JOIN_ACK { u16 hWMChar, u32 nGTNo, u16 nTeamPosition, u32 nGuildNo, u16 Error }
                                                                                   @ FUN_0040bd10
    Error != 0x0D40 → FUN_0045af40 (undo the slot); s ← 0x747B { nGuildNo, nTeamPosition, Error }
    # no WM sender of 0x7489 exists in 2016 (the OPTool / old join path, W04)
```

### 8.5 Match end and rewards: `Tournament_OnEnd` (FUN_00446340, log name `CGuildManager::Recv_NC_GUILD_TOURNAMENT_END_CMD`)

```pseudo
    k = seed; status 0: slot k result = 1 if it holds the winner, 2 if the loser, else log "1World Manager(…)/1Zone Server(…)"
        and 2; same for slot k+1 ("2…"); both 2 → status = 1
    status != 0: both slots 2
    SendRaw(CharDB, 0x748E NC_GUILD_TOURNAMENT_DB_SET_RESULT_REQ { u32 nGTNo, u16 position, u8 nResult, u32 nGuildNo })
        for slot k and slot k+1
    Tournament_Advance(T, result) (FUN_0045afd0): seed > 0x1D → nothing; next = 16 + seed/2 (pairs 16–23 → 24–27,
        24–27 → 28–29, 28–29 → 30); status 1 (no winner) → next slot cleared; else the slot holding the winner is copied
        to the next slot with nResult 0
    0x7490 NC_GUILD_TOURNAMENT_RESULT_CMD { u8 seed, u16 map, u8 status, u32 winner, u32 loser } to both guilds'
        members (FUN_0043f8e0); every member's inArena flag (+0x1E280) = 0
    rank by seed: 0–15 → 5, 16–23 → 4, 24–27 → 3, 28–29 → 2, 30 → 1
    status 0, final (seed 0x1C), winner: Tournament_Reward(winner, rank 1);
        Clients_BroadcastInGame 0x74ED { Type 2, nRanking 1, sGuildName = winner } ; then the loser gets rank 2
    status 0, other rounds: only the loser is rewarded (rank of the round)
    status 1: both are rewarded with the round's rank
    other status: no reward
    GT_COND_INFO of both guilds: nGTGrade = 16/8/4/2 by round, condition 4; a winner gets nGTGrade 1, nMatchTime = next
        round time (Time_Match_8 / 4 / 2), condition 2 (4 after the final)

Tournament_Reward(guildNo, rank) (FUN_0043f780):
    rows of GuildTournamentReward.shn with byte0 == rank → SendRaw(CharDB, 0x74AA NC_GUILD_TOURNAMENT_DB_REWARD_CREATE_REQ
        { u32 nGTNo, u32 OwnerGuildNum, i32 nItem = row count, ITEM_OPT[n] (0x21: RewardType = row[2], Value1..3,
        IO_Str..IO_Men) })                                                           # GT_REWARD_TYPE (pdb2017):
        # 0 item, 1 fame, 2 money, 3 exp, 4 token, 5 money divided among members

CharDB 0x74AB NC_GUILD_TOURNAMENT_DB_REWARD_CREATE_ACK { u32 nGuildNo, u32 nAddMoney, u32 nAddFame, u32 nAddExp,
    u32 nAddToken, u64 nAddMoneyDivision }                                          @ FUN_0040bef0
    unknown guild → log; else nFame += AddFame; nExp += AddExp; nMoney += AddMoney + AddMoneyDivision; nGuildToken += AddToken
    # nothing is broadcast; members see the new values at the next 0x7418 / 0x1012
```

The match itself (arena, flags, dice game, skills: opcodes 0x74CA–0x74E2, 0x74F0–0x74F3) is zone ↔ client and not
handled by the WM.

## 9. Guild: start-up load, deletion, rename / retype, storage rights

### 9.1 Start-up sequence (CharDB link state machine, `FUN_00405aa0`, guild part)

W01 runs a state machine on the CharDB link (g_WM+0xBD30) after connecting. The guild states:

| State | Action | Advanced by |
|---|---|---|
| 5 | SendRaw 0x7456 NC_GUILD_DB_ALL_REQ (1 payload byte, left uninitialised) | 0x7457 with PartMask & 2 → 7 (`FUN_0040b820`) |
| 7 | 0x7503 NC_GUILD_EMBLEM_INFO_DB_REQ | 0x7504 with PartMask == 2 → 9 |
| 9 | 0x74BC NC_GUILD_DB_TOKEN_ALL_REQ | 0x74BD with PartMask & 2 → 0xB |
| 0xB | `Guilds_RequestAllMembers` FUN_0043f4e0: 0x7454 NC_GUILD_DB_MEMBER_REQ for every guild | → 0xC |
| 0xC | wait until every guild's `M.loadState == 2` | → 0xD |
| 0xD | 0x7485 NC_GUILD_TOURNAMENT_DB_GET_REQ { u32 0 } | 0x7486 (§8.4) |
| 0xF | 0x74F6 NC_GUILD_TOURNAMENT_ENTER_LIST_DB_GET_REQ { u32 tournamentNo } | 0x74F7 (§8.4) |
| 0x11 | 0x9801 NC_GUILD_ACADEMY_START_DB_ALL_REQ | 0x9802 (§6.1) |
| 0x13 | `Academies_RequestAllMembers` FUN_00441a50: 0x980F for every guild | → 0x14 |
| 0x14 | wait until every guild's `A.loadState == 2` | → 0x15 |
| 0x15 | 0x9803 NC_GUILD_ACADEMY_START_DB_GET_RANKING_LIST_REQ { u32 1 } | 0x9804 (§6.1) |
| 0x17 | 0x9805 NC_GUILD_ACADEMY_START_DB_RANK_BALANCE_REQ | 0x9806 (§6.1) |

So all member and academy tables are loaded before clients are accepted; the lazy load in §2.11 / §5 (0x980D) is only a
fallback for guilds created later (their tables are created loaded, `loadState = 2`, in 0x7459).

```pseudo
CharDB 0x7457 NC_GUILD_DB_ALL_ACK { u16 Error, u8 PartMask, u16 NumOfGuild, GUILD_DB[n] (0x2F7) }
                                                                                   @ FUN_0040b820 → FUN_00450240
    Error != 0x0C41 → log "FAILED - CGuildManager::Recv_NC_GUILD_DB_ALL_ACK"; (ACK NULL → "…(ACK:NULL)")
    PartMask & 1 → G.guildCount = 0 (the list itself is not freed)
    for each GUILD_DB row: build a CGuildServer: GUILD_CLIENT from the row (nNo, sName, nMoney, nType, nGrade, nFame,
        nStoneLevel, nExp, dCreateDate, war dates + tm, nWarEnemy, win/lose/draw, nDismissStatus + date, sIntro,
        notice date / char / text; nNumMembers = 0xFFFF until the member table arrives, nMaxMembers = row.nMaxMembers,
        nWarStatus = 0, nWarEnemy = 0, war request/start/end dates = now, enemy name "" and grade 0), GUILD_SERVER { nNo, sPassword, dCreateDate }, empty member table
        Guilds_Add; failure → log "GUILD ADD FAILED, CGuildManager::Recv_NC_GUILD_DB_ALL_ACK, GuildNo=%d, GuildName=%s"
    PartMask & 2 → G.allGuildsLoaded = 1; CharDB link state = 7
```

Note: the war dates of the row are not used (all three are set to the load time), so a war running when the WM
restarts is forgotten (nWarEnemy is reset to 0 as well) *(the per-field copy was traced
for the fields named here; the remaining bytes follow the `GUILD_DB` → `GUILD_CLIENT` order)*. The academy block is initialised by `FUN_0045aa90`
(master name = first grade-0 member, i.e. "Unknown" until the members arrive; max 100).

### 9.2 Deletion (dismissal executed by the DB) and dismissal cancel

```pseudo
CharDB 0x745B NC_GUILD_DB_DELETE_ACK { u32 nNo, u16 Error }                        @ FUN_0040ba30 → FUN_00450d00
    g = Guilds_FindByNo(nNo); Error != 0x0C41 → nothing
    Members_Broadcast(g.M) 0x7430 NC_GUILD_DELETE_CMD { Name4 g.sName }             @ FUN_00444440
    AcademyMembers_Broadcast(g.A) 0x985F NC_GUILD_ACADEMY_DELETE_CMD { Name4 g.sName }   @ FUN_00447370
    Zones_Broadcast 0x7449 NC_GUILD_ZONE_DELETE_CMD { u32 nNo }                     @ FUN_0043ee50
    Members_ClearSessions(g.M): online members' session guildNo / guildEntry = 0; free the waiting queue  @ FUN_0043c8f0
    AcademyMembers_ClearSessions(g.A): same for academy members, but it clears their **guild** fields
        (+0x1DF7C / +0x1DF80) instead of the academy fields +0x1DF88 / +0x1DF8C (original bug) W03-B13  @ FUN_00440f50
    Guilds_Remove(G, nNo)                                                          @ FUN_004501b0
```

The deletion is requested by the hourly `Guilds_DismissTick` (§7) with 0x745A NC_GUILD_DB_DELETE_REQ once
dDismissDate has passed.

```pseudo
CharDB 0x74EF NC_GUILD_DB_DELETE_CANCEL_ACK { u16 nError, u32 nNo, u16 hTool }      @ FUN_0040bac0 → FUN_00443200
    t = Sessions_GetByHandle(g_OPTools, hTool) (else ignored); g = Guilds_FindByNo(nNo) (else ignored)
    nError == 0x1E48: g.nDismissStatus = 0; t ← 0x282C NC_OPTOOL_GUILD_DISMISS_CANCEL_ACK { 0x1E48 }
    else t ← 0x282C { nError }
```

The request side is OPTool 0x282B (W04). Members are not told that the dismissal was cancelled (no 0x742F with
status 0) (original bug) W03-B14; they keep the "scheduled for dismissal" state on screen until relog.

No-op CharDB handlers: 0x7465 NC_GUILD_DB_INTRO_ACK, 0x748F NC_GUILD_TOURNAMENT_DB_SET_RESULT_ACK, 0x7498
NC_GUILD_TOURNAMENT_DB_SET_MATCH_ACK, 0x749A NC_GUILD_TOURNAMENT_DB_SET_MATCH_TIME_ACK all go to `FUN_0040bb50`, which
calls `FUN_0045abc0` (`return 1`, CGuild vtable stub) and ignores the payload.

### 9.3 Rename (item, zone-driven)

The zone validates the item use with 0x74AF, then commits with 0x74B1. Both carry the 6-byte zone header
(`NETPACKETZONEHEADER` {u16 zone-side handle, u32 charNo}) *(pdb2017; charNo at +2 confirmed)*.

```pseudo
Zone 0x74AF NC_GUILD_WORLD_RENAME_REQ { hdr, u8 nItemSlot, Name4 sGuildName }        @ FUN_0042d6f0
    reply(code) = z ← 0x74B0 NC_GUILD_WORLD_RENAME_ACK { hdr, nItemSlot, sGuildName, u16 err=code }   @ FUN_0043f150
    character (by charNo) not online → 0x1A46;  no guild → 0x1A47;  guild not found → 0x1A48
    not grade 0 → 0x1A49;  Guild_IsAtWar → 0x1A4A;  Tournament_IsFighting or IsEntered → 0x1A4B
    new name == current name → 0x1A4C;  !Guild_IsValidName → 0x1A4E;  another guild has the name → 0x1A4D
    else 0x1A40 (allowed)

Zone 0x74B1 NC_GUILD_WORLD_RENAME_CMD { hdr, Name4 sGuildName }                      @ FUN_0042e520 ("fc_NC_GUILD_WORLD_RENAME_CMD")
    re-checks: character online, guild, grade 0, not at war, not in the tournament, name differs, name free
    (each failure only logs "ERROR - CParserZone::fc_NC_GUILD_WORLD_RENAME_CMD - …"; the name validity is not re-checked)
    SendRaw(CharDB, 0x74B2 NC_GUILD_DB_RENAME_REQ { u16 hWMChar, u32 nGuildNo, Name4 sGuildName })

CharDB 0x74B3 NC_GUILD_DB_RENAME_ACK { u16 hWMChar, u32 nGuildNo, Name4 sGuildName, u16 err }   @ FUN_00410890
    err != 0x1A40 → log "…DB Error!"; guild missing → log "…Guild Not Found!"
    g.sName = sGuildName; every tournament slot (§8.1) with this guildNo gets the new name
    Clients_BroadcastRaw (every in-game client, FUN_00437b00) 0x74AE NC_GUILD_RENAME_CMD { u32 nGuildNo, Name4 sGuildName }
```

A failure after 0x74B1 (or a DB error) is only logged: neither the zone nor the client is told, and the zone has
already used the item (original bug) W03-B15. The zones' own guild copies are not updated by the WM (no zone
broadcast of the new name) *(the zone may update from its own 0x74B1; not checked here)*. Client: 0x74AE →
`FUN_006b7650` (GuildTask); 0x74AD NC_GUILD_RENAME_ACK is sent by the zone, not by the WM.

### 9.4 Retype (guild type / combat propensity, item, zone-driven)

```pseudo
Zone 0x74B7 NC_GUILD_WORLD_RETYPE_REQ { hdr, u8 nItemSlot, u8 nType }               @ FUN_0042bdf0
    reply(code) = z ← 0x74B8 NC_GUILD_WORLD_RETYPE_ACK { hdr, nItemSlot, nType, u16 err }   @ FUN_0043f240
    not online → 0x1A5E;  no guild → 0x1A5F;  guild missing → 0x1A60;  not master → 0x1A61;  at war → 0x1A62
    tournament → 0x1A63;  nType == current → 0x1A64;  else 0x1A58 (allowed)
    # nType is not range-checked (original bug) W03-B16

Zone 0x74B9 NC_GUILD_WORLD_RETYPE_CMD { hdr, u8 nType }                              @ FUN_0042bf60 ("fc_NC_GUILD_WORLD_RETYPE_CMD")
    same re-checks, log only on failure
    SendRaw(CharDB, 0x74BA NC_GUILD_DB_RETYPE_REQ { u16 hWMChar, u32 nGuildNo, u8 nType })

CharDB 0x74BB NC_GUILD_DB_RETYPE_ACK { u16 hWMChar, u32 nGuildNo, u8 nType, u16 err }   @ FUN_0040bde0 ("fc_NC_GUILD_DB_RETYPE_ACK")
    err != 0x1A58 → log;  guild missing → log
    g.nType = nType; Members_BroadcastRaw(g.M) 0x74B6 NC_GUILD_RETYPE_CMD { u32 nGuildNo, u8 nType }   @ FUN_00444930
```

Same silent-failure pattern as the rename (W03-B15). Only guild members learn the new type; zones are not told.
`nType == 0` blocks guild wars (§3.2).

### 9.5 Storage withdraw rights (zone asks for the member grade)

```pseudo
Zone 0x749E NC_GUILD_STORAGE_WITHDRAW_GRADE_REQ { hdr }                              @ FUN_0042b0c0
    s = Clients_FindByCharNo(hdr.charNo)
    no guild → z ← 0x749F NC_GUILD_STORAGE_WITHDRAW_GRADE_ACK { hdr?, err 0x0CE9, Grade 99 }
    s missing or guild missing → 0x749F { hdr?, 0x0CE8, 99 }
    member found → z ← 0x749F { hdr, 0x0C41, Grade = member grade }               @ FUN_0043ca20
    not a member → 0x749F { hdr?, 0x0CF1, 99 }
    # the error replies (FUN_0043f340) leave the 6-byte zone header uninitialised, so the zone cannot route them
    # (original bug) W03-B17

Zone 0x9870 NC_GUILD_ACADEMY_REWARD_STORAGE_WITHDRAW_GRADE_REQ { hdr }               @ FUN_0042b960
    identical, but looks the character up in the **guild member table** of s.guildNo, replies 0x9871
    NC_GUILD_ACADEMY_REWARD_STORAGE_WITHDRAW_GRADE_ACK with success code 0x1780 (FUN_00440bf0), errors via
    FUN_00442260 (same uninitialised header, W03-B17)
```

The zone combines the grade with the GuildGradeData rights (Z-item for guild storage). 0x9886 (§2.9) pushes grade
changes for the same purpose.

## 10. Messages to the zones and the client-bound broadcasts (summary)

| Opcode | Sent to | When |
|---|---|---|
| 0x7448 NC_GUILD_ZONE_MAKE_CMD | all zones | guild created (§2.2) |
| 0x7449 NC_GUILD_ZONE_DELETE_CMD | all zones | guild deleted (§9.2) |
| 0x744A / 0x744B NC_GUILD_ZONE_MEMBER_JOIN / LEAVE_CMD | all zones | join / leave / kick (§2.5–2.7) |
| 0x7443 / 0x7444 NC_GUILD_ZONE_WAR_START / END_CMD | all zones | war timer (§3.3) |
| 0x7447, 0x7479, 0x7496 | asking zone / all zones / asking zone | guild list, war confirm, war status (§3.5) |
| 0x74C1 NC_GUILD_WORLD_USE_GUILD_TOKEN_CMD | all zones | token spent (§3.8) |
| 0x74B0 / 0x74B8 | asking zone | rename / retype validation (§9.3, §9.4) |
| 0x749F / 0x9871 | asking zone | storage withdraw grade (§9.5) |
| 0x9886 NC_GUILD_ACADEMY_REWARDSTORAGE_GRADE_INFO_CMD | the member's zone | grade change (§2.9) |
| 0x74E3, 0x7481, 0x74F4 | all zones | tournament entry, match start, refunds (§8) |
| 0x74C7, 0x74DA | asking zone | tournament member grades, observer check (§8.3) |
| 0x9876 / 0x9877 / 0x9879 / 0x9878 | all zones | academy join / leave / promoted to guild / master teleport |
| 0x987A / 0x987B | all zones | academy buffs, every minute (§6.4) |
| 0x742A NC_GUILD_WAR_SCORE_CMD | online members of both warring guilds (clients; no 2016 client handler) | every war kill (§3.4) |
| 0x982E NC_GUILD_ACADEMY_MEMBER_GUILD_JOIN_CMD | online guild members and academy members (clients; ignored by the 2016 client) | academy member promoted (§6.2) |
| 0x985E NC_GUILD_ACADEMY_DISMISS_CMD | online academy members (clients; ignored by the 2016 client) | dismissal scheduled (§2.3) |
| 0x750B NC_GUILD_EMBLEM_INFO_NOTICE_CMD, 0x74AE NC_GUILD_RENAME_CMD, 0x74ED NC_GUILD_TOURNAMENT_NOTIFY_CMD | every in-game client | emblem change, rename, tournament notices |

## 11. Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| W03-B1 | 0x7405 errors (FUN_0044a2e0, FUN_0041d380) | 0x7406 error replies leave `No` and `dCreateDate` as stack bytes | 8 garbage bytes to the client | zero them |
| W03-B2 | 0x740E / 0x741C | "Guild_CannotLeaveTime" = 0 makes every kick (0x3197) and leave (0x3190) fail; join stores 0 as the time | nobody can leave or be kicked when the limit is switched off | treat 0 as "no limit" |
| W03-B3 | 0x7410, 0x9824 | notice copied with strcpy, length field trusted; no bound to the 0x2000 buffer | oversized / unterminated notice overruns the packet buffer | bound to 512 and to the received length |
| W03-B4 | 0x7416 | MemberGrade not range-checked | any grade value reaches the DB | allow only the defined grades |
| W03-B5 | 0x7467 (FUN_0044a660) | enemy guild not found → NULL dereference | WM crash, reachable only by an unsolicited DB packet (the WM never sends 0x7466; its own fabricated ack always names an existing guild) | refuse |
| W03-B6 | war timer, 0x7435 | 1-byte payload uninitialised | garbage byte | send 0 / drop the byte |
| W03-B7 | 0x7473 | len and link count not checked against the packet length | reads beyond the request | check sizes |
| W03-B8 | 0x7476 | unknown guild → EmblemInfo uninitialised | garbage emblem shown | 0xFFFF |
| W03-B9 | 0x74BE, 0x74C3 error replies | token / GT_COND_INFO bytes uninitialised | garbage to the client | zero them |
| W03-B10 | 0x7505 | states 1/4 with enough members and state 3 after the period: no reply, no save | client waits for an answer forever | refresh the state and continue |
| W03-B11 | 0x7508 (FUN_0044fae0) | sends opcode 0x110D instead of 0x750D | only reached when the state changed to 1/4 between 0x7507 and its ack (0x7505 refuses states 1/4); 0x110D has no receiver in the Character server (opcodes.json `received_by: []`), so the OFF state is never stored | 0x750D |
| W03-B12 | 0x7504 (FUN_0040e640) | guild lookup not NULL-checked | crash on an emblem row of an unknown guild | skip the row |
| W03-B13 | 0x745B (FUN_00440f50) | academy members' guild fields cleared instead of their academy fields | academy members keep a dangling academy entry pointer | clear +0x1DF88 / +0x1DF8C |
| W03-B14 | 0x74EF | dismissal cancel not broadcast | members still see "scheduled for dismissal" | send 0x742F with status 0 |
| W03-B15 | 0x74B1, 0x74B9, 0x74B3, 0x74BB | failures after item use only logged | item lost, nothing changes, no message | answer the zone / refund |
| W03-B16 | 0x74B7 / 0x74B9 | nType not range-checked | any type value stored | check range |
| W03-B17 | 0x749E / 0x9870 errors | 6-byte zone header uninitialised | zone cannot route the error | copy the header |
| W03-B18 | 0x74EC | nJoinGuildNum keeps the DB count while unknown guilds are skipped | client reads past the rows | write the copied count |
| W03-B19 | 0x74EC | size check only logs; copy continues | buffer overrun with many entries | stop / chunk |
| W03-B20 | 0x9809 | success reply sent as opcode 0x9808 with the 14-byte rank layout; the client's 0x9808 handler (FUN_006f45c0) reads offsets 0, 26, 30, 34 and so parses past the end as academy info; 0x980A errors carry 12 uninitialised bytes, and the 2016 client has no 0x980A handler anyway | rank info never usable | a client-supported rank packet |
| W03-B21 | 0x982C | no check that an invitation was sent; the client-supplied `sInviteCharID` (+0x10) is forwarded unchecked in 0x982F; since the 2016 client ignores 0x982B, the flow 0x9829 → 0x982B → 0x982C cannot run from the UI and 0x982C only comes from a crafted client | crafted client promotes itself into its guild | store and require a pending invite |
| W03-B22 | 0x9859 | target index > 100 refused although the member table holds 400 | members beyond index 100 cannot be academy master | compare with the member count |
| W03-B23 | 0x9815 (FUN_0044bc30) | unknown guild → reads the guild name through NULL | WM crash | answer with an error |
| W03-B24 | 0x747B (FUN_0043f6e0) | nTeamPosition uninitialised | garbage | 0 |
| W03-B25 | 0x748B | 3 trailing bytes (min level / members in 2017) uninitialised | garbage to the DB | fill or shorten |
| W03-B26 | 0x9816 | re-join block entry added before the DB confirms the kick | a failed kick still blocks re-joining | add on 0x981A success |
| W03-B27 | 0x9888 | requester offline → target session not updated | chat ban only works after relog | look the target up independently |
| W03-B28 | Tournament_Tick / 0x748C | phases 9–0xB map to 0; with a failing DB the WM re-requests phase 0 every minute (0xB → 0 → error → 0xB) | endless 0x748B traffic | stop after an error |
| W03-B29 | 0x9830 (FUN_0044f660) | guild add succeeds, academy removal fails → member of both, no reply | inconsistent tables | roll back / reply |
| W03-B30 | 0x7501 / 0x7505 | 0x3704 used for "not master", client text says "next month" | misleading message | a dedicated code |
| W03-B31 | 0x9816 | 0x31B9 used for an index overflow, client text is a time limit; 0x179C never sent | misleading / dead codes | add the kick delay or drop the code |

Smaller observations without a bug ID: the 0x7456 request carries one uninitialised byte; the war state is held
only in the requesting guild and is not restored after a WM restart (§9.1); a war kill outside the war window
still counts (§3.4); 0x7434 always reports fame gains of 0; the hourly 0x745A and the per-minute 0x9857 repeat until
the DB answers.

## 12. Not reconstructed / uncertain

- `nGTNo`: the WM uses Time_Start (T+0) wherever a tournament number is sent; whether the DB's tournament number is
  the start time could not be checked (D-items: `p_GuildTournament*` procedures).
- The exact field copies of 0x7457 (GUILD_DB → GUILD_CLIENT), 0x9802, 0x9804, 0x980C rows and 0x9814 payload were
  checked only for the fields named in the text.
- Grades 4–6 have no names (new members get 6). The class excluded from academies (`SHAPE & 0x7C == 0x68`) is not
  decoded.
- `s.+0x1DF84` / `+0x1DF90` are "info pending" flags *(inferred from their use in §4.2)*; `s.+0x1E28C` holds a charNo
  used to find the academy master (origin W01).
- GuildAcademy.shn `LeastJoinTime` / `RankAggregationTime` columns: the WM reads the BuffName only in the code read here;
  where the 0x17A4 leave delay comes from (DB value vs table) is *(inferred)*.
- Client texts: replies handled only through the GuildTask listener (`this+0x40` vtable: 0x7427, 0x750A, 0x9808) and
  the default paths of 0x9822 / 0x9832 / 0x985A show no code-specific text in the code read; their window code was
  not followed.
- The emblem `Emblem_PeriodOver` compare is read from the machine code (year/month only).

## 13. Coverage boundary

| Found | Covered by | Argument |
|---|---|---|
| OPTool guild handlers 0x2815, 0x2820, 0x2822, 0x2824, 0x282B (FUN_004264d0, 427630, 426990, 427980, 427030) | W04 (scope table rows 0x2815 … 0x282B) | registered on CParserOPTool and listed in W04's table; W03 documents only the CharDB answer 0x74EF they cause |
| Zone-side guild war, tournament arena, storage and token shop (0x74CA–0x74E2, 0x74F0–0x74F3, guild storage) | Z16 (plan: "guild tournament system": GT arena, flag capture, guild skills) and Z08 (scope table rows `0x7491` NC_GUILD_STORAGEOPEN_REQ, `0x74ca` …FLAGCAPTURE_REQ, `0x74cf` …USESKILL_REQ, and the WorldManagerSession receivers of 0x7443/0x7449) | zone ↔ client packets; the WM only receives the summaries listed in §3, §8 |
| Character DB procedures behind 0x7458, 0x745A, 0x7469 … 0x9887 (money, item, history writes) | D04 (scope table rows `0x7458` NC_GUILD_DB_MAKE_REQ, `0x745a`, `0x9814` …) | the WM only relays; the DB decides costs (0xC9A/0xC9C) and history rows |
| Character delete flow outside the guild check (0x1407 / 0x1408 / 0x140B) | W01 | W01 owns the handlers; W03 documents the guild check 0x1413 → 0x1414 / 0x1416 (§4.5) and corrects the opcode W01 records |
| W01 CharIDChange (FUN_00431dd0), level change (FUN_0042e160), logout (FUN_00436d50), map login (FUN_0042d8d0) outside the guild parts | W01 | only their guild / academy parts are documented here (§4) |
| `FUN_004355a0`, `FUN_00451930`, `FUN_00451290` (level change, other features) | W01 / W04 | not guild related |

