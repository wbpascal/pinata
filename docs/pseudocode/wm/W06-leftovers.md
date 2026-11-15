# World Manager: leftover class-named functions and three open points (W06)

Source: `Files/Server/2016/w00_WorldManager/4WorldManagerServer2.exe`, read in the PDB re-analysis
`re-data/exports/wm-pdb` (`python3 -I tools/protocol-re/clean.py re-data/exports/wm-pdb - <addr>`). Class, member and
struct names come from the 2016 `WorldManager.pdb` *(pdb2016)*; plain statements are read in the code. The function
list is `python3 -I docs/plan/status/X02-cov.py game wm 100` (98 class-named functions no document cited,
`docs/review/confidence.md` §4.4). This document covers them and the verdicts on X02's open points E14, E15 and E25
(`confidence.md` §3.5.3). Corrections to W03 / W04 are collected in `docs/knowledge/W06.md` §0.

Reachability was checked on the 2016 exe: every 4-byte absolute reference and every `E8`/`E9` rel32 call/jump to each
function (`python3 -I docs/plan/status/W06-refs.py <exe> <hex addr>…`), the RTTI vftables (`tools/protocol-re/rtti.py`), and every
virtual call `(**(code **)(… + slot))` in `wm-pdb/decomp.c`.

## 1. Guild classes shared with the client (`CGuild`, `CGuildMember`, `CGuildAcademyMember`)

### 1.1 Classes and vftables

The WM links the same guild classes as the client (the 2017 client calls the same `CGuild*::Recv_NC_GUILD_*` members
from its `GuildTask` handlers, e.g. `Recv_NC_GUILD_MEMBER_LOGON_CMD` @ client2017 FUN_006b8490). The WM derives a
`*Server` class from each and keeps one of each per guild entry (`CGuildManager::GUILD_SERVER_LIST`, W03 §1.2).
Base and derived class each have their own vftable; no derived class overrides a base slot, so both tables hold the
same function addresses (W03 §1.2 says "vftable shared": the content is, the table is not).

| Class | Size | vftable | Slots | Derived (WM) | vftable | Slots |
|---|---|---|---|---|---|---|
| `CGuild` | 0x788 | 0x48CAB4 | 20 | `CGuildServer` | 0x48AA1C | 20 |
| `CGuildMember` | 0xABE8 | 0x48CA24 | 21 | `CGuildMemberServer` | 0x48A94C | 21 |
| `CGuildAcademyMember` | 0x2A9C | 0x48CA7C | 12 | `CGuildAcademyMemberServer` | 0x48AFC8 | 13 (+ `GetIndex`) |

The base vftables are written only by the base constructors / destructors (`CGuild::CGuild` FUN_0045c200,
`CGuild::~CGuild` FUN_0045c300, `CGuildMember::CGuildMember` FUN_0045b3b0, `~CGuildMember` FUN_0045a7f0,
`CGuildAcademyMember::CGuildAcademyMember` FUN_0045b8f0, `~CGuildAcademyMember` FUN_0045b250), which the derived ones
chain; the derived vftables are installed by `GUILD_SERVER_LIST::GUILD_SERVER_LIST` FUN_0044fec0, `CGuildManager::Clear`
FUN_00450e10 and the temporaries of `Recv_NC_GUILD_DB_ALL_ACK` FUN_00450240 / `Recv_NC_GUILD_DB_MAKE_ACK` FUN_00450750.

Data members *(pdb2016)*:

- `CGuild`: +0x08 `m_bIsGuild`, +0x0C `GUILD_CLIENT m_Guild`, **+0x438 `CGuildWar m_GuildWar`** (§1.5), +0x448
  `m_GuildToken`, +0x450 `m_GTCondInfo`, +0x47C `m_bIsGuildAcademy`, +0x480 `GUILD_ACADEMY_CLIENT m_GuildAcademy` (0x2E0:
  +0x00 sAcademyMasterName, +0x14 nNumAcademyMembers, +0x16 nMaxAcademyMembers, +0x18 nAcademyPoint, +0x1C nAcademyRank,
  +0x20 dAcademyBuffUntilTime, +0x24 sIntro[128], +0xA4 dNotifyDate, +0xA8 tm, +0xCC sNotifyCharID, +0xE0 sNotify[512]),
  +0x760 `nAcademyRewardStorageMoney` (u64), +0x768 `m_GuildAcademyGraduateCount`, +0x76C `m_PreAcademyRank`, +0x770
  `m_bisGuildAcademyBuff`, +0x774 emblem fields (W03 §1.2 table agrees).
- `CGuildMember`: +0x04 u16 `m_NumOfMembers`, +0x06 `GUILD_MEMBER_CLIENT m_Members[400]` (0x6E each; W03 §1.3).
- `CGuildAcademyMember`: +0x04 u16 `m_NumOfAcademyMembers`, +0x06 `GUILD_ACADEMY_MEMBER_CLIENT m_AcademyMembers[100]`
  (0x6D each; W03 §1.4). `CGuildAcademyMemberServer` adds +0x2A9C `m_AcademyMemberDataStatus`, +0x2AA0 / +0x2AA4 requestor
  queue, +0x2AA8 `GUILD_ACADEMY_MEMBER_SERVER m_AcademyMembersServer[100]` (0x30 each), +0x3D68 session pointers.
- `SHINE_GUILD_MEMBER_LOGON_INFO` / `SHINE_GUILD_ACADEMY_MEMBER_LOGON_INFO` (u32 bit field): bit 0 `login`, bits 1–11
  `year`, 12–15 `month`, 16–20 `day`, 21–25 `hour`.

### 1.2 Slot map and reachability

Small identical bodies are COMDAT-folded: one address serves several slots and carries only one of their names (the 2017
client has the same folding, so its PDB does not name the folded slots either). "Called by" lists every virtual call
through the slot in the 2016 WM; **dead** = no virtual call through that slot of either vftable and no other reference
(the only references are the two vftable entries). The WM calls exactly the slots 0x2C and 0x4C of `CGuildServer`,
0x1C / 0x20 / 0x24 / 0x28 of `CGuildMemberServer` and 0x04 / 0x08 / 0x0C / 0x30 of `CGuildAcademyMemberServer`.

`CGuild` / `CGuildServer`:

| Slot | Function | Opcode | Called by (WM) | WM sends the opcode (where) |
|---|---|---|---|---|
| 0x00 | `Recv_NC_GUILD_MAKE_ACK` FUN_0045c160 | 0x7406 | dead | W03 §2.2 |
| 0x04–0x10 | `return 1` stub FUN_0045abc0 (folded; PDB name `CGuildManager::Recv_NC_GUILD_DB_INTRO_ACK`) | ? | dead as a slot (`fc_NC_GUILD_DB_INTRO_ACK` FUN_0040bb50 calls FUN_0045abc0 directly, W03 §9.2) | – |
| 0x14 | `Recv_NC_GUILD_MY_GUILD_INFO_ACK` FUN_0045b880 | 0x7419 | dead | W03 §2.10 |
| 0x18 | `Recv_NC_GUILD_MONEY_ADD_ACK` FUN_0045abd0 | 0x741F | dead | not sent by the 2016 WM |
| 0x1C | `Recv_NC_GUILD_DISMISS_CMD` FUN_0045ac10 | 0x742F | dead | W03 §2.3, §9.2 |
| 0x20 | `Recv_NC_GUILD_DELETE_CMD` FUN_0045ac60 | 0x7430 | dead | W03 §9.2 |
| 0x24 | `Recv_NC_GUILD_MONEY_ADD_CMD` FUN_0045aca0 | 0x742B | dead | not sent by the 2016 WM |
| 0x28 | same address (folded; `MONEY_SUB_CMD` *(inferred: opcode 0x742C follows)*) | 0x742C | dead | not sent by the 2016 WM |
| 0x2C | `Recv_NC_GUILD_NOTIFY_CMD` FUN_0045acd0 | 0x742D | `Recv_NC_GUILD_DB_NOTIFY_ACK` FUN_00445ca0 | W03 §2.8 |
| 0x30 | `Recv_NC_GUILD_GRADE_CMD` FUN_0045ad50 | 0x742E | dead | not sent by the 2016 WM |
| 0x34 | `Recv_NC_GUILD_WAR_ACK` FUN_0045abf0 | 0x7423 | dead | W03 §3.2 |
| 0x38 | `Recv_NC_GUILD_WAR_LIST_ACK` FUN_0045c190 | 0x7427 | dead | W03 §3.5 |
| 0x3C | `Recv_NC_GUILD_WAR_TARGET_CMD` FUN_0045bdb0 | 0x7432 | dead | W03 §3.2 (`FUN_004440d0`) |
| 0x40 | `Recv_NC_GUILD_WAR_START_CMD` FUN_0045ad70 | 0x7433 | dead | W03 §3.3 |
| 0x44 | `Recv_NC_GUILD_WAR_END_CMD` FUN_0045be90 | 0x7434 | dead | W03 §3.3 |
| 0x48 | `Recv_NC_GUILD_WAR_COOLDOWN_DONE_CMD` FUN_0045adb0 | 0x7435 | dead | W03 §3.3 |
| 0x4C | `Recv_NC_GUILD_ACADEMY_NOTIFY_CMD` FUN_0045add0 | 0x9826 | `Recv_NC_GUILD_ACADEMY_DB_NOTIFY_ACK` FUN_004484d0 | W03 §6.3 |

`CGuildMember` / `CGuildMemberServer`:

| Slot | Function | Opcode | Called by (WM) | WM sends the opcode (where) |
|---|---|---|---|---|
| 0x00–0x14 | empty `void` stub FUN_0043c7b0 (folded; PDB name `Recv_NC_GUILD_MEMBER_INVITE_ACK`, 0x740A) | ? | dead | W03 §2.4 (0x740A) |
| 0x18 | `Recv_NC_GUILD_MEMBER_LIST_ACK` FUN_0045b460 | 0x741B | dead | W03 §2.11 |
| 0x1C | `Recv_NC_GUILD_MEMBER_JOIN_CMD` FUN_0045a860 | 0x7436 | `CGuildMemberServer::MemberJoin` FUN_0044e200 | W03 §2.5 |
| 0x20 | `Recv_NC_GUILD_MEMBER_VANISH_CMD` FUN_0045a8a0 | 0x7437 | `CGuildMemberServer::MemberVanish` FUN_00443da0 | W03 §2.6 |
| 0x24 | same address (folded; `MEMBER_LEAVE_CMD` *(inferred: 0x7438 follows, and the caller is the leave path)*) | 0x7438 | `CGuildMemberServer::MemberLeave` FUN_00443c80 | W03 §2.7 |
| 0x28 | `Recv_NC_GUILD_MEMBER_GRADE_CMD` FUN_0045b560 | 0x7439 | `Recv_NC_GUILD_DB_MEMBER_GRADE_ACK` FUN_0044aae0 | W03 §2.9 |
| 0x2C | `Recv_NC_GUILD_MEMBER_FLAGS_CMD` FUN_0045b5a0 | 0x743A | dead | not sent by the 2016 WM |
| 0x30 | `Recv_NC_GUILD_MEMBER_EXP_RATIO_CMD` FUN_0045b5e0 | 0x743B | dead | not sent by the 2016 WM |
| 0x34 | `Recv_NC_GUILD_MEMBER_INTRO_CMD` FUN_0045b7f0 | 0x743C | dead | not sent by the 2016 WM |
| 0x38 | `Recv_NC_GUILD_MEMBER_LOGON_CMD` FUN_0045b620 | 0x743D | dead | W03 §4.2 |
| 0x3C | `Recv_NC_GUILD_MEMBER_LOGOFF_CMD` FUN_0045b660 | 0x743E | dead | W03 §4.3, §4.4 |
| 0x40 | `Recv_NC_GUILD_MEMBER_PARTY_CMD` FUN_0045b720 | 0x743F | dead | not sent by the 2016 WM |
| 0x44 | `Recv_NC_GUILD_MEMBER_LEVEL_CMD` FUN_0045b760 | 0x7440 | dead | W03 §4.7 |
| 0x48 | `Recv_NC_GUILD_MEMBER_MAP_CMD` FUN_0045b7a0 | 0x7441 | dead | W03 §4.2 |
| 0x4C | `Recv_NC_GUILD_MEMBER_CLASS_CMD` FUN_0045b840 | 0x7442 | dead | not sent by the 2016 WM |
| 0x50 | `Recv_NC_GUILD_ACADEMY_MEMBER_GUILD_JOIN_CMD` FUN_0045a8f0 | 0x982E | dead | W03 §6.2 (`FUN_00440b40`; the 2016 client ignores 0x982E) |

`CGuildAcademyMember` / `CGuildAcademyMemberServer`:

| Slot | Function | Opcode | Called by (WM) | WM sends the opcode (where) |
|---|---|---|---|---|
| 0x00 | `Recv_NC_GUILD_ACADEMY_MEMBER_LIST_ACK` FUN_0045b920 | 0x980E | dead | W03 §5 |
| 0x04 | `Recv_NC_GUILD_ACADEMY_MEMBER_JOIN_CMD` FUN_0045b2c0 | 0x9813 | `AcademyMemberJoin` FUN_0044b6c0 | W03 §6.2 |
| 0x08 | `Recv_NC_GUILD_ACADEMY_MEMBER_VANISH_CMD` FUN_0045b300 | 0x9818 | `AcademyMemberVanish` FUN_00447030 | W03 §6.2 |
| 0x0C | same address (folded; `ACADEMY_MEMBER_LEAVE_CMD` *(inferred)*) | 0x9860 | `AcademyMemberLeave` FUN_00446f20 | W03 §6.2 |
| 0x10 | `Recv_NC_GUILD_ACADEMY_MEMBER_INTRO_CMD` FUN_0045ba20 | 0x9864 | dead | not sent by the 2016 WM |
| 0x14 | `Recv_NC_GUILD_ACADEMY_MEMBER_LOGON_CMD` FUN_0045ba70 | 0x9861 | dead | W03 §4.2 |
| 0x18 | `Recv_NC_GUILD_ACADEMY_MEMBER_LOGOFF_CMD` FUN_0045bab0 | 0x9862 | dead | W03 §4.4 |
| 0x1C | `Recv_NC_GUILD_ACADEMY_MEMBER_PARTY_CMD` FUN_0045bb70 | 0x9865 | dead | not sent by the 2016 WM |
| 0x20 | `Recv_NC_GUILD_ACADEMY_MEMBER_LEVEL_CMD` FUN_0045bbb0 | 0x9866 | dead | W03 §4.7 |
| 0x24 | `Recv_NC_GUILD_ACADEMY_MEMBER_MAP_CMD` FUN_0045bbf0 | 0x9863 | dead | W03 §4.2 |
| 0x28 | `Recv_NC_GUILD_ACADEMY_MEMBER_CLASS_CMD` FUN_0045bc40 | 0x9867 | dead | not sent by the 2016 WM |
| 0x2C | `Recv_NC_GUILD_ACADEMY_MEMBER_GUILD_JOIN_CMD` FUN_0045b350 | 0x982E | dead | W03 §6.2 (`FUN_00447cc0`; ignored by the 2016 client) |
| 0x30 | `CGuildAcademyMemberServer::GetIndex` FUN_00440fd0 (derived class only) | – | 12 callers (§1.3) | – |

"Not sent by the 2016 WM" = no WM send site in `re-data/exports/wm/layouts.json` (`.s2c`) and none in the zone's either;
these opcodes have no 2016 sender found *(inferred from the generated layouts; Character / zone hand-built buffers not
searched further)*.

**The five members the plan names** (`CGuild::Recv_NC_GUILD_WAR_TARGET_CMD` FUN_0045bdb0, `Recv_NC_GUILD_WAR_END_CMD`
FUN_0045be90, `Recv_NC_GUILD_ACADEMY_NOTIFY_CMD` FUN_0045add0, `CGuildMember::Recv_NC_GUILD_MEMBER_LIST_ACK`
FUN_0045b460, `CGuildAcademyMember::Recv_NC_GUILD_ACADEMY_MEMBER_LIST_ACK` FUN_0045b920): four are dead in the WM (only
their two vftable entries reference them); `Recv_NC_GUILD_ACADEMY_NOTIFY_CMD` is live through slot 0x4C (§1.3). W03
documents the WM side of each opcode through the send sites listed above.

### 1.3 Live slots

These bodies only update the `*_CLIENT` copy kept per guild entry (the copy the WM serialises into its own 0x741B /
0x980E member lists and the 0x7419 guild info); the server records and session pointers are handled by the callers
(W03 §2.5–§2.7, §6.2).

```pseudo
CGuildMember::Recv_NC_GUILD_MEMBER_JOIN_CMD(M, p { GUILD_MEMBER_CLIENT Member })    @ FUN_0045a860   (slot 0x1C)
    if M.m_NumOfMembers > 399: return 0
    M.m_Members[M.m_NumOfMembers] = p.Member            # GUILD_MEMBER_CLIENT::operator=, 0x6E bytes
    M.m_NumOfMembers += 1; return 1
    # caller MemberJoin FUN_0044e200 (W03 §2.2 "M.vtbl[7]") builds p from the joining session

CGuildMember::Recv_NC_GUILD_MEMBER_VANISH_CMD(M, p { Name5 CharID })                @ FUN_0045a8a0   (slots 0x20, 0x24)
    i = CGuildMember::GetIndex(M, p.CharID)             # by name, FUN_0045a810 (W03 `Members_IndexByName`)
    if i == -1: return 0
    M.m_NumOfMembers -= 1
    memcpy(&M.m_Members[i], &M.m_Members[i+1], (M.m_NumOfMembers − i)·0x6E)   # shift down; last slot not cleared
    return 1
    # slot 0x20: MemberVanish FUN_00443da0 (kick, W03 §2.6); slot 0x24: MemberLeave FUN_00443c80 (W03 §2.7)
    # overlapping memcpy: correct only because the MSVC CRT memcpy copies forward / handles overlap (inferred)

CGuildAcademyMember::Recv_NC_GUILD_ACADEMY_MEMBER_JOIN_CMD(A, p { GUILD_ACADEMY_MEMBER_CLIENT Member })
                                                                                    @ FUN_0045b2c0   (slot 0x04)
    if A.m_NumOfAcademyMembers > 99: return 0
    A.m_AcademyMembers[count] = p.Member (0x6D bytes); count += 1; return 1          # caller FUN_0044b6c0 (W03 §6.2)

CGuildAcademyMember::Recv_NC_GUILD_ACADEMY_MEMBER_VANISH_CMD(A, p { Name5 CharID })  @ FUN_0045b300   (slots 0x08, 0x0C)
    i = CGuildAcademyMember::GetIndex(A, p.CharID) (by name); -1 → return 0
    count −= 1; memcpy(&A[i], &A[i+1], (count − i)·0x6D); return 1
    # slot 0x08: AcademyMemberVanish FUN_00447030; slot 0x0C: AcademyMemberLeave FUN_00446f20 (W03 §6.2)

CGuildAcademyMemberServer::GetIndex(A, u32 charNo) → index or -1                    @ FUN_00440fd0   (slot 0x30)
    for i in 0 .. A.m_NumOfAcademyMembers−1:
        if A.m_AcademyMembersServer[i].nAcademyMemberCharNo == charNo: return i      # stride 0x30 from A+0x2AA8
    return -1
    # callers: CGuildAcademyMemberServer::Get FUN_00441000, AcademyMemberLeave FUN_00446f20,
    # SendAcademyMemberDataToRequestor FUN_0044b500, Recv_NC_GUILD_ACADEMY_MEMBER_LIST_REQ FUN_0044b890,
    # Recv_NC_GUILD_ACADEMY_MEMBER_LEAVE_REQ FUN_0044b990, Recv_NC_GUILD_ACADEMY_DB_MEMBER_JOIN_ACK FUN_0044bc30,
    # …_DB_MEMBER_VANISH_ACK FUN_0044c020, …_DB_MEMBER_LEAVE_ACK FUN_00448220, CGuildManager::Logoff FUN_0044ccf0,
    # fc_NC_GUILD_ACADEMY_MEMBER_DB_CHAT_BAN_ACK FUN_0040f540 / _CANCEL_ACK FUN_0040f740,
    # fc_NC_CHAR_LEVEL_CHANGED_CMD FUN_0042e160, CWMClientSession::CharIDChange FUN_00431dd0

CGuild::Recv_NC_GUILD_ACADEMY_NOTIFY_CMD(g, p PROTO_NC_GUILD_ACADEMY_NOTIFY_CMD)     @ FUN_0045add0   (slot 0x4C)
    # p = { i32 dNotifyDate; tm tm_dNotifyDate; Name5 sNotifyCharID; u16 nNotifyLength; char sNotify[] } (0x3E + text)
    if g.m_bIsGuildAcademy == 0 or p == null: return 0       # caller ignores the result and still broadcasts
    g.m_GuildAcademy.dNotifyDate = p.dNotifyDate; .tm_dNotifyDate = p.tm_dNotifyDate; .sNotifyCharID = p.sNotifyCharID
    strcpy(g.m_GuildAcademy.sNotify /* [512] at g+0x560 */, p.sNotify)          # nNotifyLength not used, no bound
    return 1
    # (original bug) W06-B1: the caller FUN_004484d0 (0x9828 answer, W03 §6.3) first strcpy's the DB text into
    # a stack PROTO_NC_GUILD_ACADEMY_NOTIFY_CMD (local_248, text at +0x3E) and then passes it here; neither copy is
    # bounded, so a notice longer than 511 bytes overruns the stack frame and then g+0x760.. (reward money fields)
```

The 0x2C slot (`CGuild::Recv_NC_GUILD_NOTIFY_CMD` FUN_0045acd0) and 0x28 slot (`CGuildMember::Recv_NC_GUILD_MEMBER_GRADE_CMD`
FUN_0045b560) are documented by W03 (§2.8, §2.9).

### 1.4 Dead slots (client-side handlers compiled into the WM)

Never executed by the WM. They are the client's handlers for these opcodes (same code in the client); summarised here
so a rebuild knows the WM need not implement them.

```pseudo
# all "member" CMDs: i = GetIndex(table, p.CharID) by name; -1 → return 0; then one field of the *_CLIENT row:
CGuildMember::Recv_NC_GUILD_MEMBER_FLAGS_CMD      { Name5 CharID; u32 Flags }   → nFlags       @ FUN_0045b5a0
CGuildMember::Recv_NC_GUILD_MEMBER_EXP_RATIO_CMD  { Name5 CharID; u16 ExpRatio } → nExpRatio  @ FUN_0045b5e0
CGuildMember::Recv_NC_GUILD_MEMBER_INTRO_CMD      { Name5 CharID; u16 nMemberIntroLength; char sMemberIntro[] }
                                                  → strcpy into sIntro[64] (length not used, unbounded)
                                                                                               @ FUN_0045b7f0
CGuildMember::Recv_NC_GUILD_MEMBER_LOGON_CMD      { Name5 CharID }  → dLogonInfo.login = 1     @ FUN_0045b620
CGuildMember::Recv_NC_GUILD_MEMBER_LOGOFF_CMD     { Name5 CharID }  → login = 0; year/month/day/hour = GetLocalTime()
                                                                                               @ FUN_0045b660
CGuildMember::Recv_NC_GUILD_MEMBER_PARTY_CMD      { Name5 CharID; u8 Party }   → bIsParty      @ FUN_0045b720
CGuildMember::Recv_NC_GUILD_MEMBER_LEVEL_CMD      { Name5 CharID; u8 Level }   → nLevel        @ FUN_0045b760
CGuildMember::Recv_NC_GUILD_MEMBER_MAP_CMD        { Name5 CharID; Name3 sMap } → sMap          @ FUN_0045b7a0
CGuildMember::Recv_NC_GUILD_MEMBER_CLASS_CMD      { Name5 CharID; u8 ClassID } → nClassID      @ FUN_0045b840
CGuildAcademyMember: INTRO FUN_0045ba20 (strcpy into sIntro[64]), LOGON FUN_0045ba70, LOGOFF FUN_0045bab0 (same
    time stamp), PARTY FUN_0045bb70, LEVEL FUN_0045bbb0, MAP FUN_0045bbf0, CLASS FUN_0045bc40: same as above on
    GUILD_ACADEMY_MEMBER_CLIENT

CGuildMember::Recv_NC_GUILD_MEMBER_LIST_ACK { u16 TotalMemberCount; u16 MemberIndex; u16 MemberCount; GUILD_MEMBER_CLIENT rows[] }
                                                                                               @ FUN_0045b460
    if MemberIndex + MemberCount > 400: return 0
    rows[k] → m_Members[MemberIndex + k] (field by field, 0x6E each); m_NumOfMembers = max(count, Index + Count)
CGuildAcademyMember::Recv_NC_GUILD_ACADEMY_MEMBER_LIST_ACK { u16 Total…; u16 AcademyMemberIndex; u16 AcademyMemberCount; rows }
                                                                                               @ FUN_0045b920
    same with 100 and 0x6D rows (incl. dJoinInfo, nJoinLevel); TotalMemberCount is not read by either
CGuildMember::Recv_NC_GUILD_ACADEMY_MEMBER_GUILD_JOIN_CMD { GUILD_MEMBER_CLIENT Member }      @ FUN_0045a8f0
    same body as MEMBER_JOIN_CMD: append (the graduate becomes a guild member)
CGuildAcademyMember::Recv_NC_GUILD_ACADEMY_MEMBER_GUILD_JOIN_CMD { GUILD_MEMBER_CLIENT Member } @ FUN_0045b350
    i = GetIndex(A, Member.sName); remove row i (as VANISH)   # the graduate leaves the academy table

CGuild::Recv_NC_GUILD_MAKE_ACK { u16 Error; u32 No; Name4 Name; u8 Type; i32 dCreateDate }  (Error not read)            @ FUN_0045c160
    CGuild::Make(g, No, Name, Type, dCreateDate) (FUN_0045bf60, the WM's own creation path W03 §2.2); return 1
CGuild::Recv_NC_GUILD_MY_GUILD_INFO_ACK { u16 Error; GUILD_CLIENT }                           @ FUN_0045b880
    Error != 0x0C41 → 0; else g.m_Guild = payload (GUILD_CLIENT::operator=); m_bIsGuild = 1
CGuild::Recv_NC_GUILD_MONEY_ADD_ACK / Recv_NC_GUILD_WAR_ACK { u16 Error } → Error == 0x0C41   @ FUN_0045abd0 / FUN_0045abf0
# the rest require m_bIsGuild (else return 0):
CGuild::Recv_NC_GUILD_DISMISS_CMD { Name4 Name; u8 nDismissStatus; i32 dDismissDate; tm } → stored in m_Guild  @ FUN_0045ac10
CGuild::Recv_NC_GUILD_DELETE_CMD → m_bIsGuild = m_bIsGuildAcademy = m_bisGuildAcademyBuff = 0, m_PreAcademyRank = 0,
    nAcademyRewardStorageMoney = 0, m_GuildAcademyGraduateCount = 0                           @ FUN_0045ac60
CGuild::Recv_NC_GUILD_MONEY_ADD_CMD (and the folded SUB) { Name5 CharID; u64 GuildMoneyAdd; u64 GuildTotalMoney }
    → m_Guild.nMoney = GuildTotalMoney                                                         @ FUN_0045aca0
CGuild::Recv_NC_GUILD_GRADE_CMD { u8 Grade } → m_Guild.nGrade                                  @ FUN_0045ad50
CGuild::Recv_NC_GUILD_WAR_TARGET_CMD { SHINE_GUILD_WAR_INFO WarInfo }                          @ FUN_0045bdb0
    if WarInfo.nRequestNo == m_Guild.nNo:            # my own declaration
        m_Guild.nWarEnemy/sWarEnemyName/nWarEnemyGrade/nWarStatus/3 dates/3 tm/MyScore/EnemyScore = WarInfo's
    return CGuildWar::Add(m_GuildWar, WarInfo)       # §1.5
CGuild::Recv_NC_GUILD_WAR_START_CMD { Name4 WarGuildName; u32 RequestNo; i32 EndDate; tm }     @ FUN_0045ad70
    CGuildWar::Update(m_GuildWar, RequestNo, status 2, EndDate, tm)
CGuild::Recv_NC_GUILD_WAR_END_CMD { Name4 EnemyGuildName; u32 RequestNo; u32 EnemyGuildFameAdd; u32 GuildFameAdd;
                                   u32 GuildTotalFame; u8 WarResult; u8 WarStatus }           @ FUN_0045be90
    RequestNo == m_Guild.nNo → CGuildWar::Update(…, status 3, m_Guild.dWarEndDate, tm) else CGuildWar::Del(RequestNo)
    m_Guild.nFame = GuildTotalFame; WarResult 0 → nWarWinCount++, 1 → nWarLoseCount++, 2 → nWarDrawCount++
CGuild::Recv_NC_GUILD_WAR_COOLDOWN_DONE_CMD → m_Guild.nWarEnemy = 0, nWarStatus = 0             @ FUN_0045adb0
```

### 1.5 `CGuildWar m_GuildWar` (CGuild+0x438): the war list

Correction of W03 §1.2 (its row +0x438 calls this a "member-info list"; `docs/knowledge/W06.md` §0): CGuild+0x438 is
`CGuildWar` *(pdb2016)* { +0 i32 `m_NumOfWarList`, +4 `m_pGuildWarListTop`, +8 `m_pGuildWarListBottom` }, a doubly linked
list of `CGuildWar::GUILD_WAR_LIST` nodes (0xF4 bytes: `SHINE_GUILD_WAR_INFO WarInfo` 0xEA, then `pLinkUp`, `pLinkDn`).
Only the dead slots 0x38 / 0x3C / 0x40 / 0x44 add to it, so in the WM it stays empty; `CGuildWar::Clear` FUN_0045bf20 also
runs from `CGuild::Make` FUN_0045bf60 (guild creation, W03 §2.2) and `CGuild::~CGuild` FUN_0045c300.

`SHINE_GUILD_WAR_INFO` (0xEA) *(pdb2016)*: +0x00 nNo, +0x04 Name4 sName, +0x14 nGrade, +0x15 nWarStatus, +0x16
nWarStatusRemainSec, +0x1A dRequestDate, +0x1E dStartDate, +0x22 dEndDate, +0x26 / +0x4A / +0x6E three `tm`, +0x92
nRequestNo, +0x96 `SHINE_GUILD_SCORE` MyScore, +0xC0 EnemyScore (0x2A each). W03 §3.5 builds the same rows for 0x7427.

```pseudo
CGuildWar::Add(w, info)                                                             @ FUN_0045bc80
    node with node.WarInfo.nRequestNo == info.nRequestNo → node.WarInfo = info (SHINE_GUILD_WAR_INFO::operator=
        FUN_0045a930: field-wise copy of all 0xEA bytes); return 1
    else node = new 0xF4; append at the bottom; m_NumOfWarList += 1; return 1
CGuildWar::Update(w, requestNo, status, *endDate, *tm)                              @ FUN_0045a9e0
    find by nRequestNo (else 0); set nWarStatus, dEndDate, tm_dEndDate; return 1
CGuildWar::Del(w, requestNo)                                                        @ FUN_0045bd30
    find by nRequestNo (else 0); unlink, delete, m_NumOfWarList −= 1; return 1
CGuildWar::Clear(w)                                                                 @ FUN_0045bf20
    delete all nodes; count = 0; bottom = null
```

### 1.6 Guild constructors, destructors, copy operators

| Function | What it does |
|---|---|
| `CGuildAcademyMember::CGuildAcademyMember` FUN_0045b8f0 | base vftable; 100 × `GUILD_ACADEMY_MEMBER_CLIENT` constructed (0x6D each); count = 0. Called from `GUILD_SERVER_LIST::GUILD_SERVER_LIST` FUN_0044fec0 |
| `CGuildAcademyMemberServer::~CGuildAcademyMemberServer` FUN_00446ee0 | frees the requestor queue (`m_pAcademyMemberDataRequestorTop` chain), then the base destructor. From `~GUILD_SERVER_LIST` FUN_0044fe20 |
| `CGuildAcademyServer::~CGuildAcademyServer` FUN_00438540 | frees `m_BanishMemberList` (std::vector storage, three words zeroed). Only from exception-unwind funclets (inlined in `~GUILD_SERVER_LIST`) |
| `CGuildServer::~CGuildServer` FUN_0043cce0 | resets the vftable, `CGuild::~CGuild`. Unwind funclets only |
| `CGuildMember::operator=` FUN_0043dbd0 | count + 400 rows copied (0x6E each). Only from `CGuildMemberServer::operator=` FUN_00445580 (which also copies `m_MemberDataStatus`, the requestor queue pointers, 400 `GUILD_MEMBER_SERVER` and 400 session pointers: a shallow copy) |
| `SHINE_GUILD_WAR_INFO::operator=` FUN_0045a930 | §1.5 |
| `CGuildTournament::~CGuildTournament` FUN_0045ae60 | destroys `m_TournamentList` (31 × 0x15-byte entries, trivial). From `CGuildTournamentServer` ctor unwind / dtor and `CGuildManager::~CGuildManager` FUN_00450f60 |
| `CGuildTournamentServer::~CGuildTournamentServer` FUN_0043d180 | `CDataReader::~CDataReader` of `m_GuildTournamentRequire`, `m_GuildTournamentRewardData`, `m_GuildTournamentScheduleData` (W03 §8.1 tables), then the base. From the `CGuildManager` dtor funclet |
| `CGuildDataServer::~CGuildDataServer` FUN_00403800 | `CDataReader` dtors of `m_GuildAcademyRankData`, `m_GuildAcademyLevelUpData`, `m_GuildAcademyData`, `m_GuildLevelScoreData`, `m_GuildGradeScoreData` (the guild tables of W03) |

All run only at shutdown or during exception unwinding; none has an observable effect on the protocol.

## 2. Verdicts on X02's open points

### 2.1 E14: the trailing 0x0CDB of 0x740C (W03 §2.5) is **not** dead

```pseudo
CParserClient::fc_NC_GUILD_MEMBER_JOIN_ACK(s, p { Name4 GuildName; u8 JoinAck })    @ FUN_00419db0
    … the checks of W03 §2.5; every error exit is
        return CGuildManager::Send_NC_GUILD_MEMBER_JOIN_ERR(s, p.GuildName, code)     @ FUN_0044a340
            # raw 0x740D { Name4 GuildName; u16 code } (0x15 bytes) → CWMBaseSession::Send(s) result
    r = s not academy-in-this-guild ? CGuildManager::Send_NC_GUILD_DB_MEMBER_JOIN_REQ(s, g.nNo, p)   @ FUN_0044aa30
                                    : CGuildManager::Send_NC_GUILD_ACADEMY_DB_MEMBER_GUILD_JOIN_REQ(s, g.nNo, …) @ FUN_0044c2d0
    if r == 0: return Send_NC_GUILD_MEMBER_JOIN_ERR(s, p.GuildName, 0x0CDB)
    return 1
```

Both helpers return 0 when `s` or `s.m_pCharDataBase` is null (already excluded by the handler's first check) and
otherwise **the result of `CWMBaseSession::Send(&gServer.m_CharDB, buf, len)`** (FUN_0042fca0 →
`CSocket_IOCP::Send` FUN_004666f0), not the opcode. `CSocket_IOCP::Send` returns 0 when the CharDB link's socket is
`INVALID_SOCKET` (link down: "CSocket_IOCP::Write, INVALID m_Socket=%d"), when `WriteFile` fails with an error other
than `ERROR_IO_PENDING` (0x3E5) (the buffer is freed, `gSocket_IOCP_Write` log), or for a zero-size buffer; else 1.
So 0x0CDB ("Failed to join % guild.", W03 §2.5 client texts) is sent **when the Character DB link is down or the
write fails**. W03 §2.5's last comment ("both send helpers return the opcode … dead code") is wrong.

Consequences: the invite was already cleared (`CWMClientSession::ClearGuildReserve`) before the send, so after a
0x0CDB the invitee needs a new invite. The handler's return value is the client send result: 1 normally, 0 only if
the 0x740D send to the client itself fails, which closes the client link (W05 §5.1). The same holds for the error exits
0x0CD8 / 0x0CD9 / 0x1BD1 / 0x1BD3 / 0x0CDD / 0x0CDA / 0x0CDE: they "return the helper's result" = the client send result.

0x740D layout confirmed: `{ u8 len 0x14, u16 0x740D, Name4 GuildName, u16 code }` (21 bytes).

### 2.2 E15: client 0x7425 `GuildTask::Recv_NC_GUILD_WAR_ABLE_LIST_ACK` (W03 §3.5): 0x0D1A / 0x0D1B are **not** silent

```pseudo
client GuildTask::Recv_NC_GUILD_WAR_ABLE_LIST_ACK(p { u16 Error; u8 PartMask; u16 NumOfWarInfo; rows[0x2A] })
                                                                                    @ client FUN_006b3e00
    if Error != 0x3198 and Error != 0x0C41: AddSysMsg(ErrMsgTable::GetErrMsg(Error))  # FUN_00416430
    if Error == 0x0D1C: AddSysMsg(TextData3 0x032D6F69 "Please try later.")
    if PartMask & 1: this+0xB00 = 0; CGuildWarAble::Clear(this+0x7C8)
    this+0xB00 += NumOfWarInfo; for each row: CGuildWarAble::Add(this+0x7C8, row)   # whatever Error was
```

Client texts (`ErrMsgTable::GetErrMsg`, `docs/protocol/client-error-codes.json`):

| Code | WM meaning (W03 §3.5) | Client shows |
|---|---|---|
| 0x0D1A | requester has no guild | no entry in the table → the default line "An unidentified error code has occurred.: 3354" (TextData 0xB4D3F216, `"%s: %d"`) (original bug) W06-B3 |
| 0x0D1B | requester's guild not found | "You have no joined guild" (TextData3 0x9C090D3F) |
| 0x0D1C | asked again within 5 s | the default line "An unidentified error code has occurred.: 3356" **and then** "Please try later." (original bug) W06-B2 |

The WM's error replies are the initial packet with only `Error` replaced: `PartMask = 1`, `NumOfWarInfo = 0`
(`FUN_0043e270` starts every packet as `41 0C 01 00 00`). So every error reply also **empties the client's war-able
list**, including the 5-second throttle reply (original bug) W06-B4.

### 2.3 E25 (second half): W04 §12.3, the dice-game test that drops the answer of 0x9405: **confirmed**

```pseudo
client GameFrameWork::On_NC_HOLY_PROMISE_SET_UP_CONFIRM_REQ(p { Name5 CharID; Name5 UpCharID })   @ client FUN_004afc30
    playing = MHDiceGameTask::IsDicegamePlaying(MHDiceGameTask::GetDiceGameTask())   # FUN_006a4600 / FUN_0048b2d0
                                                    # = byte task+0x148C of the singleton DAT_00b50d60
    if playing: return                              # no window, no text, nothing sent
    HolyPromiseWin::SetID(this+0x360, CharID, UpCharID)
    yes/no box TextData 0x37490F2E "%s is requesting you as a master. Do you wish to accept?" (CharID)
        → the answer is sent as 0x9405 NC_HOLY_PROMISE_SET_UP_CONFIRM_ACK (W04 §12.3)
```

The flag `+0x148C` is set to 1 by `MHDiceGameTask::Recv_NC_DICE_TAISAI_GAME_JOIN_ACK` FUN_006a7f10,
`Recv_NC_GAMBLE_DICE_TAISAI_GAME_JOIN_ACK` FUN_00707e10 and `Recv_NC_GAMBLE_SLOTMACHINE_GAME_JOIN_ACK` FUN_0071b370,
and cleared by `Recv_NC_DICE_TAISAI_GAME_LEAVE_ACK` FUN_006a7580, `ShutDownGambleHouse` FUN_006a7d70 and
`ShutDownSlotMachine` FUN_0071b660 (names: C02's client names). So "dice game playing" means **seated at a gamble-house
dice table or slot machine**. W04 §12.3's statement holds as written: while the would-be master sits at one, the
request is silently dropped. The apprentice has already received 0x9403 "You've asked %s to be your master." and gets
nothing more; the WM keeps no pending request (W04 §12.3), so nothing times out or needs cleaning up. The apprentice
can ask again once the master has left the table. This is a deliberate client rule *(inferred)*, not a bug; the only
effect worth noting for a rebuild is that the requester is never told (no refusal code exists for it).

## 3. The other leftover functions (shared code, destructors, CRT)

The 48 functions of the list that are not guild classes. None of them reads or writes protocol state. Reachability
from `W06-refs.py` (callers listed are the functions containing the `E8` call; "vftable" = only an absolute
reference from a vftable in `.rdata`).

### 3.1 `RandomBox rndbox` and `cWell512Random` (the global random source, shared with the zone)

```pseudo
`dynamic initializer for 'rndbox'` FUN_00482880 (CRT static init, before WinMain):
    RandomBox::RandomBox(&rndbox); atexit(`dynamic atexit destructor for 'rndbox'` FUN_00482b60)

RandomBox (0x348398, pdb2016) { RandomSlot rb_box[101] +0; RandomSlot rb_thausend[4] +0x328328;
                               cWell512Random rb_well512random +0x348348 }
RandomSlot (0x8008)          { u16 rs_slot[0x4000]; BitANDInt rs_point +0x8000 }      # ring of 16384 values

RandomBox::RandomBox(this)                                                          @ FUN_00467e90
    construct 101 + 4 RandomSlot (RandomSlot::RandomSlot FUN_00467de0), cWell512Random::cWell512Random   @ FUN_00468f60
        # the Well512 ctor zeroes m_nIndex, m_nZ0..m_nZ2 and the 16-word m_nState
    srand(_time32())
    for n in 0..100: rb_box[n] filled inline exactly as RandomSlot::rs_Init(n) below
    for k in 0..3:   RandomSlot::rs_Init(&rb_thausend[k], 1000)                    @ FUN_00467e00
    seed[0..15] = 16 × rand();  cWell512Random::well512_InitState(&rb_well512random, seed)   @ FUN_00468fa0
        # m_nIndex = m_nZ0 = m_nZ1 = m_nZ2 = 0; m_nState[0..15] = seed[0..15]

RandomSlot::rs_Init(this, n)                                                        @ FUN_00467e00
    rs_slot[i] = ⌊i·n / 0x4000⌋ for i in 0..0x3FFF                # each of 0..n−1 equally often
    for i: j = rand() scaled to 0..0x3FFF (_ftol2); if j < 0x4000: swap(rs_slot[i], rs_slot[j])
    for i: if rs_slot[i] ≥ n: rs_slot[i] = 0                      # never true
```

This is the zone's `RandomBox` (Z23 §8.6, zone ctor FUN_0063cdb0) compiled into the WM, plus the four 1000-boxes
`rb_thausend` that Z23 §8.6 does not mention. In the WM the only reader of `rndbox` is `RandomBox::rb_1000`
FUN_00467bc0 from `CKQServer::KQTeam_DivideRandom` FUN_00453540 (W04 §6.2 `KQ_AssignRandomTeams`), and `rb_1000` uses
only the Well512 member (W05 §6.4 table: `well512_GetRandom(1000)`). So the WM builds 105 shuffled 32 KB rings at start
(1.7 M `rand()` calls, 3.3 MB) that nothing reads; only the 16 `rand()` words of the Well512 seed matter, and they come
from `srand(_time32())`.

### 3.2 `ItemOptionsData itemoptiondata`, `rewarddata`, `fprewarddata` and the `CardDeck` lists: built, never loaded

```pseudo
`dynamic initializer for 'itemoptiondata'` FUN_00482780:
    BinaryData::BinaryData (FUN_00468cb0); vftable = ItemOptionsData::vftable
    iod_optionlist[500] = ItemOptionsData::OptionCardStack::OptionCardStack ×500       @ FUN_00467be0
        → CardDeck::CardStack::CardStack(&ocs_cardstack)                             @ FUN_00469790
            cs_deck = List<CardDeck::Card> (List::l_MakeList(1)); cs_Array = { la_Size 5, la_Array = new 0x14 }
            List::l_SetListArray(&cs_deck, &cs_Array)
    atexit(FUN_00482ac0)
`dynamic initializer for 'rewarddata'` FUN_00482750 (BinaryDataBox<ShineReward>), `'fprewarddata'` FUN_00482820
    (BinaryDataBox<FriendPointReward>): BinaryData ctor only
```

No WM function other than these initialisers, their atexit destructors and the unwind funclets references
`itemoptiondata`, `rewarddata` or `fprewarddata` (full scan of `wm-pdb/decomp.c`): no `ItemOptions.shn`,
`ShineReward.shn` or `FriendPointReward.shn` is read by the WM (W05 §3.2 lists every SHN it loads). They are the
zone's item-option / reward tables linked into the WM by a shared source file *(inferred)*; the zone side is Z24 / Z09.
Their destructors, all shutdown-only:

| Function | Body | Reached from |
|---|---|---|
| `ItemOptionsData::scalar_deleting_destructor` FUN_00467d50 | 500 × `OptionCardStack::~OptionCardStack` FUN_00467bf0, base vftable, `BinaryData::~BinaryData`, delete if flag 1 | vftable |
| `BinaryDataBox<ItemOptions>::~BinaryDataBox` FUN_00467c00 / `scalar_deleting_destructor` FUN_00467c10 | vftable, `BinaryData::~BinaryData` (+ delete) | unwind funclets FUN_00482400 / FUN_00482430; vftable |
| `BinaryDataBox<UseClassTypeInfo>` FUN_00465a10, `<FriendPointReward>` FUN_00467c40, `<ShineReward>` FUN_00467d20 `scalar_deleting_destructor` | same | vftable (`UseClassTypeInfo` is the live `CharClassDataBox`, W05 §3.2) |
| `BinaryData::scalar_deleting_destructor` FUN_00468ce0 | vftable, `CDataReader::~CDataReader`, delete if flag 1 | vftable |
| `CardDeck::CardStack::~CardStack` FUN_00469520 | delete `cs_Array.la_Array`, then `cs_deck.l_Array` | `OptionCardStack` dtor FUN_00467bf0 |
| `ListArray<CardDeck::Card>::~ListArray` FUN_004694d0 | delete `la_Array` | unwind funclet FUN_00482588 (`CardStack` ctor) |
| `ListEraser<CardDeck::Card>::~ListEraser` FUN_00467d10 | resets the base vftable | unwind funclet FUN_00482550 (`l_MakeList`) |
| `ListEraser<CardDeck::Card>::lid_Call` FUN_00467cf0 | calls slot 0x0C of `le_list` (the list's erase) with the index; returns 1 | vftable |
| `ListIteratorDefault<CardDeck::Card>::lid_Call` FUN_00467ce0 | returns 1 (visit everything) | vftable |

### 3.3 Destructors of live WM objects

| Function | What it does | Reached from |
|---|---|---|
| `CDataFileServer::~CDataFileServer` FUN_00403890 | `CDataReader::~CDataReader` of `m_AttendRewardData`, `m_AttendScheduleData`, `m_BadNameFilterData`, `m_GBHouseData`, `m_SpamerReportData` (W05 §3.2 rows; W04 §2.5 / §15 / §17.5) | `~WorldManagerServer` / ctor unwind funclets FUN_0047f4a4, FUN_0047f792 (W05 §1.6 shutdown) |
| `CDataReader::scalar_deleting_destructor` FUN_00458b50 | vftable; frees `m_pHead` (file buffer) if `m_nBFSize`, zeroes `m_pHead`, `m_pData`, `m_nBFSize`, `m_nFileCheckSum`; `delete[] m_pDataArray` if `m_nDataArraySize`; delete if flag 1 (W05 §3.1 `CDataReader`) | vftable |
| `CNpcScheduleServer::~CNpcScheduleServer` FUN_00456c20 | the same `CDataReader` teardown inlined for `enss_NpcScheduleData` (W04 §17.6) | `WorldManagerServer::~WorldManagerServer` FUN_00403920 and its ctor / dtor unwind funclets FUN_0047f488, FUN_0047f718 |
| `CNpcScheduleServer::NpcScheduleInfo::~NpcScheduleInfo` FUN_0043c190 | empty. COMDAT-folded: every empty destructor in the WM (`RandomSlot`, `Name5`, `cWell512Random`, packet rows …) is this one address, hence its 511 callers; the PDB name is that of one of the folded bodies | `_eh_vector_destructor_iterator_` everywhere |
| `PROTOCOLFUNCTIONTEMPLETE<T>::scalar_deleting_destructor`, T = `CParserAccountDB` FUN_00408210, `CParserAccountLogDB` FUN_00409260, `CParserCharDB` FUN_0040ed90, `CParserClient` FUN_00419610, `CParserGameLogDB` FUN_004242f0, `CParserLogin` FUN_004248d0, `CParserOPTool` FUN_00427330, `CParserZone` FUN_0042d440 | eight identical bodies: vftable; for each of the 1024 `pft_funcpnt[i]`, `delete[]` it unless it is `&pft_defaultdepartment`; delete `this` if flag 1. = the destructor of W05 §6.1 | vftable only (the parsers are `gServer` members, destroyed at exit) |
| `RaidSystem::~RaidSystem` FUN_004037e0 | 500 × `Raid::~Raid` (0x38 each; W02 §1.4 `g_Raids`) | `~WorldManagerServer` / ctor unwind funclets FUN_0047f46c, FUN_0047f6fc |
| `Raid::scalar_deleting_destructor` FUN_00462bf0 | vftable; delete if flag 1 | vftable |
| `CIOCP_Process_Interfece::scalar_deleting_destructor` FUN_0042ff80 | vftable (`Interfece` sic, PDB spelling); delete if flag 1 | vftable |
| `CIOCP_Process_LSession::~CIOCP_Process_LSession` FUN_0042fbb0 | resets the base vftable | unwind funclets of `CWMBaseSession::CWMBaseSession` FUN_00480919 and `CSocket_IOCP::CSocket_IOCP` FUN_00482290 (W05 §6.2) |
| `CMD5Checksum::~CMD5Checksum` FUN_0045e2c0 / `scalar_deleting_destructor` FUN_0045e2d0 | vftable (+ delete) | unwind funclet FUN_004821a0 of `CMD5Checksum::GetMD5` (the MD5 of W05 §3.1 / §6.3); vftable |
| `WinService::scalar_deleting_destructor` FUN_00466d80 | vftable; `String::~String(&serviceName)`; delete if flag 1 (the service wrapper of W05 §1.1 / §6.3) | vftable |
| `String::scalar_deleting_destructor` FUN_004671c0 | vftable; delete `chData` if set; delete if flag 1 | vftable |

### 3.4 Packet-builder destructors (stack objects of send functions)

Each is the unwind cleanup of one sender's stack packet: it runs the folded empty destructor over the packet's arrays,
so it does nothing; none changes the bytes sent.

| Function | Arrays destroyed | Owner (unwind funclet) and where the packet is documented |
|---|---|---|
| `PROTO_NC_DATA_SEND1<PROTO_NC_RAID_SLOT_MOVE_BROAD_CMD>::~…` FUN_0041a3b0 | 5 × 0x14 at +0x1F and at +0x83 | `CParserClient::fc_NC_RAID_SLOT_MOVE_REQ` (funclet FUN_004802a0); W02 §5.7 |
| `PROTO_NC_DATA_SEND1<PROTO_NC_RAID_MAKE_BROAD_CMD>::~…` FUN_0041a270 | 5 × 0x14 at +0x0D | `CParserClient::fc_NC_RAID_MAKE_REQ` (funclet FUN_0048026b); W02 §5.1 |
| `PROTO_NC_DATA_SEND2<PROTO_NC_RAID_MEMBER_LIST_CMD>::~…` FUN_00435a60 | 4 × 0x14 at +0x19, 20 × 0x15 at +0x7F | `CWMClientSession::SendRaidMember` (funclet FUN_00480d50); W02 §1.4 `Client_SendRaidMemberList` |
| `PROTO_NC_PARTY_MEMBER_LIST_CMD_SEND::~…` FUN_00419b90 | `memberarray` 5 × 0x16 | `CParserClient::SendPartyMemberList` (funclet FUN_00480150); W02 §1.3 (0x3809) |
| `PROTO_NC_DATA_SEND2<PROTO_NC_GUILD_TOURNAMENT_LIST_ACK>::~…` FUN_00445560 | 31 × 0x15 at +0x170 | `CGuildTournamentServer::Send_NC_GUILD_TOURNAMENT_LIST_ACK` (funclet FUN_004815e0); W03 §8.2 (0x747F) |

### 3.5 `Raid::iterator::operator!=` FUN_00462e60

```pseudo
Raid::iterator::operator!=(a, b)                                                    @ FUN_00462e60
    return not (a.m_pRaid != null and a.m_pRaid == b.m_pRaid
                and a.m_nPartyIndex == b.m_nPartyIndex and a.m_nSlot == b.m_nSlot)
```

The loop test of W02 §1.4's iterator (`Raid::Begin` {0,0} … `Raid::End` {4,0}); its six call sites are the member
loops of `WorldManagerServer::RaidLeaveLeader` FUN_00407430, `RaidLeaveSubLeader` FUN_00407620 and `RaidLeaveLooter`
FUN_00407800 (W02 §1.4, the 0xB02E broadcast to every raid member). Two iterators on a null raid compare unequal, so a
loop over a null raid would not end; the three callers check `GetRaid` ≠ null first.

### 3.6 MSVC runtime `type_info`

`type_info::_Type_info_dtor` FUN_0047017c (unlinks and frees the cached undecorated name under CRT lock 0xE),
`type_info::~type_info` FUN_00469ce3, `scalar_deleting_destructor` FUN_00469cf3, `type_info::operator==` FUN_00469d14
(`strcmp` of the decorated names): Visual C++ CRT code for RTTI, called only by the CRT and `dynamic_cast`/`typeid`.
No server behaviour; a rebuild does not reproduce it.

## Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| W06-B1 | CharDB 0x9828 → slot 0x4C (FUN_004484d0 → FUN_0045add0) | the academy notice from the DB answer is strcpy'd into a stack `PROTO_NC_GUILD_ACADEMY_NOTIFY_CMD` and then into `GUILD_ACADEMY_CLIENT.sNotify[512]`; `nNotifyLength` is not used, no bound (the request side is W03-B3) | a notice ≥ 512 bytes overruns the WM stack frame and the guild entry from +0x760 (academy reward money, graduate count, emblem fields) | copy at most `min(nNotifyLength, 511)` bytes and terminate |
| W06-B2 | client 0x7425 (FUN_006b3e00) | for 0x0D1C the generic `GetErrMsg` line is shown before "Please try later."; 0x0D1C has no `ErrMsgTable` entry | two lines, the first "An unidentified error code has occurred.: 3356" | exclude 0x0D1C from the generic message |
| W06-B3 | 0x7424 (FUN_0043e270) | a guild-less requester gets 0x0D1A, which the client has no text for; the client's "You have no joined guild" text is under 0x0D1B, which the WM sends when the guild entry is missing | generic "unidentified error: 3354" | send 0x0D1B for "no guild" (codes look swapped) *(inferred)* |
| W06-B4 | 0x7424 (FUN_0043e270) | error replies keep `PartMask = 1` from the packet template | the client clears its war-able list on every error, also on the 5 s throttle reply | send `PartMask = 0` on errors |

## Not reconstructed / uncertain

- The original names of the folded vftable slots (`CGuild` 0x04–0x10, 0x28; `CGuildMember` 0x00–0x14, 0x24;
  `CGuildAcademyMember` 0x0C): the folded bodies keep one PDB name; the 2017 client folds the same way. 0x24 / 0x0C as
  the LEAVE handlers and 0x28 as MONEY_SUB are *(inferred)* from the opcode order and the callers.
- The opcodes "not sent by the 2016 WM" (0x741F, 0x742B, 0x742C, 0x742E, 0x743A, 0x743B, 0x743C, 0x743F, 0x7442,
  0x9864, 0x9865, 0x9867): no send site in the WM or zone layouts; whether another server sends them was not checked.
- §3.1: the `rand()` → index scaling constant of `RandomSlot::rs_Init` (an `_ftol2` of a float product) was not read;
  it only shapes the shuffle of rings nothing in the WM reads. §3.2: that `itemoptiondata` / `rewarddata` /
  `fprewarddata` come from a source file shared with the zone is *(inferred)* from the identical classes there.

## Coverage boundary

(Filled by the sweep part.)
