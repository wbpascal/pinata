# World Manager: party and raid (expedition)

Source: `Files/Server/2016/w00_WorldManager/4WorldManagerServer2.exe` (2016), Ghidra export `re-data/exports/wm`.
Each block cites the function it was reconstructed from (`@ FUN_xxxxxxxx`). View the original with

```
python3 -I tools/protocol-re/clean.py re-data/exports/wm tools/protocol-re/names/wm 41a940
```

Names are ours unless they come from a string in the binary (`fc_NC_*` log texts, `RaidSystem::FindRaid`,
`Raid::AddMember`, `CWMClientSession::SendRaidMember`, the RTTI class `Raid`). Opcode and field names are the
official ones from the 2017 client PDB *(pdb2017)*; every field offset below was read in the 2016 WM code, so the
layouts themselves are plain facts, only the names come from the PDB. *(inferred)* marks behaviour deduced from
context. Payload offsets are from the start of the payload (after the 2-byte opcode). Client cross-references use
`re-data/client-handlers.json` (C01) and the client export; error texts come from `docs/protocol/client-error-codes.json`.
Core session handling (CheckAlive, sessions, blobs, map login) is in [`W01-core.md`](W01-core.md).

The WM is the owner of parties and raids. Zones only receive notifications (dept 14 / 44 `*_ZONE_*` and `*_CMD`
packets, broadcast to every zone) and send three requests (0x384E, 0x3860, 0x3861). There is no database storage:
parties and raids live in WM memory only and survive character logout, but not a WM restart.

---

## 1. Data structures

### 1.1 Client session fields used here (see W01-core §1.1 for the rest)

| Offset | Field (ours) | Notes |
|---|---|---|
| +0x114 / +0x116 / +0x117 / +0x118 | wmHandle / linking / zoneNo / zoneHandle | W01 |
| +0x560 | CHARDATA (+0 charNo, +4 name[20], +0x19 level, +0x42 map[12], +0x62 prison) | W01 |
| +0x568 | SHAPE blob; class = byte0 bits 2-6 | W01 |
| +0x638 | game block: u8, **+0x639 u16 partyNo**, **+0x63b u16 raidNo** (0xFFFF = none) | sent to zones in 0x1030; several paths clear both with one u32 write of 0xFFFFFFFF at +0x639 |
| +0x658 | single-option blob = `PROTO_NC_CHAR_SINGLE_OPTION_CMD` *(pdb2017)*; u32 at blob+10 = `nChatBan` ≠ 0 → raid chat goes back to the sender only (§5.12) | W01 §6.3 |
| +0x704 | inGame | W01 |
| +0x708.. | friends list (W04) | used by `Friends_SendPartyState` |
| +0x258c | KQ instance handle (`g_InstanceMaps`) | used by the "opposite team" check |
| +0x1df7c | guildNo | guild-only party maps (§1.6) |
| +0x1ecd0 | **pendingRaidInvite** (u16 raidNo, 0xFFFF = none) | set by 0xB00C on the invitee, cleared by 0xB00F |
| +0x1ecd4 | u32 loggingOut: 1 while 0x0C18 NC_USER_NORMALLOGOUT_CMD runs the logout (`Client_NormalLogout_0C18` FUN_00412df0 sets it before `CharacterLogout` and clears it after; FUN_00434300 resets it) | raid code skips such members when counting online members and sending 0xB020 |

### 1.2 Party registry `g_Parties` (DAT_0055e128 = g_WM + 0xc4100)

```
g_Parties { PARTY *slots (malloc 4000 × 0xd0) ; int activeCount ; int nextHint }      @ FUN_004657c0
PARTY (0xd0 bytes, index = partyNo 0..3999)
  +0x00 u8  memberCount (0..5)
  +0x04 PARTY_MEMBER members[5] (0x24 each; members[0] is the master)
  +0xb8 PARTY_LOOT loot
  +0xcc u8  (not used here)
  +0xcd u8  reservedForRaid   1 = slot belongs to a raid (counts as active even with 0 members)
PARTY_MEMBER (0x24) = PROTO_PARTY_MEMBER_AND_ZONEMERCHINE (0x20, pdb2017) + 4
  +0x00 u32 chrregnum (-1 = empty)   +0x04 u16 zonecharhandle   +0x06 u16 wmcharhandle
  +0x08 char charname[20]   +0x1c u8 level   +0x1d u8 flag   +0x1e u8 charclass   +0x1f u8 ZoneMerchineNo
  +0x20 u32 (unused)
  flag bit 0 = "invited, not yet accepted" (we call such a member *pending*; the others *confirmed*)
PARTY_LOOT (0x14; also used by RAID +0x24)
  +0x00 u32 lootType[4]   one per item grade 0 regular, 1 named, 2 rare/set, 3 unique (client texts)
                          type 0 free for all, 1 alternating, 2 particular person (the looter), 3 dice (client texts)
  +0x10 u32 looterCharNo  (-1 after init; set to the master when a party is created)
```

A party slot is *active* when `memberCount != 0 or reservedForRaid == 1`. Most functions treat a non-active slot as
"no party". Session `partyNo` is a cache of "the slot that contains my charNo"; it is re-derived on map login.

Registry operations (all return codes are ours to read; the client never sees them directly):

```pseudo
Parties_NextFreeSlot():                       @ FUN_00464780
    from nextHint, first slot that is neither active nor reserved (wraps at 4000); none → 0xFFFF; nextHint = slot+1

Parties_Invite(masterRec, memberRec, masterPartyNo) → partyNo or error     @ FUN_004651b0
    if masterPartyNo >= 4000: masterPartyNo = Parties_NextFreeSlot(); 0xFFFF → return 0xFFFF
    p = Parties_FindByCharNo(master.charNo)                                 @ FUN_004648a0 (linear search, all 4000)
    if p found: return p == masterPartyNo ? Party_AddMember(p, memberRec) : 0xFFF9
    if member already in any party: return 0xFFFE
    new party: count = 2, members[0] = master, members[1] = member, members[2..4].charNo = -1,
               loot = {0,0,0,0, looter = master.charNo}, activeCount++ ; return masterPartyNo

Party_AddMember(partyNo, rec) → partyNo or error                            @ FUN_00464fa0 (return values read in the assembly)
    partyNo >= 4000 → 0xFFF9 ; slot not active → 0xFFFA ; memberCount > 4 → 0xFFFB
    rec.charNo or rec.name (case-insensitive) already in this party → 0xFFFD
    rec.charNo in any other party → 0xFFFE
    members[count++] = rec ; return partyNo

Party_RemoveMember(partyNo, charNo) / Party_RemoveMemberByName(partyNo, name)   @ FUN_004652c0 / FUN_00465420
    4 = no party, 3 = not a member
    shift the later members down, count--, clear the freed slot
    raid party (reservedForRaid = 1) → 0 (a raid party is never dissolved here)
    count <= 1 after removal → slot freed (count = 0, activeCount--) → 2   # the last member is dropped silently
    else → 1 if the removed member was the master (index 0), 0 otherwise

Party_GetRole(partyNo, charNo) / Party_GetRoleByName(partyNo, name)       @ FUN_00464b70 / FUN_00464c10
    4 no party, 3 not a member, 0 raid party, 2 party has fewer than 3 members (leaving dissolves it),
    1 member is the master, 0 ordinary member
Party_ConfirmMember(partyNo, charNo)                                       @ FUN_004649c0
    member pending → clear its flag and members[0].flag, return 0 ; already confirmed → 1 ; not found → 2 (log)
Party_IsPending(partyNo, charNo) = member.flag & 1                          @ FUN_00464ce0
Party_CountConfirmed(partyNo)                                              @ FUN_00464df0
Party_IsMaster(partyNo, charNo) = members[0].charNo == charNo              @ FUN_00464f10
Party_IndexOfCharNo / Party_IndexOfName → index, -2 not found, -1 bad no   @ FUN_00464ec0 / FUN_00464e40
Party_MakeMaster(partyNo, charNo): swap that member with members[0]        @ FUN_004655b0
Parties_SwapMembers(pA, iA, pB, iB): swap two member records (raid slot move)   @ FUN_00465720
Parties_ReserveSlot(&no): take a free slot, mark reservedForRaid, members[*].charNo = -1 → 0xFFF8 ok   @ FUN_00464910
Parties_Release(no): clear count and reservedForRaid, activeCount--          @ FUN_00464850
Party_CheckLevelGap(partyNo, myLevel, targetLevel)                         @ FUN_00464ad0
    min/max level of the members (or myLevel when no party); ok if |min-target| <= 1000 and |max-target| <= 1000
    # levels are u8, so this never fails in 2016: the level-gap rule (error 0x4D1) is disabled by the 1000 limit (original bug) W02-B6
PartyLoot_SetType(loot, grade, type):  grade > 3 or type > 3 → false;      @ FUN_004646f0
    lootType[0..grade-1] = 0 ; lootType[grade..3] = type ; true
```

### 1.3 Party send helpers

```pseudo
Party_SendMemberList(partyNo, to):                                          @ FUN_0041b050
    to ← 0x3809 NC_PARTY_MEMBER_LIST_CMD { u8 membercount, n × MEMBER_INFO { charname[20], u8 memberstatus, u8 charclass } }
         confirmed members only; memberstatus = 1 if that member's session (by wmHandle) is in game with the same charNo
Party_SendLooterInfo(partyNo, to):                                          @ FUN_0041b200
    to ← 0x385F NC_PARTY_ITEM_JOIN_LOOTING_CMD { u8 nItemGrade = first grade with lootType != 0 (else 0),
                                                 u8 nLootingType = that type, LooterName[20] = looter's member name }
Party_SendLeave(partyNo, leaver):                                           @ FUN_0041b350
    all zones ← 0x380C NC_PARTY_LEAVE_CMD { u16 partyregnum, PROTO_PARTY_MEMBER leavemember }
        (chrregnum, zonecharhandle, wmcharhandle, charname set; flag = 0; level/charclass not initialised) (original bug) W02-B10
    every confirmed online member (leaver included) ← 0x380B NC_PARTY_LEAVE_ACK { memberid = leaver name, u16 err = 0x501 }
Party_SendKickoff(partyNo, name):                                           @ FUN_0041b9d0
    m = member with that name; all zones ← 0x3816 NC_PARTY_KICKOFF_CMD { u16 partyregnum, u32 kickoffmemberregnum }
    every confirmed online member (the kicked one included) ← 0x3815 NC_PARTY_KICKOFF_ACK { memberid = name, err = 0x541 }
Party_SendMasterChanged(partyNo):                                           @ FUN_0041b630
    master = members[0]; only if master's session is valid:
    all zones ← 0x382A NC_PARTY_CHANGEMASTER_CMD { u16 partyregnum, u32 newmaster_chrregnum }
    every confirmed online member ← 0x3829 NC_PARTY_CHANGEMASTER_ACK { newmaster = master name, err = 0x548 }
Party_EnsureLooter(partyNo):                                                @ FUN_0041b4d0
    if looter is still a member: return
    looter = members[0]
    every online member ← 0x385D NC_PARTY_SET_LOOTER_BROAD_CMD { sCommandCharID = master name, sNewLooterCharID = master name }
    all zones ← 0x385E NC_PARTY_ZONE_SET_LOOTER_CMD { u16 nPartyNo, u32 nNewLooterCharNo }
Party_SendLogin(partyNo, charNo):   confirmed member → all zones ← 0x383C NC_PARTY_LOGIN_CMD { u16 partyregnum, u32 chrregnum }   @ FUN_004132c0
Party_SendLoginInfo(partyNo, charNo): every confirmed online member ← 0x383D NC_PARTY_LOGININFO_CMD { memberid }   @ FUN_0041c3b0
Party_SendLogout(partyNo, charNo):  member → all zones ← 0x3846 NC_PARTY_LOGOUT_CMD { u16 partyregnum, u32 chrregnum }   @ FUN_00413340
Party_SendLogoutInfo(partyNo, charNo): confirmed online members except charNo ← 0x3847 NC_PARTY_LOGOUTINFO_CMD { memberid }   @ FUN_0041c4e0
Friends_SendPartyState(s):  each online friend ← 0x540E NC_FRIEND_PARTY_CMD { name[20], u8 inParty }   @ FUN_00435ee0 (W04 owns the friend list)
```

"Online member" everywhere = `Clients_GetByHandle(member.wmcharhandle)` exists and its CHARDATA.charNo equals the
member's charNo (the stored handle may be stale after a relog; that is why most loops re-check the charNo).

### 1.4 Raid registry `g_Raids` (DAT_006bdf60 = g_WM + 0x223f38), class `Raid` (RTTI)

```
g_Raids = Raid[500] (0x38 each)                                             @ FUN_00462f70 / ctor FUN_00462ba0
Raid (0x38)
  +0x00 vftable   +0x04 u16 raidNo (= slot index; 0xFFFF = free)   +0x06 u8 memberCount
  +0x08 u16 partyNo[4]          the 4 parties of the raid (party slots with reservedForRaid = 1)
  +0x10 u32 leaderCharNo        +0x14 u32 subLeaderCharNo[4] (-1 = none)
  +0x24 PARTY_LOOT loot         (same layout as PARTY +0xb8)
DAT_006d6470 = &g_Parties (set at startup, FUN_00462b00)
```

A raid holds up to 20 members as 4 parties × 5 slots. Members are addressed by *position* `{partyIndex 0..3,
slotIndex 0..4}`; the matching `nPartyNo` is `partyNo[partyIndex]`. An iterator `{Raid*, partyIndex, slotIndex}`
walks all 20 positions (`Raid_Begin` = {0,0}, `Raid_End` = {4,0}, next = slot+1, after slot 4 the next party)
@ FUN_00462c20 / FUN_00462c40 / FUN_00462a90; positions past a party's member count read charNo -1.

```pseudo
Raids_Get(raidNo): raidNo < 500 → &g_Raids[raidNo], else log "RaidSystem::FindRaid : INVALID RAID SLOT INDEX : %d", null   @ FUN_00462b10
Raids_Create(firstPartyNo, &err) → Raid*                                    @ FUN_00462fb0 (return read in the assembly)
    err = 0x1E80; no party registry → 0x1EC1; firstPartyNo == 0xFFFF → 0x1E84
    raid = first free slot (raidNo == 0xFFFF); none → null, err stays 0x1E80   # client gets the success code (original bug) W02-B5
    reserve 3 more party slots (Parties_ReserveSlot); any failure → release the ones taken, err 0x1E85, null
    Raid_Init(slot, {firstPartyNo, r1, r2, r3}, &err)                        @ FUN_00462c60
        raid slot already used → 0x1EC2; raidNo = slot; memberCount = parties[first].memberCount
        leader = looter = parties[first].members[0].charNo; loot types = 0; all 4 party slots reservedForRaid = 1
        a party slot that cannot be read → 0x1E86 and the raid is reset
Raids_FindByCharNo(charNo) → raidNo or 0xFFFF (scan all 500 × 20)           @ FUN_00463100
Raid_Find(raid, charNo) → position, or End when not found                   @ FUN_004632d0 (charNo -1 = first free position)
Raid_AddMember(raid, rec, &err):                                            @ FUN_00463370
    pos = first free position (charNo -1); none → 0x1F45 "It's not possible to accept more expedition members."
    Party_AddMember(partyNo[pos.partyIndex], rec) != that partyNo → 0x1F46 ; memberCount++
    (bad party index: log "Raid::AddMember : INVALID PARTY INDEX :")
Raid_RemoveMember(raid, charNo, &err):                                      @ FUN_00463650
    not in raid → 0x1F48; party unreadable → 0x1E86
    Party_RemoveMember result → Raid_PartyRemoveError: 0/1 ok, 2 → 0x1F4C, 3 → 0x1F4D, 4 → 0x1F4E, other 0x1F42   @ FUN_004629e0
    memberCount--
Raid_MoveMember(raid, charNo, dstPartyIndex, dstSlot, &err):  (into a free slot)   @ FUN_00463460
    not in raid 0x1F48; dstPartyIndex > 3 or dstSlot > 4 → 0x1F49; party unreadable 0x1F4A
    dstSlot < dst party memberCount (slot taken) → 0x1F4B
    remove from own party, Party_AddMember(dst party) (appended at its end) ; failure → 0x1F46
Raid_SwapMembers(raid, charA, charB): both in raid → Parties_SwapMembers(...)    @ FUN_00463720
Raid_Dismiss(raid, &err):                                                   @ FUN_004631c0
    remove every member from its party (errors → 0x1F41 or the remove error), release the 4 party slots,
    reset raidNo/partyNo/leader/subLeaders/loot
Raid_CanInvite(raid, charNo, &err): leader or sub-leader, else 0x1F44        @ FUN_00462930
Raid_SetLeader(raid, charNo): member and not the current leader → leader = charNo; if it was a sub-leader, that
    sub-leader entry is cleared                                             @ FUN_004638e0
Raid_AddSubLeader(raid, charNo, &err): not a member 0x1F08; already sub-leader 0x1F0C; 4 already → 0x1F0B   @ FUN_004637d0
Raid_DelSubLeader(raid, charNo, &err): not a sub-leader → 0x1F0A            @ FUN_00462980
Raid_SetLooter(raid, charNo): member and not already the looter             @ FUN_00463880
```

Session-level raid helpers:

```pseudo
Client_IsInRaid(s): Raids_Get(s.raidNo) and Raid_Find(raid, charNo) != End  @ FUN_00431240
    # used as "busy" check: party actions refuse with it (0x4C2, 0x544) and party code is skipped for raid members
Client_CanJoinRaid(t, &err):                                                @ FUN_00431140
    t.raidNo != 0xFFFF → 0x1EC8 ; t is a pending party invitee → 0x1EC7 ; t.partyNo != 0xFFFF → 0x1EC8
    t.linking → 0x1EC9 ; Zones_GetCanParty(t.map) == 0 → 0x1ECA ; t prison → 0x1ECB ; else 0x1E80 ok

Raid_HandOverRoles(raid, leavingCharNo):                                    @ FUN_004313f0
    if leaving is the leader:
        new = first online sub-leader (iteration order) ≠ leaving; else first online member ≠ leaving
        Raid_SetLeader(new); Raid_BroadcastSetLeader(raidNo, leaving, new)
    if leaving is a sub-leader: Raid_DelSubLeader; Raid_BroadcastDelSubLeader(raidNo, leaving, …)
    if leaving is the looter: looter = leader; Raid_BroadcastSetLooter(raidNo, leaving, leader)
Raid_BroadcastSetLeader:  online members ← 0xB02E NC_RAID_SET_LEADER_BROAD_CMD { sCommandCharID = "" , sNewLeaderCharID,
        u16 nPartyNo, u8 nPartyIndex, u8 nSlotIndex } ; all zones ← 0xB02F NC_RAID_ZONE_SET_LEADER_CMD
        { u16 nRaidNo, u32 nNewLeaderCharNo, u16 nPartyNo, u8 nPartyIndex, u8 nSlotIndex }   @ FUN_00407430
Raid_BroadcastDelSubLeader: 0xB038 { sCommandCharID = "", sDelSubLeaderCharID, position } + zones 0xB039   @ FUN_00407620
Raid_BroadcastSetLooter:  0xB03D { sCommandCharID = leader name, sNewLooterCharID, position } + zones 0xB03E   @ FUN_00407800

Raid_DismissIfEmpty(raidNo):                                                @ FUN_004312b0
    online = members in game with CHARDATA and not loggingOut (+0x1ecd4 != 1)
    if online > 1: return
    leaderSession = Clients_FindByCharNo(leader)
    Raid_Dismiss(raid); on success:
        if leaderSession: leaderSession.partyNo = raidNo = 0xFFFF; leaderSession ← 0xB006 NC_RAID_DISMISS_BROAD_CMD (empty)
        all zones ← 0xB007 NC_RAID_ZONE_DISMISS_CMD { u16 nRaidNo }
    # only the leader is told; the one remaining member (if not the leader) keeps a stale raidNo/partyNo (original bug) W02-B7
    #   until its next map login re-derives them (inferred)

Client_SendRaidMemberList(s):                                               @ FUN_00436170 ("CWMClientSession::SendRaidMember")
    s ← 0xB005 NC_RAID_MEMBER_LIST_CMD (0x21E bytes; long header {0x00, u16 len 0x220, opcode})
        { Leaderid[20], SubLeaderid[4][20], Looterid[20], u8 nItemGrade, u8 nLootingType,
          memberarray[20] { memberid[20], u8 memberstatus (1 = in game) } }   # 20 positions in iterator order; empty = ""
        nItemGrade/nLootingType = first grade with a non-zero loot type
```

### 1.5 Party finder `g_PartyFinder` (DAT_0055e134 = g_WM + 0xc410c)

Linked list `{ int count; ENTRY *head; ...; CRITICAL_SECTION @+0xc; int locked @+0x24 }`, entries 0xA4 bytes
(the first 0x9A are `PROTO_NC_PARTY_FINDER_INFO` *(pdb2017)*):
`+0 u16 nPastSecond (always 0), +2 time32 dRegistTime, +6 sCharID[20], +0x1A sMsg[128], +0xA0 next`.

```pseudo
PartyFinder_AddOrUpdate(name, msg) → 0 added, 1 updated                    @ FUN_00457750 (return read in the assembly)
    entry for name exists: dRegistTime = now, msg replaced (127 chars + NUL) → 1 ; else append a new entry → 0
PartyFinder_Delete(name) → 1 deleted, 0 not found                           @ FUN_00457540 / FUN_0045d670
PartyFinder_ExpireTick():  (called from the WM main tick)                    @ FUN_004575c0
    every 11 s: entries with now - dRegistTime >= 1800 s are removed; the owner, if in game,
    gets 0x3856 NC_PARTY_FINDER_DELETE_YOUR_MSG_CMD (empty; the client ignores it)
On character logout and rename: entry deleted / renamed (W01 CharacterLogout, FUN_00431dd0 CharIDChange,
    log "DEBUG - CWMClientSession::CharIDChange : PartyFinder - sOldCharID(%s)")
```

### 1.6 Map flags from the zones' map registration

Zones register maps with 0x180F NC_MAP_REGIST_CMD; each 14-byte entry is
`{ u8 canparty, Name3 mapname, u8 IsPartyReleaseMap }` *(pdb2017 names; W01 read the layout)*. The WM keeps
`canparty` at map-table entry +2 and `IsPartyReleaseMap` at +0xF.

- `Zones_GetCanParty(map)` @ FUN_00439320: 0 = no party actions on that map (unknown map = 0), 1 = normal,
  **2 = guild-only**: party invitations and raid invitations involving such a map need both characters in the same
  non-zero guild (errors 0x4D6 / 0x1ED0). (Values 1/2 read from the checks; their source data is the zone's.)
- `Zones_IsPartyReleaseMap(map)` @ FUN_00439380: entering such a map makes the character leave its party or raid (§4.1).

Two more cross-checks used by invitations:
- `Client_SameKQTeam(a, b)` @ FUN_00433740: if neither is in a kingdom-quest instance → ok; else both must be on the same
  team (`g_InstanceMaps` FUN_00453630). The 0x3860 log text for this check is "Kingdom Quest Team". Errors 0x4DA /
  0x1ED4 ("You cannot party/make expedition with opposite team").
- `Client_GetPrison(s)` @ FUN_00409a10: CHARDATA +0x62 (non-zero = in prison, log text "psiaon").

---

## 2. Party: client handlers (CParserClient, dept 14)

All handlers start with `Client_CheckAlive` (W01). Replies are raw packets `{len, opLo, opHi, payload}`.
Error/result codes and client texts are in §7.

### 2.1 0x3802 NC_PARTY_JOIN_REQ { char target[20] }  (invite)

```pseudo
Client_PartyJoinReq(s, p):                                                  @ FUN_0041a940
    reply(err) = s ← 0x3807 NC_PARTY_JOIN_ACK { memberid = p.target, u8 charclass (not set), u16 err }
    if s.partyNo != 0xFFFF:
        n = Party_GetMemberCount(s.partyNo); invalid → reply 0x4CC ; n >= 5 → reply 0x4C9
    if CHARDATA.prison != 0 or Zones_GetCanParty(my map) == 0: reply 0x4D2
    t = Clients_FindByCharName(p.target)                                    @ FUN_004378a0
    if !t or t.zoneHandle == 0xFFFF or !t.CHARDATA or !t.SHAPE or t == s: reply 0x4C5
    if !Party_CheckLevelGap(s.partyNo, myLevel, t.level): reply 0x4D1       # never fails (§1.2)
    if Party_IsPending(t.partyNo, t.charNo): reply 0x4CB                    # t is answering another invitation
    if t.partyNo != 0xFFFF: reply 0x4C4
    if t.linking: reply 0x480                                               # no client text for 0x480
    if Zones_GetCanParty(t map) == 0: reply 0x4D2
    if Client_GetPrison(t): reply 0x4D3
    if (canparty(my map) == 2 or canparty(t map) == 2) and (guilds differ or either is 0): reply 0x4D6
    if !Client_SameKQTeam(s, t): reply 0x4DA
    master = { charNo, zoneHandle, wmHandle, name, level, flag = 1, class, zoneNo } of s
    member = same of t, flag = 1
    r = Parties_Invite(master, member, s.partyNo)
    switch r:
        0xFFF9, 0xFFFE → reply 0x4C4     0xFFFA → reply 0x4CE     0xFFFB → reply 0x4C9
        0xFFFD → reply 0x4CF             0xFFFF → reply 0x4CD
        else: s.partyNo = t.partyNo = r
              t ← 0x3803 NC_PARTY_JOINPROPOSE_REQ { mastername = s name }     # no reply to the inviter on success
```

Notes: a brand-new party has *both* the master and the invitee pending (flag 1) until the invitee accepts; the
invitee's session already carries the partyNo while it decides. The client opens the invitation dialog on 0x3803
(`FUN_004a29d0`).

### 2.2 0x3804 NC_PARTY_JOINPROPOSE_ALLOW_ACK (no payload; accept)

```pseudo
Client_PartyJoinProposeAllow(s):                                            @ FUN_004211e0
    reply(err, name) = s ← 0x3807 { memberid = name, charclass, err }
    pn = s.partyNo
    if pn invalid or !s.CHARDATA: reply(0x4C7, "")
    m = Clients_GetByHandle(party.members[0].wmHandle)
    if !m or m.charNo != members[0].charNo:                                 # master gone
        Party_RemoveMember(pn, s.charNo); s.partyNo = 0xFFFF; return (no reply)
    if !Client_SameKQTeam(s, m): reply(0x4DA, "")
    if Client_IsInRaid(m): reply(0x4C2, "")
    switch Party_ConfirmMember(pn, s.charNo):
      1 (already confirmed): m ← 0x3807 { s name, 0x4CF }; reply(0x4CF, m name)
      2 (not found):         m ← 0x3807 { s name, 0x4C7 }; reply(0x4C7, m name)
      0 (was pending → now confirmed, master confirmed too):
        if Party_CountConfirmed(pn) == 2:                                   # the party is born
            all zones ← 0x3801 NC_PARTY_FUNDAMENTAL_CMD { u16 partyregnum, master, member }
                (PROTO_PARTY_MEMBER_AND_ZONEMERCHINE each: charNo, zoneHandle, wmHandle, name, level, flag 0, class, zoneNo)
            Friends_SendPartyState(m); Friends_SendPartyState(s)
            Party_SendLooterInfo(pn, m)
        else:
            all zones ← 0x3808 NC_PARTY_JOIN_CMD { u16 partyregnum, joiner (same record) }
            Friends_SendPartyState(s)
        every confirmed online member ≠ s ← 0x3807 { memberid = s name, charclass = s class, err = 0x4C1 }
        Party_SendLooterInfo(pn, s); Party_SendMemberList(pn, s)
```

Client: 0x3807 with 0x4C1 adds the member to the party window, prints "%s has joined the party." and sends
0x3848 NC_PARTY_MEMBERINFOREQ_CMD (to the zone); any other code prints `ErrMsgTable(err)` with the name
(`FUN_004ac300`). The joiner never receives 0x3807 for itself; it learns the party from 0x3809.

### 2.3 0x3805 NC_PARTY_JOINPROPOSE_REJECT_ACK (no payload)

```pseudo
Client_PartyJoinProposeReject(s):                                           @ FUN_00419bb0
    pn = s.partyNo; s.partyNo = 0xFFFF
    if pn invalid or !s.CHARDATA: return
    m = master session (members[0], charNo-checked); gone → Party_RemoveMember(pn, s.charNo); return
    role = Party_GetRole(pn, s.charNo)
    if role < 2:  m ← 0x3807 { s name, 0x4C6 "%s has rejected the party invitation." }
    if role == 2: m ← 0x3807 { s name, 0x4C6 }; m.partyNo = 0xFFFF       # the 2-member draft party dissolves
    Party_RemoveMember(pn, s.charNo)
```

There is no server-side timeout for an unanswered invitation (NC_PARTY_JOINPROPOSE_TIMEOUT_ACK 14/6 has no WM
handler); the pending member stays until reject, accept, logout (§4.2) or a new 0x3802 hits 0x4CB *(inferred)*.

### 2.4 0x380A NC_PARTY_LEAVE_REQ (no payload) and the shared leave routine

```pseudo
Client_PartyLeaveReq(s): Party_Leave(s)                                     @ FUN_0041b990

Party_Leave(s) → 1:                                                         @ FUN_0041b7d0
    if Client_IsInRaid(s): return                                            # raid members leave via 0xB014
    pn = s.partyNo; s.partyNo = 0xFFFF; Friends_SendPartyState(s)
    if pn invalid or !s.CHARDATA: return
    switch Party_GetRole(pn, s.charNo):
      0 (member, ≥3 in party): Party_SendLeave(pn, s)
      1 (master, ≥3 in party): Party_SendLeave(pn, s); Party_RemoveMember(pn, s.charNo)
                               Party_SendMasterChanged(pn)                   # members[1] moved up to master
                               Party_EnsureLooter(pn); return
      2 (2 members → dissolve): Party_SendLeave(pn, s)
                               all zones ← 0x381F NC_PARTY_DISMISS_CMD { u16 partyregnum }
                               every other member session (by handle, not charNo-checked) (original bug) W02-B8 ← partyNo = 0xFFFF,
                                   0x381E NC_PARTY_DISMISS_ACK (empty), Friends_SendPartyState
      3: log
    Party_RemoveMember(pn, s.charNo); Party_EnsureLooter(pn)
```

Also called from 0x3861 (§3.3) and from map login on a party-release map (§4.1). Client: 0x380B with the own
name → "You have left the party." and clears the party UI; other name → "%s has left the party." (`FUN_004ac420`).

### 2.5 0x3814 NC_PARTY_KICKOFF_REQ { char member[20] }

```pseudo
Client_PartyKickoffReq(s, p):                                               @ FUN_0041bb40
    reply(err) = s ← 0x3815 NC_PARTY_KICKOFF_ACK { memberid = p.member, err }
    if Client_IsInRaid(s): reply 0x544                                       # client shows nothing for 0x544
    t = Clients_FindByCharName(p.member)                                     # may be null (offline member)
    pn = s.partyNo; invalid → reply 0x543 "You are not in a party."
    if !Party_IsMaster(pn, s.charNo): reply 0x546 "Kick option is available only to Party Leader."
    switch Party_GetRoleByName(pn, p.member):
      3: reply 0x542 "Selected player is not a party member."      4: reply 0x543
      1 (the master kicks himself): Party_SendKickoff(pn, name); Party_RemoveMemberByName
            Party_SendMasterChanged(pn); Party_EnsureLooter(pn); return
      2 (2-member party): Party_SendKickoff(pn, name)
            all zones ← 0x381F { pn }
            every member session (charNo-checked): partyNo = 0xFFFF; if its name != p.member:
                ← 0x381E NC_PARTY_DISMISS_ACK, Friends_SendPartyState
      0: Party_SendKickoff(pn, name)
    r = Party_RemoveMemberByName(pn, p.member)
    if r < 3 and t: t.partyNo = 0xFFFF; Friends_SendPartyState(t)
    Party_EnsureLooter(pn)
```

Client (`FUN_004ac600`): 0x541 with the own name → "You have been banned from the party." and clears the party;
other name → "%s has left the party."; 0x542/0x543/0x546 → the texts above.

### 2.6 0x3828 NC_PARTY_CHANGEMASTER_REQ { char newmaster[20] }

```pseudo
Client_PartyChangeMasterReq(s, p):                                          @ FUN_0041bf10
    reply(err) = s ← 0x3829 NC_PARTY_CHANGEMASTER_ACK { newmaster = p.newmaster, err }
    pn invalid → reply 0x549
    i = Party_IndexOfName(pn, p.newmaster); < 0 → reply 0x542
    if !Party_IsMaster(pn, s.charNo): reply 0x543
    if Party_MakeMaster(pn, members[i].charNo): Party_SendMasterChanged(pn)  # 0x382A to zones, 0x3829 0x548 to members
```

Client (`FUN_004ac860`): 0x548 → "You became the Party Leader." / "% became the Party Leader." (sic) (original bug) W02-B12 and updates the
window; 0x542/0x549 → "Selected player is not a party member."; 0x543 → "Adjustment is available to Party Leader only."
The new master need not be online; the looter is not changed.

### 2.7 0x384B NC_PARTY_ITEM_LOOTING_SET { u8 lootingtype, u8 nItemGrade }

```pseudo
Client_PartyItemLootingSet(s, p):                                           @ FUN_004130f0
    silent unless: CHARDATA, valid partyNo, !Client_IsInRaid(s), s is members[0]
    if !PartyLoot_SetType(party.loot, grade = p.nItemGrade, type = p.lootingtype): return
    all zones ← 0x384D NC_PARTY_ITEM_LOOTING_ZONE_CMD { u16 partyregnum, u8 nItemGrade, u8 nLootingType, u32 LooterNo }
    every confirmed online member ← 0x384C NC_PARTY_ITEM_LOOTING_CMD { u8 LootType, u8 ItemGrade }
```

Client (`FUN_004ac990`): "Item acquisition of %s items has been changed to: free for all / alternating / a particular
person" or the dice text, for grade names Regular / Named / Rare-set / Unique item level.

### 2.8 0x385A NC_PARTY_SET_LOOTER_REQ { char sNewLooterCharID[20] }

```pseudo
Client_PartySetLooterReq(s, p):                                             @ FUN_0041c0b0
    silent unless: valid partyNo, !Client_IsInRaid(s), s is members[0]
    t = Clients_FindInGameByCharName(p.sNewLooterCharID)                    @ FUN_00437720
    if !t: s ← opcode 0xB05B { "", 0x559 } ; return
    if party.looter == t.charNo: s ← opcode 0xB05B { "", 0x55A } ; return
    party.looter = t.charNo                                 # t is NOT checked to be a party member (original bug) W02-B2
    s ← 0x385B NC_PARTY_SET_LOOTER_ACK { sNewLooterCharID = t name, u16 nError = 0x558 }
    t ← 0x385C NC_PARTY_SET_LOOTER_CMD { sCommandCharID = s name }   "{%s designated you to be in charge.}"
    every online member ← 0x385D NC_PARTY_SET_LOOTER_BROAD_CMD { sCommandCharID = s name, sNewLooterCharID = t name }
    all zones ← 0x385E NC_PARTY_ZONE_SET_LOOTER_CMD { u16 nPartyNo, u32 nNewLooterCharNo }
```

The two error replies are built with opcode bytes `5B B0` (0xB05B, dept 44 cmd 91: no such opcode) instead of
0x385B, so the client never displays 0x559 "{The character designated to take the loot can not be found.}".
(original bug) W02-B1 A re-implementation that wants client-visible errors would send 0x385B.

### 2.9 Party finder: 0x3850 / 0x3852 / 0x3854

```pseudo
0x3850 NC_PARTY_FINDER_ADD_REQ { char sMsg[128] }:                         @ FUN_00415a30
    !CHARDATA → s ← 0x3851 NC_PARTY_FINDER_ADD_ACK { u16 Error = 0x551 }
    r = PartyFinder_AddOrUpdate(my name, sMsg): 0 → Error 0x552 (added), 1 → 0x553 (updated)
    # the client ignores the code and refreshes the list (sends 0x3854 { current page, 20 })
0x3852 NC_PARTY_FINDER_DELETE_REQ (no payload):                            @ FUN_00415ad0
    !CHARDATA → 0x3853 NC_PARTY_FINDER_DELETE_ACK { Error = 0x554 }
    PartyFinder_Delete(my name): 1 → 0x555 (deleted), 0 → 0x554 (not registered)
    # client: only 0x555 is handled (removes its own row, refreshes)
0x3854 NC_PARTY_FINDER_LIST_REQ { u16 nPageNo, u8 nCountOfOnePage }:     @ FUN_0041a080
    silent if nCountOfOnePage == 0 or !CHARDATA
    s ← 0x3855 NC_PARTY_FINDER_LIST_ACK { u16 nPageNo, u8 nCountOfOnePage, u8 bYouAreRegisted,
            u16 nMaxPages = ceil(count / nCountOfOnePage), u16 nNumOfList,
            InfoList[nNumOfList] (PROTO_NC_PARTY_FINDER_INFO, 0x9A each) }
        entries start at index nPageNo × nCountOfOnePage; at most nCountOfOnePage, and the payload stays < 8000 bytes
```

---

## 3. Party: zone and OPTool handlers

### 3.1 0x384E NC_PARTY_MEMBERINFORM_REQ { u16 partyregnum }  (CParserZone and CParserOPTool)

```pseudo
Zone_PartyMemberInformReq(z, p):   @ FUN_0042d5a0   (OPTool copy @ FUN_004274e0, OPTool_CheckAlive FUN_00424c70)
    z ← 0x384F NC_PARTY_MEMBERINFORM_ACK { u16 PartyRegnum, u8 NumberOfMember,
            Member[n] (PROTO_PARTY_MEMBER, 0x1F each: chrregnum, zonecharhandle, wmcharhandle, charname, level, flag, charclass) }
        confirmed members only; partyregnum >= 4000 → 0 members
```

### 3.2 0x3860 NC_PARTY_ZONE_JOIN_CMD { u32 nMasterCharNo, u32 nJoinCharNo }

A zone-driven join without invitation (the joiner is confirmed at once). Every refusal is only logged
(`fc_NC_PARTY_ZONE_JOIN_CMD : …`); nobody is told.

```pseudo
Zone_PartyZoneJoin(z, p):                                                   @ FUN_0042e8c0
    refuse (log) when: same charNo ("same charregno"); master / joiner session missing ("session null"),
        zoneHandle 0xFFFF ("zonehandle null"), no CHARDATA ("chardatabase null"), no SHAPE ("chardatashape null")
    if master.partyNo != 0xFFFF:
        count invalid → "master(%d) invalid partyno(%d)"; count >= 5 → "master(%d) to many member"
        Client_IsInRaid(master) → "master(%d) is in raid"
    prison: master → "master(%d) is in psiaon"; joiner → "join member(%d) is in psiaon"
    canparty == 0: master map → "master(%d) party impossible field"; joiner map → "join member(%d)  party impossible field"
    Party_CheckLevelGap fails → "join member(%d) join level"
    joiner pending elsewhere → "join member(%d) join ing"; joiner.partyNo != 0xFFFF → "join member(%d) other party"
    joiner.linking → "join member(%d) zone link"
    (the guild-only map check is evaluated but its result is ignored) (original bug) W02-B11
    !Client_SameKQTeam → "Kingdom Quest Team"
    r = Parties_Invite(master rec flag 0, joiner rec flag 0, master.partyNo)
    error code → "MemberJoin fail(%d)"
    master.partyNo = joiner.partyNo = r
    if Party_CountConfirmed(r) == 2: zones ← 0x3801 { r, master, joiner }; Friends_SendPartyState(both); Party_SendLooterInfo(r, master)
    else: zones ← 0x3808 { r, joiner }; Friends_SendPartyState(joiner)
    every confirmed online member ≠ joiner ← 0x3807 { joiner name, joiner class, 0x4C1 }
    Party_SendLooterInfo(r, joiner); Party_SendMemberList(r, joiner)
```

### 3.3 0x3861 NC_PARTY_ZONE_LEAVE_CMD { u32 nCharNo }

```pseudo
Zone_PartyZoneLeave(z, p):  s = Clients_FindByCharNo(nCharNo); if s: Party_Leave(s)   @ FUN_0042cbf0
```

---

## 4. Party lifecycle hooks (called from W01 paths)

### 4.1 Map login (0x180C, W01 §7)

```pseudo
in Zone_MapLoginDone (FUN_0042d8d0), after zoneNo/map are stored:
    Client_RaidOnMapLogin(s)                                                 (§6.1)
    if !Client_IsInRaid(s):
        Client_PartyRefreshOnMapLogin(s):                                    @ FUN_00430a30
            s.partyNo = Parties_FindByCharNo(charNo)
            in that party: member.wmHandle, zoneHandle, ZoneMerchineNo, level = current values
        if (Zones_IsPartyReleaseMap(new map) or payload byte +0x2e == 1) and s.partyNo != 0xFFFF: Party_Leave(s)
        Party_SendMemberList(s.partyNo, s); Party_SendLooterInfo(s.partyNo, s)
        Party_SendLogin(s.partyNo, charNo)   → zones 0x383C
        Party_SendLoginInfo(s.partyNo, charNo) → confirmed online members (s included) 0x383D { name }
    else (raid member) and (release map or flag):  leave the raid exactly like 0xB014 (§5.5) without the 0xB015 reply
```

This is how a character returns to its party after a relog or a map change: the party kept its member record
while it was offline (§4.2), and the record's handles are refreshed here.

### 4.2 Character logout (W01 §5.4 CharacterLogout, FUN_00436d50)

```pseudo
if Client_IsInRaid(s): Client_RaidOnLogout(s) (§6.2) else Client_PartyOnLogout(s)
PartyFinder_Remove(my name)                                                  @ FUN_004576d0

Client_PartyOnLogout(s):                                                    @ FUN_00436670
    pn = s.partyNo; invalid → return
    if Party_IsPending(pn, s.charNo):                                        # never accepted
        if Party_GetRole(pn, s.charNo) == 2: master session.partyNo = 0xFFFF
        Party_RemoveMember(pn, s.charNo); return
    Party_SendLogout(pn, charNo)  → zones 0x3846
    Party_SendLogoutInfo(pn, charNo) → other confirmed online members 0x3847 { name }
    if Party_AtMostOneOnline(pn):                                            @ FUN_004133b0 (≤ 1 confirmed member online, s counted)
        all zones ← 0x381F { pn }
        every member session by handle (not charNo-checked): partyNo = 0xFFFF, ← 0x381E, Friends_SendPartyState
        Parties_Release(pn)                                                  # the whole party is deleted
        return
    if s is members[0]:
        first other confirmed online member → Party_MakeMaster; Party_SendMasterChanged(pn)
    # s stays a member while offline; it is not removed
```

### 4.3 Other hooks

- Level change 0x1074 (W01 §7.5): `party.members[i].level = new level` @ FUN_0042e160.
- 0x4015 NC_CHARSAVE_2WLDMAN_GAME_CMD (W01 §7.4) compares the zone's partyNo/raidNo with the session values and
  logs a mismatch; the WM's value wins.
- Character rename (CharIDChange, FUN_00431dd0): in a raid → `Raid_RemoveMember` when the change is a delete
  (flag byte = 1) else the member name is replaced (FUN_00462ef0); otherwise the same for the party member record;
  the party-finder entry is deleted or renamed.

---

## 5. Raid: client handlers (CParserClient, dept 44)

All raid handlers return silently when the session has no CHARDATA. `0x1E80` is the success code of every raid
ACK; the client shows `ErrMsgTable(code)` for anything else unless noted. "Online members" = raid positions whose
charNo is in game (`Clients_FindInGameByCharNo`). The position `{nPartyNo, nPartyIndex, nSlotIndex}` of a member
is `Raid_Find`'s result.

### 5.1 0xB001 NC_RAID_MAKE_REQ (no payload)  (turn my party into a raid)

```pseudo
Client_RaidMakeReq(s):                                                      @ FUN_0041ed50
    reply = s ← 0xB002 NC_RAID_MAKE_ACK { u16 nRaidNo = 0xFFFF, u16 nError }
    s.raidNo != 0xFFFF → 0x1E81 "Already belongs to the expedition group."
    s.partyNo == 0xFFFF → 0x1E82 "You are not in a party."
    !Party_IsMaster → 0x1E83 "Only guild leaders can create expedition groups." (client text says guild)
    pending members of the party are removed (their sessions get partyNo 0xFFFF; nobody is told)
    raid = Raids_Create(s.partyNo, &err); null → reply err (0x1E84/0x1E85/0x1E86, or 0x1E80 when no raid slot is free)
    reply { raid.raidNo, 0x1E80 }       # the client prints "Expedition group has been formed." + "has been named expedition leader."
    if that send succeeded:
        every online raid member: raidNo = raid.raidNo;
            ← 0xB003 NC_RAID_MAKE_BROAD_CMD { u16 nRaidNo, u16 nRaidPartyNo[4], sFirstPartyCharID[5][20] }
               (names of the first party's 5 positions, "" when empty; missing party → log "… Not Find Raid Party")
        all zones ← 0xB004 NC_RAID_ZONE_MAKE_CMD { u16 nPartyNo (first party), u16 nRaidNo, u16 nRaidPartyNo[4],
                                                   u32 FirstPartyCharRegNo[5] }
```

The first party keeps its partyNo and becomes `partyNo[0]`; its master becomes leader and looter.

### 5.2 0xB008 NC_RAID_LOOTING_TYPE_REQ { u8 nItemGrade, u8 nLootingType }

```pseudo
Client_RaidLootingTypeReq(s, p):                                            @ FUN_00417420
    raid = Raids_Get(s.raidNo); none → log "… Not Find RaidNo : ", s ← 0xB009 NC_RAID_LOOTING_TYPE_ACK { 0x1EC3 }
    !PartyLoot_SetType(raid.loot, p.nItemGrade, p.nLootingType) → log "… Error LootingType  : ", 0xB009 { 0x1EC4 }
    s ← 0xB009 { 0x1E80 }
    online members ← 0xB00A NC_RAID_LOOTING_TYPE_BROAD_CMD { u8 nItemGrade, u8 nLootingType } (request echoed)
    all zones ← 0xB00B NC_RAID_ZONE_LOOTING_TYPE_CMD { u16 nRaidNo, u8 nItemGrade, u8 nLootingType }
```

No leader check: any raid member can change the loot rule (original bug) W02-B4.

### 5.3 0xB00C NC_RAID_INVITATION_REQ { char sInvitationCharID[20] }

```pseudo
Client_RaidInvitationReq(s, p):                                             @ FUN_0041f1c0
    reply(err) = s ← 0xB00D NC_RAID_INVITATION_ACK { sInvitationCharID = p.name, u16 nError }
    raid = Raids_Get(s.raidNo); none → log "fc_NC_RAID_INVITATION_REQ Not Find RaidNo : ", reply 0x1EC3
    !Raid_CanInvite(raid, s.charNo) → reply 0x1F44 "Only the expedition leader and vice leader can send invites."
    t = Clients_FindByCharName(p.name); none → 0x1EC5
    t.zoneHandle == 0xFFFF or !t.CHARDATA or t == s → 0x1EC6
    !Client_CanJoinRaid(t, &err) → reply err (0x1EC7/0x1EC8/0x1EC9/0x1ECA/0x1ECB)
    guild-only map on either side and not the same guild → 0x1ED0
    !Client_SameKQTeam(s, t) → 0x1ED4
    if t.pendingRaidInvite != 0xFFFF → reply 0x1EC7 ; else t.pendingRaidInvite = raid.raidNo
    reply 0x1E80
    t ← 0xB00E NC_RAID_INVITATION_CMD { sMasterCharID = s name }   "%s has invited you to the expedition group. Do you wish to join?"
```

Client (`FUN_004b13c0`): 0x1EC8 → "%s is already registered with another party." (or "Already belongs to the expedition
group." when the name is in its own raid list); 0x1EC7 → "%s has already received an invitation to the expedition.";
0x1ED4 → "You cannot make expedition with opposite team."

### 5.4 0xB00F NC_RAID_INVITATION_ANSWER_REQ { u8 bIsAllow, char sMasterCharID[20] }

```pseudo
Client_RaidInvitationAnswerReq(s, p):                                       @ FUN_00422400
    reply(err) = s ← 0xB010 NC_RAID_INVITATION_ANSWER_ACK { u16 nError }
    (every exit below except success first clears s.pendingRaidInvite)
    inv = Clients_FindByCharName(p.sMasterCharID); none or no CHARDATA → reply 0x1ECD
    answer = 0xB011 NC_RAID_INVITATION_ANSWER_CMD { sInvitationCharID = s name, u8 bIsAllow }
    if !p.bIsAllow: inv ← answer ("%s has declined to register for the expedition group."); return
    !Client_CanJoinRaid(s, &err) → reply err
    guild-only map and not same guild → reply 0x1ED0 ; !Client_SameKQTeam → reply 0x1ED4
    raid = Raids_Get(inv.raidNo) or else Raids_Get(s.pendingRaidInvite); none → reply 0x1ECE "This expedition group doesn't exist."
    s.pendingRaidInvite != raid.raidNo → reply 0x1ECE
    rec = { s charNo, zoneHandle, wmHandle, name, level, flag 0, class, zoneNo }
    !Raid_AddMember(raid, rec, &err) → reply err (0x1F45 full, 0x1F46, …)
    clear pendingRaidInvite; pos = Raid_Find(raid, s.charNo); End → reply 0x1ECF
    s.raidNo = raid.raidNo; s.partyNo = partyNo[pos.partyIndex]
    reply 0x1E80 ; inv ← answer (bIsAllow = 1)
    online members (s included) ← 0xB012 NC_RAID_MEMBER_JOIN_BROAD_CMD { u16 nPartyNo, u8 nPartyIndex, u8 nSlotIndex, sCharID }
    all zones ← 0xB013 NC_RAID_ZONE_MEMBER_JOIN_CMD { u16 nRaidNo, u16 nPartyNo, u8 nPartyIndex, u8 nSlotIndex,
                                                      u32 nCharNo, PROTO_PARTY_MEMBER_AND_ZONEMERCHINE tInfo }
    Client_SendRaidMemberList(s)
```

The new member goes into the first free position (party order, then slot order).

### 5.5 0xB014 NC_RAID_LEAVE_REQ (no payload)

```pseudo
Client_RaidLeaveReq(s):                                                     @ FUN_0041f4d0
    reply(err) = s ← 0xB015 NC_RAID_LEAVE_ACK { u16 nError }
    raid none → 0x1ED8 ; s not found in raid → 0x1ED9
    bc = 0xB016 NC_RAID_LEAVE_BROAD_CMD { u16 nPartyNo, u8 nPartyIndex, u8 nSlotIndex, sCharID = s name }
    zc = 0xB017 NC_RAID_ZONE_LEAVE_CMD { u16 nRaidNo, u16 nPartyNo, u8 nPartyIndex, u8 nSlotIndex, u32 nCharNo }
    Raid_HandOverRoles(raid, s.charNo)
    !Raid_RemoveMember(raid, s.charNo, &err) → reply err
    s.partyNo = s.raidNo = 0xFFFF
    reply 0x1E80 ; s ← bc ("Checked out of the expedition group.") ; remaining online members ← bc ; zones ← zc
    Raid_DismissIfEmpty(raidNo)
```

### 5.6 0xB018 NC_RAID_VANISH_REQ { char sVanishCharID[20] }  (leader bans a member)

```pseudo
Client_RaidVanishReq(s, p):                                                 @ FUN_0041f7b0
    reply(err) = s ← 0xB019 NC_RAID_VANISH_ACK { sVanishCharID = "" (zeros), u16 nError }
    raid none → 0x1EE0 ; s not leader → 0x1EE4
    pos = first position whose member name == p.name; none / charNo -1 → 0x1EE1 ; target == s → 0x1EE5
    bc = 0xB01B NC_RAID_VANISH_BROAD_CMD { u16 nPartyNo, u8 nPartyIndex, u8 nSlotIndex, sCommandCharID = s name, sVanishCharID }
    zc = 0xB01C NC_RAID_ZONE_VANISH_CMD { u16 nRaidNo, u16 nPartyNo, u8 nPartyIndex, u8 nSlotIndex, u32 nVanishCharNo }
    Raid_HandOverRoles(raid, target); !Raid_RemoveMember(raid, target, &err) → reply err
    reply 0x1E80
    target in game: partyNo = raidNo = 0xFFFF; ← 0xB01A NC_RAID_VANISH_CMD { sCommandCharID = s name }; ← bc
    remaining online members ← bc ; zones ← zc ; Raid_DismissIfEmpty(raidNo)
```

The target may be offline (found by member record name, not by session).

### 5.7 0xB027 NC_RAID_SLOT_MOVE_REQ { PrePosition{u16 nPartyNo, u8 nPartyIndex, u8 nSlotIndex}, PostPosition{…}, sPreSlotMoveCharID[20], sPostSlotMoveCharID[20] }

Only `nPartyIndex`/`nSlotIndex` of both positions are used; the names and Pre.nPartyNo are not checked.

```pseudo
Client_RaidSlotMoveReq(s, p):                                               @ FUN_0041fc70
    reply(err) = s ← 0xB028 NC_RAID_SLOT_MOVE_ACK { sSlotMoveCharID = "", u16 nError }
    raid none → 0x1EF0 ; s not leader → 0x1EF1
    a = Raid_GetMemberCharNo(Pre.idx, Pre.slot); -1 → 0x1EF2
    b = Raid_GetMemberCharNo(Post.idx, Post.slot)
    if b == -1: Raid_MoveMember(raid, a, Post.idx, Post.slot, &err)    (fail → reply err)
    else:       Raid_SwapMembers(raid, a, b)                            (fail → reply with an uninitialised stack value as nError) (original bug) W02-B9
    update partyNo of a (and b) in their sessions if in game
    reply 0x1E80
    online members ← 0xB029 NC_RAID_SLOT_MOVE_BROAD_CMD { sCommandCharID = s name,
        PrePosition = request's, PostPosition = a's new position (request's if not found),
        sPreCharID[5] = names in the Pre party (in-game members only, else ""), sPostCharID[5] = same for the Post party }
    all zones ← 0xB02A NC_RAID_ZONE_SLOT_MOVE_CMD { u16 nRaidNo,
        PrePosition { u16 nPartyNo (request), u8 idx, u8 slot, u32 nPartySeqCharNo[5] },
        PostPosition { u16 nPartyNo (request), u8 idx, u8 slot, u32 nPartySeqCharNo[5] } }
```

A move into a free slot appends the member at the end of the destination party, so the final slot can differ from
`Post.nSlotIndex`; the broadcast carries the real one.

### 5.8 0xB02B NC_RAID_SET_LEADER_REQ { char sNewLeaderCharID[20] }

```pseudo
Client_RaidSetLeaderReq(s, p):                                              @ FUN_004202c0
    reply(err) = s ← 0xB02C NC_RAID_SET_LEADER_ACK { sNewLeaderCharID, u16 nError }   (name zeros on errors)
    raid none → 0x1EF8 ; s not leader → 0x1EF9
    t = Clients_FindInGameByCharName(p.name); none → 0x1EF8
    !Raid_SetLeader(raid, t.charNo) → 0x1EFA ; position of the new leader not found → 0x1EFA
    reply { t name, 0x1E80 }
    t ← 0xB02D NC_RAID_SET_LEADER_CMD { sCommandCharID = s name }   (client: no visible action)
    online members ← 0xB02E { sCommandCharID = s name, sNewLeaderCharID = t name, position of t }
    all zones ← 0xB02F { nRaidNo, nNewLeaderCharNo, position of t }
```

The old leader becomes an ordinary member (not a sub-leader).

### 5.9 0xB030 NC_RAID_SET_SUB_LEADER_REQ { char sNewSubLeaderCharID[20] }

```pseudo
Client_RaidSetSubLeaderReq(s, p):                                           @ FUN_00420660
    reply(err) = s ← 0xB031 NC_RAID_SET_SUB_LEADER_ACK { name, u16 nError }
    raid none → 0x1F00 ; s not leader → 0x1F01 ; t = Clients_FindByCharName(p.name) none → 0x1F00
    !Raid_AddSubLeader(raid, t.charNo, &err) → reply err (0x1F08 / 0x1F0B / 0x1F0C) ; position not found → 0x1EFA
    reply { t name, 0x1E80 } ; t ← 0xB032 NC_RAID_SET_SUB_LEADER_CMD { sCommandCharID = s name }
    online members ← 0xB033 NC_RAID_SET_SUB_LEADER_BROAD_CMD { s name, t name, position }   "%s has been named vice expedition leader."
    all zones ← 0xB034 NC_RAID_ZONE_SET_SUB_LEADER_CMD { nRaidNo, nNewSubLeaderCharNo, position }
```

### 5.10 0xB035 NC_RAID_DEL_SUB_LEADER_REQ { char sDelSubLeaderCharID[20] }

```pseudo
Client_RaidDelSubLeaderReq(s, p):                                           @ FUN_00420a00
    reply(err) = s ← 0xB036 NC_RAID_DEL_SUB_LEADER_ACK { name, u16 nError }
    raid none → 0x1F08 ; s not leader → 0x1F09 ; no member with that name → 0x1F0A ; that position empty → 0x1F08
    !Raid_DelSubLeader(raid, charNo, &err) → reply err (0x1F0A)
    reply { p.name, 0x1E80 } ; target in game ← 0xB037 NC_RAID_DEL_SUB_LEADER_CMD { s name } (client ignores it)
    online members ← 0xB038 { s name, p.name, position } ; all zones ← 0xB039 { nRaidNo, nDelLeaderCharNo, position }
```

### 5.11 0xB03A NC_RAID_SET_LOOTER_REQ { char sNewLooterCharID[20] }

```pseudo
Client_RaidSetLooterReq(s, p):                                              @ FUN_00420e40
    reply(err) = s ← 0xB03B NC_RAID_SET_LOOTER_ACK { name, u16 nError }
    raid none → 0x1F10 ; s not leader → 0x1F11 ; t = Clients_FindInGameByCharName none → 0x1F10
    !Raid_SetLooter(raid, t.charNo) or position not found → 0x1F12 "You can not change the loot setting."
    reply { t name, 0x1E80 } ; t ← 0xB03C NC_RAID_SET_LOOTER_CMD { s name } (client ignores it)
    online members ← 0xB03D { s name, t name, position } "%s is to receive the item." ; zones ← 0xB03E { nRaidNo, nNewLooterCharNo, position }
```

### 5.12 0xB03F NC_RAID_CHAT_REQ / 0xB042 NC_RAID_WARNING_REQ { u8 itemLinkDataCount, u8 nChatLen, sChat[nChatLen], item links }

```pseudo
Client_RaidChatReq(s, p):                                                   @ FUN_00417630
    if CHARDATA.prison != 0 or p.itemLinkDataCount != 0: s ← 0xB040 NC_RAID_CHAT_ACK { 0x1FC1 }; return
    raid none → s ← 0xB040 { 0x1FC0 }
    pkt = 0xB041 NC_RAID_CHAT_BROAD_CMD { u8 itemLinkDataCount, sTalkerCharID = s name, u8 nChatLen, sChat,
                                          itemLinkDataCount × 0x67-byte link (copy; always 0 here) }
    if single-option blob(+0x658).nChatBan (u32 @+10) != 0: s ← pkt only (a chat-banned sender sees its own message, nobody else does)
    else every online member (s included) ← pkt
    # no ACK on success

Client_RaidWarningReq(s, p):                                                @ FUN_004178a0
    prison → 0xB043 NC_RAID_WARNING_ACK { 0x1F82 } ; itemLinkDataCount != 0 → { 0x1F83 } ; raid none → { 0x1F81 }
    !Raid_CanInvite (not leader / sub-leader) → { 0x1F80 }
    same as chat with opcode 0xB044 NC_RAID_WARNING_BROAD_CMD and itemLinkDataCount forced to 0
```

Client: 0xB040 shows "Cannot link item in Expedition chat." only for 0x1FC2, which the 2016 WM never sends
(it sends 0x1FC1), so a refused raid chat is silent (original bug) W02-B3; 0xB043 shows that text for 0x1F83 and `ErrMsgTable` for the rest.
`nChatLen` is not bounded by the WM beyond the u8 (the 0x2000-byte packet buffer is large enough).

---

## 6. Raid lifecycle hooks

### 6.1 Map login

```pseudo
Client_RaidOnMapLogin(s):                                                   @ FUN_00436b90
    s.raidNo = Raids_FindByCharNo(charNo)
    if in a raid and found:
        other online members ← 0xB01E NC_RAID_LOGININFO_CMD { u16 nPartyNo, u8 nPartyIndex, u8 nSlotIndex, sCharID }
        all zones ← 0xB01D NC_RAID_ZONE_LOGIN_CMD { u16 nRaidNo, u32 nCharNo }
        Client_SendRaidMemberList(s)
```

Note that `s.partyNo` is not re-derived for raid members here (the party branch of §4.1 is skipped); it keeps the
value from the session (0xFFFF after a fresh login) *(inferred from the code path; effect on zones not traced)*.

### 6.2 Logout

```pseudo
Client_RaidOnLogout(s):                                                     @ FUN_004357d0
    s.partyNo = s.raidNo = 0xFFFF   (session only; the character stays in the raid)
    if s is leader or looter: Raid_HandOverRoles(raid, s.charNo)
    online members not loggingOut ← 0xB020 NC_RAID_LOGOUTINFO_CMD { u16 nPartyNo, u8 nPartyIndex, u8 nSlotIndex, sCharID }
    all zones ← 0xB01F NC_RAID_ZONE_LOGOUT_CMD { u16 nRaidNo, u32 nCharNo }
    Raid_DismissIfEmpty(raidNo)
```

---

## 7. Result codes and client texts

Party (`ErrMsgTable` texts unless noted; codes without text print nothing useful):

| Code | Sent in | Meaning / client text |
|---|---|---|
| 0x4C1 | 0x3807 | joined (success; "%s has joined the party.") |
| 0x4C2 | 0x3807 | master is in a raid: "Cannot form/join a party now." |
| 0x4C4 | 0x3807 | "The selected character is already in a party." |
| 0x4C5 | 0x3807 | target not found / offline / self: "You must select a character first." |
| 0x4C6 | 0x3807 | "%s has rejected the party invitation." |
| 0x4C7 | 0x3807 | accept without a valid party: "An unexpected error has occurred." |
| 0x4C9 | 0x3807 | "There are too many people in the party." |
| 0x4CB | 0x3807 | "%s is receiving an invitation from another party." |
| 0x4CC / 0x4CD | 0x3807 | invalid party / no free party slot: "An unexpected error has occurred." |
| 0x4CE | 0x3807 | party slot not active: "Party has been dismissed." |
| 0x4CF | 0x3807 | "%s is already in your party." |
| 0x4D1 | 0x3807 | level gap (never sent in 2016, §1.2) |
| 0x4D2 | 0x3807 | prison or no-party map: "Party Invitation is not allowed in the area." |
| 0x4D3 | 0x3807 | "The selected user is current in prison." |
| 0x4D6 | 0x3807 | guild-only map, different guild (text is a blank) |
| 0x4DA | 0x3807 | "You cannot party with opposite team." (client prints it twice) |
| 0x480 | 0x3807 | target is changing map (no client text) |
| 0x501 | 0x380B | leave notification (client only compares the name) |
| 0x541 / 0x542 / 0x543 / 0x544 / 0x546 | 0x3815 | kicked / not a member / not in a party / requester in a raid (no text) / leader only |
| 0x548 / 0x542 / 0x543 / 0x549 | 0x3829 | master changed / not a member / leader only / not a member (no party) |
| 0x551 / 0x552 / 0x553 | 0x3851 | no character / added / updated (client ignores) |
| 0x554 / 0x555 | 0x3853 | not registered / deleted |
| 0x558 | 0x385B | looter set |
| 0x559 / 0x55A | 0xB05B (sic) | looter not found / already looter (never reach the client) |

Raid: 0x1E80 success everywhere.

| Code | Sent in | Meaning / client text |
|---|---|---|
| 0x1E81 / 0x1E82 / 0x1E83 | 0xB002 | already in a raid / not in a party / not the party master ("Only guild leaders can create expedition groups.") |
| 0x1E84 / 0x1E85 / 0x1E86 | 0xB002 | creation failed ("Expedition group cannot be created.") |
| 0x1EC1 / 0x1EC2 | internal | no party registry / raid slot busy |
| 0x1EC3 / 0x1EC4 | 0xB009, 0xB00D | raid not found / bad loot type (no text) |
| 0x1EC5 / 0x1EC6 | 0xB00D | "Can't find the character." / "This object cannot be registered with the expedition group." |
| 0x1EC7 | 0xB00D, 0xB010 | target is a pending party invitee or already has a raid invitation |
| 0x1EC8 | 0xB00D, 0xB010 | target in a party or raid |
| 0x1EC9 | 0xB00D, 0xB010 | target changing map: "The target is currently unavailable." |
| 0x1ECA / 0x1ECB | 0xB00D, 0xB010 | no-party map / prison: "…area where they cannot receive invitations…" |
| 0x1ECD / 0x1ECE / 0x1ECF | 0xB010 | inviter not found / "This expedition group doesn't exist." / not placed |
| 0x1ED0 | 0xB00D, 0xB010 | guild-only map (blank text) |
| 0x1ED4 | 0xB00D, 0xB010 | opposite KQ team |
| 0x1ED8 / 0x1ED9 | 0xB015 | raid not found / not a member |
| 0x1EE0 / 0x1EE1 / 0x1EE4 / 0x1EE5 | 0xB019 | raid not found / target not in raid / not leader / self |
| 0x1EF0 / 0x1EF1 / 0x1EF2 | 0xB028 | raid not found / "You are not an expedition leader." / "Can't find the character." |
| 0x1EF8 / 0x1EF9 / 0x1EFA | 0xB02C, (0xB031) | not found / not leader / "Cannot be made expedition leader." |
| 0x1F00 / 0x1F01 | 0xB031 | not found / not leader |
| 0x1F08 / 0x1F09 / 0x1F0A / 0x1F0B / 0x1F0C | 0xB031, 0xB036 | not a member / not leader / not a vice leader / 4 vice leaders already / already vice leader |
| 0x1F10 / 0x1F11 / 0x1F12 | 0xB03B | not found / not leader / "You can not change the loot setting." |
| 0x1F41 / 0x1F42 / 0x1F45 / 0x1F46 / 0x1F48 … 0x1F4E | 0xB010, 0xB015, 0xB019, 0xB028 | registry errors (0x1F45 "It's not possible to accept more expedition members.", 0x1F4C "Expedition group has been disbanded.") |
| 0x1F44 | 0xB00D | "Only the expedition leader and vice leader can send invites." |
| 0x1F80 … 0x1F83 | 0xB043 | not leader/vice / no raid / prison / item link |
| 0x1FC0 / 0x1FC1 | 0xB040 | no raid / prison or item link (client handles only 0x1FC2) |

---

## 8. Messages to the zones (summary)

Every one is broadcast to **all** zones (`Zones_BroadcastRaw` / FUN_00439500), not only to the members' zones.

| Opcode | When |
|---|---|
| 0x3801 NC_PARTY_FUNDAMENTAL_CMD | party born (second member confirmed) |
| 0x3808 NC_PARTY_JOIN_CMD | further member joined |
| 0x380C NC_PARTY_LEAVE_CMD | member left (0x380A, 0x3861, release map) |
| 0x3816 NC_PARTY_KICKOFF_CMD | member kicked |
| 0x381F NC_PARTY_DISMISS_CMD | party dissolved (leave/kick of a 2-member party, last online member logs out) |
| 0x382A NC_PARTY_CHANGEMASTER_CMD | master changed |
| 0x383C / 0x3846 NC_PARTY_LOGIN_CMD / NC_PARTY_LOGOUT_CMD | member map login / logout |
| 0x384D NC_PARTY_ITEM_LOOTING_ZONE_CMD | loot rule changed |
| 0x385E NC_PARTY_ZONE_SET_LOOTER_CMD | looter changed |
| 0x384F NC_PARTY_MEMBERINFORM_ACK | reply to 0x384E (to the asking zone / OPTool only) |
| 0xB004 / 0xB007 | raid made / dismissed |
| 0xB00B | raid loot rule |
| 0xB013 / 0xB017 / 0xB01C | member joined / left / banned |
| 0xB01D / 0xB01F | member map login / logout |
| 0xB02A / 0xB02F / 0xB034 / 0xB039 / 0xB03E | slot move / leader / sub-leader set / sub-leader removed / looter |

---

## 9. Original-server bugs (decide for a rebuild)

Behaviour of the 2016 WM that looks unintended. A faithful rebuild reproduces it; a fixed rebuild should change it
deliberately. Each item is read in the code; none was observed in a capture.

| # | Where | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| W02-B1 | 0x385A §2.8 | error replies 0x559 / 0x55A use opcode bytes `5B B0` (0xB05B, no such opcode) | client never shows "loot character not found" | send 0x385B |
| W02-B2 | 0x385A §2.8 | new looter is any in-game character, party membership not checked | a non-member can be the party looter | require party member |
| W02-B3 | 0xB03F §5.12 | refusal for prison / item link sends 0x1FC1; client only handles 0x1FC2 | refused raid chat is silent | send 0x1FC2 (or 0x1FC1 is right and the client is wrong) |
| W02-B4 | 0xB008 §5.2 | no leader / sub-leader check | any raid member changes the raid loot rule | leader only (party 0x384B is master-only) |
| W02-B5 | 0xB001 §1.4 | no free raid slot leaves `err = 0x1E80` | client gets raidNo 0xFFFF with the success texts | a real error code (0x1E84…0x1E87) |
| W02-B6 | 0x3802 §1.2 | level-gap limit is 1000 on u8 levels | error 0x4D1 can never happen | a real gap limit (the client text speaks of a gap "over 1") or remove the check |
| W02-B7 | `Raid_DismissIfEmpty` §1.4 | only the leader gets 0xB006 and has its raidNo/partyNo cleared | a remaining non-leader member keeps a stale raidNo/partyNo until its next map login *(inferred)* | tell the remaining member too |
| W02-B8 | 0x380A role 2 §2.4, logout §4.2 | dissolve paths address sessions by stored `wmcharhandle` without re-checking charNo | after handle reuse an unrelated session could get 0x381E and partyNo cleared *(inferred risk)* | check charNo like the other loops |
| W02-B9 | 0xB027 §5.7 | swap failure replies with an uninitialised nError | random code on the client | a defined error |
| W02-B10 | 0x3804 / 0x3802 | 0x3807 error replies leave `charclass` uninitialised; 0x380C leaves level/charclass uninitialised | garbage bytes on the wire (client ignores them) | zero them |
| W02-B11 | 0x3860 §3.2 | guild-only map check is computed and ignored | zone-driven joins bypass the guild-only rule | apply it, or drop the call |
| W02-B12 | client 0x3829 handler (FUN_004ac860) | client prints "% became the Party Leader." (missing `s`) | cosmetic, client-side | – |

## 10. Not reconstructed / uncertain

- Zone-side handling of all the notifications above is in **Z08**'s scope (zone `WorldManagerSession` handlers
  0x3801…0x385E and 0xB004…0xB03E); C02 notes the 0x384D/0x385E profiler-string mix-up there.
- The `nChatBan` name for single-option blob +10 is *(pdb2017)*; how the ban value is set is W04's (chat-ban
  handlers 0x0861/0x0863) and D02's.
- PARTY +0xcc and PARTY_MEMBER +0x20: never read by the WM code we followed.
- `FUN_0042cda0` (CParserZone 0x6009, dept 24 = NC_CT) forwards `0x380A { u32 charNo, u16 }` to the character's
  zone; it is in **W04**'s scope table and was not followed here.
- No capture with party or raid traffic was available; nothing here is *(captured)*.
