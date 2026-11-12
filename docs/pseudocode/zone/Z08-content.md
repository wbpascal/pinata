# Zone server: party/raid mirror, quests, kingdom quests, instance dungeons, guild / academy / tournament zone side, holy promise, misc (Z08)

Source: `Files/Server/2016/w00_Zone00/5ZoneServer2.exe`, export `re-data/exports/zone`. Each block cites the
function it was reconstructed from (`@ FUN_xxxxxxxx`); view one with
`python3 -I tools/protocol-re/clean.py re-data/exports/zone tools/protocol-re/names/zone <addr>`.
Function names are the original profiler strings (Z01 names file) unless marked *(ours)*; Z08's additions are in
`tools/protocol-re/names/zone/Z08.json`. Opcode names: `docs/protocol/opcodes.json`. Packet layouts:
[`../../protocol/annotations/Z08.json`](../../protocol/annotations/Z08.json).
Core facts (objects, send primitives, player modes, `g_Now` in tenths of a second, the `ref` header of server-link
messages) are in [`Z01-core.md`](Z01-core.md)–[`Z07-character.md`](Z07-character.md) and `docs/knowledge/Z01.md`–`Z07.md`;
the WM side of parties and raids is [`../wm/W02-party-raid.md`](../wm/W02-party-raid.md).

Conventions: `p` = the player. `SendErrorCode(dept, cmd, code)` = `vt 0x308`, a 2-byte `{u16 code}` packet.
"→ DB" = a request over a GameDB session, "→ WM" = to the World Manager. Field offsets are **payload** offsets
(packet offset − 2). "mode mask M" = the handler runs only when `M & (1 << p.mode)` (Z01-core §4.3, modes in
`docs/knowledge/Z02.md` §1). Every handler body is wrapped in the profiler enter/leave pair; not repeated below.

---

## 1. Party mirror (WM → zone, dept 14)

### 1.1 Data

The zone keeps a copy of every WM party: `g_ZoneParties` *(ours)* at `DAT_0da50bdc` = `{ PARTY *slots, int count }`,
4000 records of 0xD0 bytes, same layout as the WM's (W02 §1): `PartySlot(partyNo)` @ FUN_00645340 returns
`slots + partyNo*0xD0` (a static dummy record for partyNo ≥ 4000).

| Record offset | Field |
|---|---|
| +0x00 | u8 memberCount |
| +0x04 + i·0x24 | member i: `PROTO_PARTY_MEMBER_AND_ZONEMERCHINE` (chrregnum +0, zonecharhandle +4, wmcharhandle +6, charname[20] +8, level +0x18, flag +0x19, charclass +0x1a, ZoneMerchineNo +0x1b) followed by `ShinePlayer *` (+0x20; NULL when the member is not on this zone). Member 0 is the master. |
| +0xB8 | loot rule `{u32 lootType[4] per item grade, u32 looterCharNo}` (W02 §1) |
| +0xC8 | u32 creator charNo (set on create) |
| +0xCD | u8 reservedForRaid |

Player fields: `p+0x7fb9` u16 partyNo (`vt 0x574` set, `vt 0x550` get; 0xFFFF none); `p+0x29244` → the party record
(`vt 0x774` set); `p+0x29248…+0x29268` cache of the last values sent to the party (HP, SP, LP, class, level, max HP/SP/LP,
x, y). Raid membership is `vt 0xa84` (→ raid record, §2). `vt 0xa8c` `GetPartyKey(&kind, &id)` *(ours)* @ FUN_005605f0
returns `{kind 3, id = raid+4}` for a raid member, `{kind 0, id = partyNo}` for a party member, false otherwise; this key
selects the party's instance dungeon (§8).

Record helpers (shared party library, same code as the WM's): `Party_Create(master, member, partyNo)` @ FUN_00645600
(count 2, slots 2–4 charNo −1, loot rule zeroed, looter −1, creator = master), `Party_AddMember` @ FUN_006453f0 (ignored when
the record is empty and not raid-reserved, when it already has 5 members, or when the charNo or the name (case-insensitive)
is already in it), `Party_RemoveMember(partyNo, charNo)` @ FUN_00645710 (shifts the later members down),
`Party_SetMaster(partyNo, charNo)` @ FUN_00645870 (swaps that member into slot 0), `Party_Delete` @ FUN_00645110,
`LootRule_Set(grade, type)` @ FUN_00644ff0 (grades ≥ grade get `type`, lower grades 0), `LootRule_SetLooter` @ FUN_00645060.

`pm_HandleSet(partyNo, member)` @ FUN_004cc610 links one member to its local object:

```
if member.ZoneMerchineNo != own zoneNo: member.zonecharhandle = 0xFFFF (in the packet copy only); return
i = index of the record member with the same 20-byte name     (else log "Member Name not found")
rec.member[i].player = som_FindPlayer(name)
if none: rec.member[i].zonecharhandle = 0xFFFF; return
rec.member[i].zonecharhandle = player.handle; player.vt0x774(rec)        // p+0x29244 = rec
if rec.count > 5: log "Exceeded the NumOfMember"
elif rec.count == 5: for every linked member: CCharacterTitleZone(vt 0x420) FUN_005cbf20(title, partyNo, 5)   // full-party title check
```

`pm_Sendmemberinfo(partyNo)` @ FUN_004cc9f0 sets `partyNo` and the record pointer on every linked member whose object still
matches (same name and charNo); it also fills `g_buf` with a `0x3832 NC_PARTY_MEMBERINFORM_CMD` for all members (name, HP,
SP, LP; 0 for members not here) **but never sends it** (original bug, Z08-B1: dead packet build, the per-tick sender below does the
real work). `pm_NewMemberJoin` @ FUN_004cc920 calls `vt 0x77c` on every linked member, which is the empty function
FUN_00417480 (no effect in 2016).

### 1.2 Party status broadcast (player tick)

`sp_SendMyInform2PartyMember` @ FUN_0056df80 runs from the player routine while the player is in a party or raid and has a
record pointer. Each packet goes to the other linked members with `pm_Broadcast` @ FUN_004cce30; the raid variants are
FUN_005cd8f0 / FUN_005cd9c0 / FUN_005cdb50 (not expanded).

| When | Packet | Body |
|---|---|---|
| HP, SP or LP changed since the cache | `0x3832 NC_PARTY_MEMBERINFORM_CMD` (0x23 bytes) | `membernum 1, { charname[20], hp, sp, lp }` (`PROTO_PARTY_MEMBER_INFORM`) |
| class, level, max HP/SP/LP changed | `0x3833 NC_PARTY_MEMBERCLASS_CMD` (0x26 bytes) | `1, charname[20], u8 class, u8 level, u32 maxhp, u32 maxsp, u32 maxlp, u8 1` |
| moved ≥ 200 units since the cache (party only; raid → FUN_005cdb50) | `0x3849 NC_PARTY_MEMBERLOCATION_CMD` (0x1F bytes) | `1, charname[20], u32 x, u32 y` |

### 1.3 Handlers

```
0x3848 NC_PARTY_MEMBERINFOREQ_CMD (client, no body) @ FUN_004cd820 → FUN_004cd6d0, mode mask 0x7E
    for every linked member of p's party record: member.vt0x8dc → FUN_0056d980(member+0x29244)
        // resets the member's send cache (HP/SP −1, class/level, max HP/SP, x, y 0), so the next tick resends
        // all three status packets of every member to the party
```
The client sends it from three places (client FUN at decomp lines 128299/131243/138649 build `0x3848`), when the party
window needs a full refresh *(inferred)*.

```
0x3801 NC_PARTY_FUNDAMENTAL_CMD {u16 partyregnum, master, member} @ FUN_004cd5c0
    if partyregnum < 4000 and PartySlot(partyregnum).count == 0:
        Party_Create(master, member, partyregnum); pm_HandleSet(master); pm_HandleSet(member); pm_Sendmemberinfo
    else log "New party in nonempty slot"

0x3808 NC_PARTY_JOIN_CMD {u16 partyregnum, joiner} @ FUN_004cd730
    if partyregnum < 4000: Party_AddMember; pm_HandleSet(joiner); pm_Sendmemberinfo; pm_NewMemberJoin
    else log "join to empty party"

0x380C NC_PARTY_LEAVE_CMD {u16 partyregnum, PROTO_PARTY_MEMBER leavemember} @ FUN_004cda00
0x3816 NC_PARTY_KICKOFF_CMD {u16 partyregnum, u32 kickoffmemberregnum} @ FUN_004cdb20     (same body)
    q = som_FindPlayer(charNo)                    // charNo = payload +2 in both
    if q == NULL or q.GetPartyKey(&kind, &id):
        pm_MemberLeave(partyNo, charNo); Party_RemoveMember(partyNo, charNo)
        if q: InstanceEjectAfterLeave(q, partyNo, kind)      // FUN_00486c00, §8.5
    // a local member without party key is skipped entirely, the record keeps him (original bug, Z08-B2)
```
`pm_MemberLeave` @ FUN_004cc7e0: if the party had fewer than 3 members and is not raid-reserved, every linked member gets
`partyNo = 0xFFFF` (the WM dissolves a 2-member party); otherwise only the leaver. The `p+0x29244` record pointer is not
cleared.

```
0x381F NC_PARTY_DISMISS_CMD {u16 partyregnum} @ FUN_004cc060
    MapClusterManager visit DeleteDungeon{kind 0, partyregnum, 0}     // §8: the party's instances are deleted
    pm_Break: every member found by its stored zonecharhandle gets partyNo 0xFFFF
    Party_Delete(partyregnum)

0x382A NC_PARTY_CHANGEMASTER_CMD {u16 partyregnum, u32 newmaster_chrregnum} @ FUN_004cc150
    Party_SetMaster(...)        // charNo not in the record → FUN_0064f3c0(1, "Msg", "%s") with no argument (original bug, Z08-B3)

0x384D NC_PARTY_ITEM_LOOTING_ZONE_CMD {u16 partyregnum, u8 nItemGrade, u8 nLootingType, u32 LooterNo} @ FUN_004cc2a0
    LootRule_Set(rec+0xB8, nItemGrade, nLootingType); LootRule_SetLooter(LooterNo)
    // error branch logs the DISMISS text (original bug, Z08-B4)

0x385E NC_PARTY_ZONE_SET_LOOTER_CMD {u16 nPartyNo, u32 nNewLooterCharNo} @ FUN_004cc010
    LootRule_SetLooter(...)     // partyNo ≥ 4000: log "wms_NC_PARTY_ITEM_LOOTING_ZONE_CMD : OverNo"

0x383C NC_PARTY_LOGIN_CMD @ LAB_004cc200, 0x3846 NC_PARTY_LOGOUT_CMD @ LAB_004cc250
    empty bodies (profiler enter/leave only; read in the disassembly). Online state reaches the zone through
    0x384F refreshes instead.

0x384F NC_PARTY_MEMBERINFORM_ACK {u16 PartyRegnum, u8 NumberOfMember, PROTO_PARTY_MEMBER Member[]} @ FUN_004cd4b0
    rec = PartySlot(PartyRegnum)
    if rec.count != NumberOfMember or some record charNo is missing from the list:
        wms_PartyMemberRefresh(rec, body)  @ FUN_004cd1a0:
            rec.count = 0; for each listed member: copy it (0x1F bytes); player = som_FindPlayer(charNo)
            if found: link (+0x20, vt 0x774), ZoneMerchineNo = own zoneNo, zonecharhandle = player.handle
            else: player NULL, ZoneMerchineNo 0xFF, zonecharhandle 0xFFFF
    // when the list matches, nothing is updated (levels/handles keep their old values)
```
The zone asks with `0x384E NC_PARTY_MEMBERINFORM_REQ {u16 partyregnum}` (sent from the login path, Z01/Z07).

## 2. Raid mirror (WM → zone, dept 44)

`g_RaidTask` *(ours, log prefix `RaidTask::`)* at `DAT_14d50830` is built lazily on first use over `g_ZoneParties`
(FUN_0063d6a0). A raid record (shared `Raid` class, FUN_0063d…/FUN_0063e…) holds its raidNo at +4 and four partyNos; members
are addressed by `{nPartyIndex 0..3, nSlotIndex 0..4}` (W02). `Raid_Find(raidNo)` @ FUN_005cdf80 (→ FUN_0063d6d0). Player
`vt 0xa88` sets the raid pointer (`vt 0xa84` reads it). `ToShinePlayer` @ FUN_00409840 = RTTI-checked cast. Raid status
packets to the members: FUN_005cda50, FUN_005cd9c0 (class/level/max values), FUN_005cdb50 (location), FUN_005cdc00 — the raid
counterparts of §1.2 (not expanded; the client opcodes are 0xB020 LOGOUTINFO, 0xB021 MAPOUT, 0xB022 MEMBERINFORM,
0xB023 MEMBERCLASS, 0xB026 LOCATION *(pdb2017)*).

```
0xB004 NC_RAID_ZONE_MAKE_CMD {u16 nPartyNo, u16 nRaidNo, u16 nRaidPartyNo[4], u32 FirstPartyCharRegNo[5]} @ FUN_005a6320
    raid = RaidTask_Create(nRaidNo, nRaidPartyNo) @ FUN_005cde10      // every member online here: vt0xa88(raid)
    if none: log "Not Make Raid"; return
    for k in 0..4: if FirstPartyCharRegNo[k] != -1 and the member at raid position k differs:
        Raid_SwapMembers(...) @ FUN_0063ded0          // the creator's party keeps the WM's slot order; "swap error" log
    for every raid member that is a local ShinePlayer: FUN_005cd9c0; FUN_005cdb50
    MapCluster_ChangeOwner(g_MapClusterMgr, from {kind 0, nRaidPartyNo[0]} to {kind 3, raid.raidNo}) @ FUN_00485210
        // the party's instance dungeons now belong to the raid (§8)

0xB007 NC_RAID_ZONE_DISMISS_CMD {u16 nRaidNo} @ FUN_005a4cf0
    RaidTask_Reset(nRaidNo) @ FUN_005ce320: every local member vt0xa88(NULL); free the record (FUN_0063e110);
        if freeing fails the members are re-linked to the record and the handler logs "Not Reset Raid"
    on success: MapClusterManager visit DeleteDungeon{kind 3, nRaidNo, 0}

0xB00B NC_RAID_ZONE_LOOTING_TYPE_CMD {u16 nRaidNo, u8 nItemGrade, u8 nLootingType} @ FUN_005a4dc0
    if raid and nLootingType < 4: LootRule_Set(raid loot block, nItemGrade, nLootingType)

0xB013 NC_RAID_ZONE_MEMBER_JOIN_CMD {u16 nRaidNo, u16 nPartyNo, u8 nPartyIndex, u8 nSlotIndex, u32 nCharNo, PROTO_PARTY_MEMBER_AND_ZONEMERCHINE tInfo}
        @ FUN_005a4e90
    q = RaidTask_AddPlayer(body) @ FUN_005ce4f0   // adds at the position; q = local ShinePlayer nCharNo → vt0xa88(raid)
                                                  // ("RaidTask::rt_AddPlayer" logged when the add fails)
    if q: FUN_005cda50(q); FUN_005cd9c0(q); FUN_005cdc00(q)
    else: RaidTask_SendMemberClass(nRaidNo, nCharNo) @ FUN_005ce190: if the member exists, every local raid member gets
          0xB023 NC_RAID_MEMBERCLASS_CMD {1, entry (FUN_005cd5a0)} (0x3D bytes)

0xB017 NC_RAID_ZONE_LEAVE_CMD {u16 nRaidNo, u16 nPartyNo, u8 nPartyIndex, u8 nSlotIndex, u32 nCharNo} @ FUN_005a4f70
    q = RaidTask_DelPlayer(nRaidNo, nCharNo) @ FUN_005ce5e0     // removes; local q: vt0xa88(NULL); "rt_DelPlayer" log
    if q: InstanceEjectAfterLeave(q, nRaidNo, 3)                 // §8.5

0xB01C NC_RAID_ZONE_VANISH_CMD {…, u32 nVanishCharNo} @ FUN_005a5040
    q = RaidTask_DelPlayer(nRaidNo, nVanishCharNo)
    if q: InstanceEjectAfterLeave(q, nVanishCharNo, 3) twice     // passes the charNo as raidNo, and twice (original bug, Z08-B5)

0xB02A NC_RAID_ZONE_SLOT_MOVE_CMD {u16 nRaidNo, PrePosition (0x18), PostPosition (0x18)} @ FUN_005a5110
    // each Position = {u16 nPartyNo, u8 nPartyIndex, u8 nSlotIndex, …}; indices read at payload +4/+5 and +0x1C/+0x1D
    a = member at Pre, b = member at Post
    if a exists and b is empty: Raid_MoveMember(a, Post) @ FUN_0063dc10  ("Not Change Member" on failure)
    elif both exist: Raid_SwapMembers(a, b)                            ("Not Swap Member")
    for the moved member(s) online here: vt0x574(new partyNo); vt0x774(new party record)

0xB02F NC_RAID_ZONE_SET_LEADER_CMD      @ FUN_005a53d0 → Raid_SetLeader(raid, member at {nPartyIndex, nSlotIndex})   (FUN_0063e090)
0xB034 NC_RAID_ZONE_SET_SUB_LEADER_CMD  @ FUN_005a54a0 → Raid_SetSubLeader (FUN_0063df80)
0xB039 NC_RAID_ZONE_DEL_SUB_LEADER_CMD  @ FUN_005a5570 → Raid_DelSubLeader (FUN_0063cfa0)
0xB03E NC_RAID_ZONE_SET_LOOTER_CMD      @ FUN_005a5640 → Raid_SetLooter (FUN_0063e030)
    // all four: {u16 nRaidNo, u32 charNo, u16 nPartyNo, u8 nPartyIndex, u8 nSlotIndex}; position at payload +8/+9;
    // the charNo field is ignored, the position alone selects the member

0xB01D NC_RAID_ZONE_LOGIN_CMD, 0xB01F NC_RAID_ZONE_LOGOUT_CMD @ FUN_00509900: empty function (no effect)
```

## 3. Quests (dept 17)

### 3.1 Model

Each player owns a `CQuestZone` object at `p+0x173e8` (`vt 0x808` returns it); it derives from the shared quest library
(the client has the same classes, `CQuest` / `CQuestData`, 2017 PDB). The quest rows come from the quest data file loaded at
start (Z01 §2.3); `QuestData_Find(id)` @ FUN_00635ff0. The player's quest list ("diary") holds `PLAYER_QUEST_INFO`
records (0x20 bytes: `u16 ID, u8 Status, PLAYER_QUEST_DATA Data` *(pdb2017)*), filled at login by the WM blobs 0x1021
DOING / 0x1022 DONE / 0x10CD READ / 0x10D6 REPEAT (Z07 §1.2). Status values *(pdb2017 `PLAYER_QUEST_STATUS`)*:
0 NONE, 1 ABORT, 2 DONE, 3 SOON, 4 REPEAT, 5 ABLE, 6 ING, 7 FAILED, 8 REWARD, 9 LOWABLE, 20 READ_ABLE.
Diary helpers: `Diary_Find(id)` @ FUN_0062f210, `Diary_Store(info)` @ FUN_0062f2e0, `Diary_Touch` @ FUN_0062f320,
`Diary_Count` @ FUN_0062fb10.

| `CQuestZone+` | Field |
|---|---|
| +0x04 | current quest row |
| +0x2e·4 (+0xb8) | script runner (`ScriptNext` @ FUN_006387f0 returns the next command) |
| +0xa4…+0xb0 | quest reset times: year, month, week, day (`time_t`) |
| +0xb4 | owner ShinePlayer (NULL → every entry point returns) |
| +0xd0 | last answer of a SAY / SCENARIO command |
| +0x888 | script state (1 END, 0x23 EOF, 0 ERROR stop the loop) |
| +0x8fc | → current `STRUCT_QSC` command |
| +0x900 | waiting for a client/DB answer |
| +0x904 / +0x906 | NPC id / quest id of the running script (0xFFFF none) |
| +0x90c | selected reward index (0x4411) |

The quest **script** runs on the server; each command is a `STRUCT_QSC {u32 Cmd, u8 IsPigeonStartType, Data[0x60]}`
*(pdb2017, size 0x65; 2016 copies 0x65 bytes)*. Command numbers = `QUEST_SCRIPT_COMMAND` *(pdb2017)*.
`QuestNext` @ FUN_005bdef0 executes commands until one has to wait:

| Cmd | Action | Error on failure (`Send_QUEST_ERROR_TO_CLIENT`) |
|---|---|---|
| 1 END | send the command to the client (0x4401) | |
| 2 SAY | send, wait for 0x4402 (answer stored at +0xd0) | |
| 3 SCENARIO | `QuestPlayer_ScenarioRun` (client cut-scene, 0x4401 / scenario id), wait | |
| 4 CALLPS | `PsStart(name, args)` (a server-side script) | 0xC10 |
| 5 CLEAR | → DB `0x4405 NC_QUEST_DB_CLEAR_REQ {ref, u16 nQuestID}`, wait | |
| 6 ACCEPT | quest row required (0xC02); fewer than 40 diary entries (0xC0F); start conditions FUN_0062fee0 (0xC03); new record status 6 ING with `Data` start time = `_time64()` (or the stored record with status 6) → DB `0x4403 SET_INFO_REQ` | |
| 7 CANCEL | diary record required (0xC04); status update → SET_INFO_REQ or CLEAR_REQ | |
| 8 PROGRESS | (0xC05) → SET_INFO_REQ with the progress byte | |
| 9 FAILED | → SET_INFO_REQ | 0xC06 |
| 10 DONE | diary record required (0xC07); end conditions FUN_006300d0 (0xC08); if the quest has selectable rewards and none chosen → `0x4412 NC_QUEST_REWARD_NEED_SELECT_ITEM_CMD {u16 nQuestID}` and wait; `QuestCheckReward` (inventory room etc.) and `QuestTakeReward` → DB `0x441A NC_QUEST_DB_DONE_REQ` (money, exp, fame, item creates, inventory lock); on failure the lock is cancelled | 0xC01 |
| 11 LINK | by the linked quest's status: 4/5/20 → `QuestStart`, 6/7 → `QuestDoing`, 8 → `QuestEnd`, then continue | |
| 12 ABORT | → SET_INFO_REQ | 0xC09 |
| 13 DELETE_ITEM | `sp_DestroyItemB(item id, count)` | 0xC0A |
| 14 CREATE_ITEM | `sp_MakeItem_2(item id, count)` | 0xC0B |
| 18, 20–22 GOTO/SET/ADD/SUB | script variable / jump (runner) | |
| 23–27 GET_PLAYER_RACE/CLASS/LEVEL/GENDER/EMPTY_INVENTORY | store into script variable `Data[0]` (vt 0x6c/0x70/0x64/0x74/0x78 of the quest object) | |
| 30–32 SET/RESET/IS_ABSTATE, 33 GET_ITEM_LOT | abstate / item-count tests (not expanded) | |
| other | log "QUEST UN-DRIVED COMMAND", stop | |

When the loop ends (END/EOF/ERROR state) the script is closed (`QuestClose` @ FUN_005b9e50) and `sp_EndOfTrade(p, 1)`
runs. `Send_QUEST_ERROR_TO_CLIENT(code)` @ FUN_005bd870 also calls `sp_EndOfTrade(p, 1)` and sends 0x4401 with
`Cmd 0 (QSC_ERROR)`, `Data = {u32 failing Cmd, u32 0, u16 code}`. The client (`On_NC_QUEST_SCRIPT_CMD_REQ`,
client FUN_004ba970) prints "an unknown error has occurred", "Inventory full. Cannot receive the reward item.",
"ths quest is not proceedable" or the give-up failure text.

Error codes are quest-local numbers without a client error-table text; meanings from the code: 0xB41 success
(DB answers, give up), 0xB45 give up: unknown quest, 0xB46 give up (repeat quest) failed, 0xB47 select-start refused,
0xB49 give up too soon, 0xB50 start accepted, 0xB51 no quest object, 0xB53 not active, 0xB58 read OK, 0xB59 read
refused, 0xB5A read: not active; 0xC00–0xC10 script errors (table above; 0xC0C answer does not match, 0xC0D unknown
command, 0xC0E DB failure). `smo_IsActiveMode` gates all client requests.

### 3.2 Client requests

```
0x4402 NC_QUEST_SCRIPT_CMD_ACK {u16 nQuestID, u8 nQSC, u32 nResult} @ FUN_00578340 → Recv @ FUN_005bf0d0
    require IsActiveMode; p+0x5cb4 = g_Now                         // timestamp for the give-up delay
    q.waiting = 0
    if q.questId == 0xFFFF: return
    if nQuestID != q.questId or nQSC != current.Cmd: Send_QUEST_ERROR(0xC0C); return
    SAY (2):      q.answer = nResult; QuestNext
    SCENARIO (3): q.answer = nResult; if nResult != 0: q.vt0x18(Data.id) (scenario result branch); QuestNext
    LINK (11):    QuestStart(Data.questId)
    other: log "QUEST UN-DRIVED COMMAND"; Send_QUEST_ERROR(0xC0D); QuestClose

0x4407 NC_QUEST_GIVE_UP_REQ {u16 nQuestID} @ FUN_00578910
    require IsActiveMode
    if g_Now < p+0x5cb4 + 100: → 0x4408 NC_QUEST_GIVE_UP_ACK {nQuestID, 0xB49}     // 10 s after the last script answer
    else Recv @ FUN_005bd960:
        rec = Diary_Find(id); row = QuestData_Find
        if !rec or !row: GIVE_UP_ACK {id, 0xB45}
        elif FUN_006304d0 (may give up):
            if row.repeatable (+0x12) == 0: → DB 0x4409 NC_QUEST_DB_GIVE_UP_REQ {ref, nQuestID}
            else: rec.Status = 4 REPEAT → DB 0x4403 SET_INFO_REQ with nQSC = 28 (REPEAT_QUEST_GIVE_UP)
        // otherwise: no answer at all (original bug, Z08-B6)

0x440B NC_QUEST_CLIENT_SCENARIO_DONE_REQ {u16 nScenarioID} @ FUN_005789f0
    require IsActiveMode → QuestPlayer_ScenarioDone_Server(nScenarioID) @ FUN_005bd750
        (answers 0x440C NC_QUEST_CLIENT_SCENARIO_DONE_ACK {nScenarioID}; not expanded)

0x440F NC_QUEST_SELECT_START_REQ {u16 nNPCID, u16 nQuestID} @ FUN_00578ab0 → Recv @ FUN_005c0550
    row = current quest row; if !row or !CanStart(FUN_00630570): err 0xB47
    elif nQuestID != q.questId and q.npc == nNPCID and QuestScriptRun(nQuestID) != 0: err 0xB41
    else err 0xB47
    → 0x4410 NC_QUEST_SELECT_START_ACK {nNPCID, nQuestID, err}     // the 2016 client ignores this packet (C01)

0x4411 NC_QUEST_REWARD_SELECT_ITEM_INDEX_CMD {u16 nQuestID, u32 nSelectedItemIndex} @ FUN_00578b70 → @ FUN_005bb490
    if nQuestID == q.questId: q.selectedReward = nSelectedItemIndex       // no reply; the next DONE uses it

0x4414 NC_QUEST_START_REQ {u16 nQuestID} @ FUN_00578e90
    if !IsActiveMode: err 0xB53
    elif QuestPlayer_NotCheckNPC(nQuestID) @ FUN_005c03c0 != 0: err 0xB50     // success code
    else: no reply
    → 0x4415 NC_QUEST_START_ACK {u16 err} (sender FUN_00578c30, opcode from the static {17, 21})
  NotCheckNPC: refused while q.waiting == 1; needs the quest row; picks the start NPC (row+0x1e when row+0x1d == 1, or the
  first open reward NPC slot of a status-8 quest); requires a "no NPC needed" flag (row+0x20, or row+0x58 / row+0x19 by
  status); sets +0x88c and runs the quest script (QuestScriptRun). The 2016 client closes its quest window on 0xB50.
  (The `this+0x173e8 == NULL` test in the handler can never be true; dead check (original bug, Z08-B15).)

0x4416 NC_QUEST_READ_REQ {u16 nQuestID} @ FUN_00578f90
    if !IsActiveMode: → 0x4417 NC_QUEST_READ_ACK {0xB5A, …}  (FUN_00578d60, opcode from the static {17, 23})
    elif Send_NC_QUEST_DB_READ_REQ @ FUN_005bb6b0 fails: READ_ACK {0xB59}
       // fails when there is no current quest row or the diary status is 2, 6, 7 or 8
    else → DB 0x4418 NC_QUEST_DB_READ_REQ {ref, u16 nQuestID}
```

### 3.3 DB answers

All five GameDB handlers look the player up by `ref` (charNo match, not closing) and call the CQuestZone method. The
0x4419 and 0x441B handlers carry the profiler string of 0x440A (`…GIVE_UP_ACK`, copy-paste).

```
0x4404 NC_QUEST_DB_SET_INFO_ACK {ref, u8 nQSC, PLAYER_QUEST_INFO QuestInfo, u16 ErrorType} @ FUN_00578410 → @ FUN_005bf280
    p.vt0xae4(0); q.waiting = 0
    if nQSC == 28 (repeat give up): ok = ErrorType == 0xB41 and the record exists → record.Status = 4
        → 0x4408 GIVE_UP_ACK {ID, ok ? 0xB41 : 0xB46}; return
    if ErrorType != 0xB41: debug message box; Send_QUEST_ERROR(0xC0E); return
    apply the change to the diary: 6 ACCEPT FUN_0062f3b0, 7 CANCEL FUN_0062f4b0, 8 PROGRESS FUN_0062f550(byte +0x1e),
        9 FAILED FUN_0062f5b0, 10 DONE FUN_006302b0 (+ title check FUN_005cc270 for a non-repeatable quest),
        12 ABORT FUN_0062f680; other → "UN-DRIVED COMMAND", QUEST_ERROR 0xC0E
    if applied: → client 0x4401 {ID, Cmd = nQSC (+ progress byte)}
    if ACCEPT: → GameLog 0xC80F NC_SYSLOG_CHAR_QUEST_STARTED {u32 userNo, u32 charNo, u16 questId, u8 zoneNo, u16 FUN_0062fc30(questId)} (15 bytes)
    QuestNext

0x4406 NC_QUEST_DB_CLEAR_ACK {ref, u16 nQuestID, u16 ErrorType} @ FUN_00578510 → @ FUN_005bf640
    nQuestID must equal the current command's quest id, ErrorType 0xB41; else QUEST_ERROR 0xC00
    q.waiting = 0; QuestNext

0x440A NC_QUEST_DB_GIVE_UP_ACK {ref, u16 nQuestID, u16 ErrorType} @ FUN_00578610 → @ FUN_005bafc0
    if ErrorType == 0xB41: Diary_Store({nQuestID, Status 20 READ_ABLE, Data 0})
    → 0x4408 GIVE_UP_ACK {nQuestID, ErrorType}

0x4419 NC_QUEST_DB_READ_ACK {ref, u16 err, u16 nQuestID} @ FUN_00578710 → @ FUN_005c06c0
    if err == 0xB41: Diary_Store({nQuestID, 20, 0}); → 0x4417 NC_QUEST_READ_ACK {0xB58, nQuestID}
    else → READ_ACK {err}                                // the client only prints "%d ??? Read OK" to the debugger

0x441B NC_QUEST_DB_DONE_ACK {ref, u8 nQSC, PLAYER_QUEST_INFO, u16 nLockIndex, u16 ErrorType} @ FUN_00578810 → @ FUN_005bfb30
    if ErrorType == 0xB41:
        inventory lock list (vt 0x7d4).apply(nLockIndex)   // gives the reward items; failure logged as
                                                           // "Recv_NC_ITEMDB_QUESTREWARD_ACK"
        q.waiting = 0; if FUN_006302b0 (mark done): title check; → client 0x4401 {ID, Cmd nQSC}
        p.vt0xae4(0); QuestNext
    else: debug message box; lock list.cancel(nLockIndex); QUEST_ERROR 0xC0E; p.vt0xae4(0)
```

### 3.4 Reset times (WM → zone)

```
0x441C NC_QUEST_RESET_TIME_CMD {i32 tResetYearQuest, tResetMonthQuest, tResetWeekQuest, tResetDayQuest} @ FUN_005a6520
    for every entry of g_PlayerList: q = entry.vt0x808(); Recv @ FUN_005bdc80: store the 4 times;
        → client 0x441E NC_QUEST_RESET_TIME_CLIENT_CMD {u32[4]} (18 bytes) via the send object vt 0x2fc
    // the loop calls through the entry pointer without a NULL check for unused list cells (original bug, Z08-B7)

0x441D NC_QUEST_RESET_TIME_ZONE_CMD {u32 nCharNo, i32 times[4]} @ FUN_005a5b90
    p = som_FindPlayer(nCharNo) (else log "ShineObject Null"); store; → 0x441E through the other send object (vt 0x2f8)
```
The client stores the four times in its quest object (+0xa4…+0xb0, C01) to show daily/weekly reset.

## 4. Kingdom quests (dept 22)

A kingdom quest (KQ) is a scheduled event owned by the WM (W04). The WM picks a zone, asks it to build the KQ
(0x580D), then starts it with the joiner list (0x580F) and destroys it at the end (0x5811). On the zone a KQ is a
`KingdomQuest::KQElement` in `g_KingdomQuests` *(ours)* = `KingdomQuestContainer` at `DAT_0d624a00`
(`kqc_SearchHandle(handle)` @ FUN_004954f0); contribution scores live in `KQContribute::KQContributeList` at `DAT_0d67a048`.

| `KQElement+` | Field |
|---|---|
| +0x04 | copy of `PROTO_KQ_INFO` (0x179 bytes *(pdb2017)*: Handle, Status, NumOfJoiner, ID, Title[64], LimitTime, StartTime, level/player limits, repeat/revival modes, demands, RewardIndex, DemandMobKill, ScheduleTime, `MapLink[4]` `{MapIndex, MapBase, MapName, MapClear}`, ScriptLanguage[32], ScriptInitValue[32], IsTeamPVP, TeamRegenXY[2]) |
| +0x16d + team·8 | TeamRegenXY[team] (x, y) |
| +0x180 … | 4 map slots of 0x24 bytes: map index, MapBase name (+0x181), MapName (+0x18d), FieldMap * (+0x19c, +0x1c0, …), MapInfo row (+0x1a0: regen x/y at +0x32/+0x36), MapClear flag |
| +0x210 / +0x310 | script language / init value texts (expanded by FUN_004d62c0, 0x100 bytes each) |
| +0x410 | `KQPlayerInfoList` (joiners: charNo, team, knock-down count, revive number) |

A KQ map instance (`FieldMap`) carries the KQ handle at `+0x3c` (−1 none) and the KQ ID at `+0x40`.

```
0x580D NC_KQ_W2Z_MAKE_REQ {PROTO_KQ_INFO KQInfo} @ FUN_00497790 (profiler string "…W2Z_MAKE_REQ", log texts "…MAKED_CMD")
    reply = 0x580E NC_KQ_Z2W_MAKE_ACK {u32 hquest = KQInfo.Handle, u16 err} → WM
    if kqc_SearchHandle(Handle) exists: err 0x982 "Duplicate handle"
    book = ScenarioBookShelf.sbs_GetScenarioBook(ScriptLanguage[32])     // the KQ map script
    if !book: err 0x98C "Script not found" (ERR_KINGDOMQUEST_MAKE_SCRIPTNOTFOUND)
    for i in 0..3 (MapLink[i]):
        if MapLink[i].MapBase is empty: if i == 0: err 0x984; reply; return       // else stop scanning
        if !kqc_MapUseCheck(MapBase): err 0x988+i "Submap in use"; reply; return
        find a free FieldMap instance named MapBase (ListSearchSame over g_FieldList); MapInfo row from g_MapData
        if MapInfo row missing: err 0x984+i "Not found2"; reply; return
        if no local instance: allLocal = false; continue                       // map hosted elsewhere
        if instance.kqHandle != -1: err 0x988+i "Not empty2"; reply; return
        instance.kqHandle = Handle; instance.kqId = ID; if MapClear: fm_ClearObject(instance, 0x3b6)
    el = container.New() (else err 0x983 "Buffer full"); copy KQInfo, map slots, both script texts;
    clear el.playerInfoList
    if allLocal: err 0x981 (= ERR_KINGDOMQUEST_MAKE_NOERR, success); reply
    // when some map is not on this zone, no 0x580E is sent at all (original bug, uncertain: the WM may expect it, Z08-B8)
    KQContribute.kqcl_NewKQ(Handle)

0x580F NC_KQ_W2Z_START_CMD {PROTO_KQ_INFO KQInfo, u16 NumOfJoiner, PROTO_NC_KQ_JOINER JoinerArray[] {u32 chrregnum, u8 nTeamType}}
        @ FUN_00499240
    el = kqc_SearchHandle(Handle) (else log "Not exist KingdomQuest")
    if el has its first map: kqe_QuestStart(el) @ FUN_004953e0
        for each joiner: el.playerInfoList.Add(chrregnum, nTeamType, 1) @ FUN_00498f30
    entrance = KingdomQuestEntrance.new(KQInfo + joiners) @ FUN_00496150   // ring of 128 entries, ≤ 100 joiners each
                                                                          // ("Too many entrance" above 100)
    link = { MapName, MapBase, regen x/y of map 0 }
    for delay in {0, 2, 5, 7, 10} seconds: reserve a timed event (queue DAT_13388e70, "EventReserve error" when full) at
        g_Now + delay·10 that runs KingdomQuestGateKeeper::erb_happen(entrance, link, ID, Handle)

KingdomQuestGateKeeper::erb_happen @ FUN_00496280 (timer)
    sort the entrance list (qsort by charNo); el = kqc_SearchHandle (else "pKQElement NULL")
    for every local player in mode ≠ 0 and ≠ 3 (not dead) that is in the entrance list and passes FUN_00495160:
        if mode 5 (vending booth): system messages "KQEntryInCamp0", "KQEntryInCamp1" (vt 0x784), log " is in Booth"
        if mode 4: stand up (vt 0x488)
        title check FUN_005cbf90
        team < 2: so_LinkTo(link with TeamRegenXY[team])   else so_LinkTo(link, 6, 9, 10)
        → GameLog 0x0441 NC_LOG_GAME_KQ_ENTER {u32 charNo, char map[12], u32 x, u32 y, u16 KQ ID, u32 Handle} (0x20 bytes)
        mark the entrance entry used (charNo = −1)
    // players who are offline or on another zone at all five ticks are not pulled in

0x581A NC_KQ_ENTRYRESPONCE_ACK {u8 Reply, u32 EncHandle} @ FUN_00496990 (client), mode mask 0x56 {1,2,4,6}
    if Reply == 0: return
    if mode 4: stand up
    el = kqc_SearchHandle(EncHandle ^ p.wmHandle)          // the handle is XOR-masked with the player's WM handle
    if el: so_LinkTo({MapName, MapBase, map 0 regen x/y}, 6, 9, 10)
    // no reply; an unknown handle is ignored. 0x5819 NC_KQ_ENTRYRESPONCE_REQ {u16 ID, u32 EncHandle} is the invitation
    // (sent by the WM, W04); the 2016 GameFrameWork ignores it (C01), so how the client produces EncHandle is open.

0x5811 NC_KQ_W2Z_DESTROY_CMD {u32 hquest} @ FUN_004972c0
    el = kqc_SearchHandle(hquest); if none: return
    KQContribute.kqpl_EndOfKQ(hquest)
    for each of the 4 map slots with an instance: if MapClear: fm_ClearObject(map, 0x3b0)
        map.kqHandle = −1; map.kqId = 0xFFFF; stop the map script (FUN_00509150 with the script text);
        FUN_0049e1e0(map's link block)
    container.Remove(el)

0x5833 NC_KQ_LINK_TO_FORCE_BY_BAN_CMD {u32 nCharNum, Name3 sMapName[4]} @ FUN_00497120
    p = som_FindPlayer(nCharNum); require mode ≠ 0 and a current map
    if p's map name equals one of sMapName[0..3]: so_LinkTo({"RouN", "RouN", x 6445, y 8630}, 6, 9, 10)
        // banned from the KQ: sent back to Roumen (hard-coded)

0x583B NC_KQ_PLAYER_DISJOIN_CMD {u32 nHandle, u32 nCharNum} @ FUN_00499100
    el = kqc_SearchHandle(nHandle); if el: el.playerInfoList.Remove(nCharNum) @ FUN_00499030

0x5816 NC_KQ_REWARDSUC_ACK {ref, u16 lockindex} @ FUN_0052e570
    p by ref (not closing, charNo); inventory lock list.apply(p, lockindex, 0)
    // gives the reward items locked by the KQ reward request 0x5815; failure logged "gds_NC_KQ_REWARDSUC_ACK"
0x5817 NC_KQ_REWARDFAIL_ACK {ref, u16 lockindex, u16 error} @ FUN_0052e680
    p by ref; lock list.cancel(lockindex)          // error not shown to the player
```
The KQ reward request (`0x5815 NC_KQ_REWARD_REQ {fame, cen, item list}`) is sent from the KQ map script's result
nodes (`cQuestResult`, `PineEventScriptNode::ShineQuestResult`, Z09); the zone locks the reward cells first.

## 5. Instance dungeons (dept 41) and their NPC gates

### 5.1 Model

An instance dungeon ("Indun") is a FieldMap instance owned by a key `{CATEGORY, RegisterNumber}`; categories
*(pdb2017 `INSTANCE_DUNGEON::CATEGORY`)*: −1 CLASSIC, 0 PARTY (key = partyNo), 1 GUILD, 2 INDIVIDUAL, 3 RAID (key = raidNo).
Instances are managed by `MapClusterManager::ClusterManager` at `DAT_0d742b30` (`g_MapClusterMgr` *(ours)*):
`cm_FindExistByRegnum(map, regnum, category, &level)` @ FUN_00486400, `cm_FindEmptyByRegnum` @ FUN_00486290,
`DeleteDungeon` visitor {category, regnum, flag} @ FUN_004866b0 (`mc_DeleteInstanceDungeon` @ FUN_004867d0),
`ChangeOwner` @ FUN_00485210 (`mc_ChangeCategory`). Levels *(pdb2017 `ID_LEVEL_TYPE`)*: 0 EASY, 1 NORMAL, 2 HARD.

Gate data: the NPC's role row (`World/NPC.txt` role `IDGate` / `ModeIDGate` / random-multi gate, Z02 §6.4) names an
**instance-dungeon row** by a 20-byte key (`ORToken Argument`, role row +0x54); `IDInfo_Find(g_FieldList, key, level)`
@ FUN_00484470 returns it (FUN_00484380 without level). Row fields used: +0x15 u8 zone number hosting the dungeon, +0x16 map
name, +0x23 script name, +0x43 level/mode, +0x44 required group (2 party, 3 raid, 4 party or raid), +0x47 u16 required
quest, +0x69 u8 item count, +0x6b u8 max players, +0x6d u16 required item (−1 none). Level limits come from the Indun level
table `DAT_0d026c30` (FUN_0046a370(map, mode): +0x22 min, +0x24 max).

`IDCondition(p, row, &regnum, &category)` *(ours)* @ FUN_004624d0 returns 0 OK, 1 no key (also for group types 0/1 and
unknown types), 2 level outside the row's limits, 4 needs a party (type 2: party and not in a raid; type 4: party or raid)
or the required quest is not done, 5 needs a raid, 6 required item missing or too few; it fills the key (party → `{partyNo, 0}`,
raid → `{raidNo, 3}`). `LinkCondition_Report(p, code, levels)` @ FUN_004626e0 returns true for 0 and otherwise shows the
system text "LevelLimit" (with min/max), "PartyLimitedField" (3), "NeedPartyOrQuest" (4), "NeedRaid" (5), "NeedItem" (6);
1 is silent; on a mover only the mover owner gets the text.

Player: `p+0x5cb9` bit 7 = an ID level-select request is in flight (FUN_00560f90 get / FUN_00560fa0 set); `vt 0xbbc` returns
the player when usable (FUN_00450350).

### 5.2 Gate roles and menu callbacks (Z02 §6.5 open points)

```
NPCRole_ID_Portal.nrb_Role(p, entry) @ FUN_004c33f0            (role "IDGate"; profiler name NPCRole_Portal::nrb_Role)
    require no trade partner, empty server menu, link index (role+0x18) ≥ 0, and either index > 0 or link row 0's key
        equals the NPC's key; require the role's ID row (role+0x9c)
    code = IDCondition(p, row, &regnum, &category); levels = Indun level table (default 1 … g_MaxLevel)
    if LinkCondition_Report(code):
        build 0xA404 NC_INSTANCE_DUNGEON_FIND_RNG in g_buf {Start {machine, handle = p.handle, regnum = charNo},
            InstanceCategory, IDRegisterNumber, Argument = key, Error 2}
        IDGate_OpenMenu(p, buf) @ FUN_005a6d10: find the LinkTable row with the same key; server menu titled
            sprintf("LinkTitle", destination map name), "Yes" → smfm_LinkToDungeon({regnum, key, category}),
            "No" → smfm_Cancel, range 1000

ServerMenuFuncter.smfm_LinkToDungeon(p, data) @ FUN_0050f070
    0xA404 {Start {own zoneNo, p.handle, charNo}, category, regnum, Argument = data key, Error 2}
    row = IDInfo_Find(key, 1); if row: ZoneRingPacketFindInstanceDungeon.zrpb_Request(p, buf, row) @ FUN_005a92e0:
        if row.zone == own zone:
            party/raid key required (else system text "CannotAddAnymore")
            find or create the instance (FUN_00486d80); on success: link through the matching LinkTable row
                (sp_DestroyItemB first when the row needs an item; so_LinkTo otherwise); on failure "CannotAddAnymore"
        else: forward 0xA404 (0x48 bytes) around the zone ring (zcs_Send); the hosting zone's
              `zrpb_Success` @ FUN_005a8c20 clears the instance (fm_ClearObject 0x3b0), restarts its script and plays the film
              (answer path is ZoneListenSession, not in this item)

NPCRole_Mode_ID_Portal.nrb_Role(p, entry, npcHandle) @ FUN_004c35d0     (role "ModeIDGate": dungeon with levels)
    require request flag clear, no trade, empty menu, link row 0 key equals the NPC key
    if level outside [role.vt0x3c, role.vt0x40]: code 2
    else for each of the 3 ID rows (role+0x9c…): c = IDCondition; 2 → try the next row; 0/4/5/6 → keep (stop at 0);
         1/3 → return silently                         // all three level-limited → code stays 1 (silent)
    if LinkCondition_Report(code):
        → WM 0xA408 NC_INSTANCE_DUNGEON_LEVEL_SELECT_CHECK_REQ {u8 nStartZoneNum = own, u8 nDestZoneNum = row.zone,
             u32 nCharRegNum, u32 nInDunRegNum, i32 IndunCategory, u16 nNPCHandle, ORToken Argument} (0x24)
        set the request flag

NPCRole_RandomMulti_Portal.nrb_Role(p, entry, npcHandle) @ FUN_004c3850
    require no trade and an empty menu; link index (role+0x18) ≥ 0
    index 0: walk the role's link rows for the one whose key equals the NPC key; check its level range (system text
        "LevelLimit") and, unless the row allows solo (+0x60), that p is **not** in a party (else "PartyLimitedField");
        then pick a random destination row (FUN_00427c30 over vt 0x28 rows)
    index > 0: the role's own row (+0x1c)
    server menu "LinkTitle"(destination map name): "Yes" → smfm_Link(row), "No" → smfm_Cancel, range 1000
    // a plain random link, no instance key

ServerMenuFuncter.smfm_DeleteInstanceDungeon(p, data {category, regnum}) @ FUN_0050f370
    ZoneRingPacketEmtpyInstanceDungeon.zrpb_Request @ FUN_005a8a70: → ring 0x10B1 NC_CHAR_EMPTY_INSTANCE_DUNGEON_RNG
        {Start {own zoneNo, 0xFFFF, regnum}, i32 Category} (13 bytes); every zone's zrpb_Success @ FUN_005a8b70 runs
        DeleteDungeon{category, regnum, 0}
```

### 5.3 Level-select flow (ModeIDGate)

```
client clicks a ModeIDGate → (zone A) 0xA408 CHECK_REQ → WM → (zone B hosting the map) 0xA40A CHECK_ECHO_REQ
  → 0xA40B CHECK_ECHO_ACK → WM → (zone A) 0xA409 CHECK_ACK → client 0xA40C MENU_REQ → client 0xA40D MENU_ACK
  → (zone A) 0xA40E JOIN_REQ → WM → (zone B) 0xA410 JOIN_ECHO_REQ → 0xA411 JOIN_ECHO_ACK → WM → (zone A) 0xA40F JOIN_ACK
  → link
```

```
0xA40A NC_INSTANCE_DUNGEON_LEVEL_SELECT_CHECK_ECHO_REQ {u8 nStartZoneNum, u32 nCharRegNum, u32 nInDunRegNum,
        i32 IndunCategory, u16 nNPCHandle, ORToken Argument} @ FUN_00486ff0           (zone B)
    reply 0xA40B CHECK_ECHO_ACK {nStartZoneNum, nCharRegNum, nNPCHandle, u16 nError = 2, i32 eLevelType = 3}
    row = IDInfo_Find(Argument) (else log "InstanceDungeonInfo Data NULL", no reply)
    if row.zone != own zone: log "Invalid Zone Number", no reply
    if cm_FindExistByRegnum(row.map, nInDunRegNum, IndunCategory, &level): nError 0, eLevelType = level
    → WM

0xA409 NC_INSTANCE_DUNGEON_LEVEL_SELECT_CHECK_ACK {u32 nCharRegNum, u16 nNPCHandle, u16 nError, i32 eLevelType} @ FUN_00485540
    p = som_FindPlayer(nCharRegNum); role = NPCRoleTable_Find(nNPCHandle); npc object type 4 within 1000 units
    (each failure: log "Invalid NPC Handle1/2/3", "NPC Function NULL", "NPC Click Range Over"; no reply)
    menu = 0xA40C NC_INSTANCE_DUNGEON_LEVEL_SELECT_MENU_REQ {u16 nNPCHandle, Name3 sMapIndex, u8 nMenuCount, i32 eLevelType[]}
    nError 0 (a dungeon exists): one entry, the existing level (IDInfo_Find(key, eLevelType))
    nError 2 (none yet): one entry per level 0..2 that has a row; map name of the last row
    other: log "Invalid Error Type"
    if nMenuCount > 0: send to p; clear the request flag
    else: system text "RecallDisableField" / log "Indun Level Data Null"
    // the failure paths leave the request flag set, which blocks further ModeIDGate use until it is cleared
    // (original bug, inferred; Z08-B9)

0xA40D NC_INSTANCE_DUNGEON_LEVEL_SELECT_MENU_ACK {u16 nNPCHandle, i32 eLevelType} @ FUN_00485810   (client)
    require flag clear, no trade, empty server menu, mode mask 0x46 {1,2,6}; NPC role and object checks as above;
    eLevelType < 3 ("Invalid Level Type")
    row = IDInfo_Find(NPC key, eLevelType) ("Indun Info NULL")
    code = IDCondition(p, row, &regnum, &category); levels from the level table
    if LinkCondition_Report(code):
        → WM 0xA40E NC_INSTANCE_DUNGEON_LEVEL_SELECT_JOIN_REQ {nStartZoneNum, nDestZoneNum = row.zone, nCharRegNum,
             nInDunRegNum, IndunCategory, nNPCHandle, Argument = row key, eLevelType} (0x28); set the request flag

0xA410 NC_INSTANCE_DUNGEON_LEVEL_SELECT_JOIN_ECHO_REQ {…, ORToken Argument, i32 eLevelType} @ FUN_004871a0  (zone B)
    row = IDInfo_Find(Argument), lrow = IDInfo_Find(Argument, eLevelType) (else log, no reply); row.zone must be own zone
    reply 0xA411 JOIN_ECHO_ACK {nStartZoneNum, nCharRegNum, nNPCHandle, u16 nError, i32 eLevelType, Name3 sMapName} (0x19)
    inst = cm_FindExistByRegnum(row.map, nInDunRegNum, IndunCategory, &level)
    if !inst:
        inst = cm_FindEmptyByRegnum(…, eLevelType)
        if !inst: nError 1                                    // no free instance
        else: fm_ClearObject(inst, 0x3b0); set its script (row+0x23) and mode (lrow+0x43); start the script
    elif level != eLevelType: nError 5, eLevelType = level, sMapName = the instance's map   // fixed by the first entrant
    if inst and nError != 5: count the players in it (so_AllInMap1 over its centre object):
        nError = count < row.maxPlayers (+0x6b) ? 0 : 3; sMapName = instance map name
    → WM          // the "Packet Too Long" log names CHECK_ECHO_REQ (copy-paste)

0xA40F NC_INSTANCE_DUNGEON_LEVEL_SELECT_JOIN_ACK {u32 nCharRegNum, u16 nNPCHandle, u16 nError, i32 eLevelType, Name3 sMapName}
        @ FUN_00485b90                                                                         (zone A)
    p, NPC role, NPC object and range checks as in CHECK_ACK
    nError 0: row = IDInfo_Find(NPC key, eLevelType) (else log, clear flag); find the LinkTable row matching it
              (FUN_00427e10); link with that row and destination map sMapName:
              no item needed → so_LinkTo(…); else sp_DestroyItemB(p, slot, item, count, link) (consumes, then links)
              clear the flag
    nError 1: system text "CannotAddAnymore"; 3: "InstanceDungeonMaxPlayer"; 2: "RecallDisableField"; clear the flag
    nError 5: 0xA40C MENU_REQ {nNPCHandle, sMapName, 1, row.level} again (only the existing level); clear the flag
    other: log "Invalid Indun Find Error Code"; clear the flag

0xA402 NC_INSTANCE_DUNGEON_DELETE_DUNGEON_CMD {u8 Category, u32 RegisterNumber, u32 ReaderRegisterNumber} @ FUN_00484590
    leader = som_FindPlayer(ReaderRegisterNumber); if a player:
        server menu "ID_DeleteNow": "Yes" → smfm_DeleteInstanceDungeon({Category, RegisterNumber}), "No" → cancel
    // the WM asks the group leader whether to reset the dungeon

0xA417 NC_INSTANCE_DUNGEON_RANK_LIST_REQ (no body) @ FUN_00564db0 → sp_SendIndunList @ FUN_00564830
    → 0xA418 NC_INSTANCE_DUNGEON_RANK_LIST_ACK {u16 nMapCount, SHINE_INDUN_INFO[] {Name3 MapIDClient, u8 ModeIDLv}}
      one entry per instance-dungeon row of g_FieldList (FUN_00462840 count / FUN_00462850 row)
      // no mode check; the client opens it from 0x3C10 NC_MENU_INDUNRANK_CMD (NPC role MenuOpen "Ranking", Z02)
```

### 5.4 Leaving a group inside its dungeon

```
InstanceEjectAfterLeave(q, groupNo, category) *(ours)* @ FUN_00486c00       (from §1 0x380C/0x3816, §2 0xB017/0xB01C)
    require q in mode ≠ 0 and on a map whose data type (+0x36) is 3 (instance) *(inferred)*
    inst = cm_FindExistByRegnum(q.map name, groupNo, category)
    if inst == q's current map:
        if q is not dead: so_LinkToReserv (vt 0x3fc) to the map's return point (FUN_00453370 map name; position from the
            map row's exit table, index from DAT_14d720d0, ≤ 4 else exit 0)
        else: sp_ReviveReqProcess(q)
```

## 6. Friend points (dept 21)

```
0x5421 NC_FRIEND_UES_FRIEND_POINT_REQ (no body) @ FUN_0045a730 (profiler name sp_NC_FRIEND_UES_FRIEND_POINT_REQ)
    reply = 0x5422 NC_FRIEND_UES_FRIEND_POINT_ACK {u16 error, u16 friendpoint, u16 itemid, u8 numofitem}
    if mode ∉ {1,2} (mask 6): reply {0x36C1, 0, 0, 0}; return
    weighted draw over FriendPointReward.shn (`DAT_150bad20`, loader FUN_0064ca60; columns InxName, Lot, FPR_Rate):
        r = Random(1000); pick the first row whose cumulative FPR_Rate·1000/total ≥ r; item = ItemInfo[InxName], count = Lot
        // when the table is empty or all rates are 0 the item name buffer stays uninitialised and the lookup below
        // runs on stack garbage; normally it fails and nothing is sent (original bug, Z08-B10)
    if the item row is missing: return (no reply)
    count = min(count, item max stack (+0x6a))   ("Invalid item data" log when clipped)
    find a free inventory cell (InventoryCellLockList, kind 9); none: reply {0x36C4}; return
    build the new item (ItemAttrCls ctor, ItemKey_Make(id, 0x0B, zoneNo, worldNo)), cell = (9 << 10 | slot)
    → DB 0x34BF NC_ITEMDB_UES_FRIEND_POINT_REQ {ref, u16 cell, u16 logId("FriendUsePoint"), u16 lockIndex, item (0x6F bytes)}
    lock the cell (lock list .vt0x40), lockIndex++
```
The zone neither checks nor deducts the friend points; the Character DB does, and its answer 0x34C0
(`gds_NC_ITEMDB_UES_FRIEND_POINT_ACK` @ FUN_00469d00, Z05) sends 0x5422 and, for items listed as
"FriendBroadcastItemID", a broadcast. Client texts (client FUN_004ae070): "You have received (%s) %d with your friend
points.", "Cannot be used right now." (0x36C1), "Error has occurred. Please try again.", "You do not have enough Friend Points.".

## 7. Weapon titles / licences (dept 23) and character titles (dept 24)

### 7.1 Weapon licence

A weapon (ItemInfo class +0x66 = 5) carries three licence slots `{u16 mobId, u32 killCount}` in its attribute block; a
licence item (class 0x10) names a mob; the licence-clear item is `DAT_14d50498`.

```
0x5C01 NC_WT_LICENSE_REQ {ITEM_INVEN licenseitem, ITEM_INVEN weaponitem, u16 mobid, u8 bSet} @ FUN_0059e410
    reply 0x5C02 NC_WT_LICENSE_ACK {licenseitem, weaponitem, u8 bSet, u16 err} — bSet is never written on this path
    if mode ∉ {1,2,6} (mask 0x46): err 0x9BF
    weapon = cell weaponitem (inventory kind 8 = equipped via p+0x7fd8, kind 9 = bag via p+0x8e2c; other kinds: err 0x9BE)
    require weapon present and of class 5 (else 0x9BE)
    licence = bag cell licenseitem (must be kind 9, else 0x9BF)
    if licence.id == licence-clear item: sp_WeaponLicenseClear (below); return
    require licence class 0x10 and its mob id (attr vt 0x58) ≠ −1 (else 0x9BF)
    r = weapon attr .vt0x48(copy, mobId, p.name): 1 → 0x9BB (mob already registered), 2 → 0x9BC, 3 → 0x9BD
    else: lock both cells (lock list vt 0x30 / 0x40 with the new attribute copy)
          → DB 0x5C05 NC_WT_LICENSE_SET_REQ {ref, u16 lockindex, u32 chrregnum, Name5 chrname, WeaponItemKey, LicenItemKey,
                u16 LicenseMobID, echo {licenseitem, weaponitem}} (0x36); lockindex++; no client reply yet

sp_WeaponLicenseClear(p, req, weapon, clearItem) @ FUN_0059de20
    slot = weapon licence slot with mobId == req.mobid; none: 0x5C02 {…, bSet 0, 0x9C0}; return
    clear that slot in a copy; → DB 0x5C07 NC_WT_LICENSE_CLR_REQ {ref, lockindex, echo, WeaponItemKey, MobID,
        LicenseClearItemKey, LicenseClearItemID, u8 LicenseClearItemDelete = (clear item count == 1),
        LicenseClearAttr (the clear item's attribute with count − 1 when it is not deleted)}
    lock both cells; lockindex++

0x5C06 NC_WT_LICENSE_SET_ACK {ref, u16 Error, u16 lockindex, echo {licenseitem, weaponitem}} @ FUN_0059dab0
    p by handle, not closing (charNo not compared: original bug, Z08-B14)
    if Error == 0x9B9: lock list.apply(lockindex) ("gds_NC_WT_LICENSE_SET_ACK" log on failure);
                       CQuestZone.QuestPlayer_ScenarioDone_Server(7)      // tutorial / quest scenario step 7
    else: lock list.cancel(lockindex)
    → 0x5C02 {echo.licenseitem, echo.weaponitem, bSet (not written, stale g_buf byte), Error}

0x5C08 NC_WT_LICENSE_CLR_ACK {ref, u16 lockindex, echo, WeaponItemKey, u16 MobID, u16 ErrorCode} @ FUN_0059d920
    ErrorCode == 0x9E1: apply the lock, else cancel; → 0x5C02 {echo…, bSet 0, ErrorCode}

0x5C0A NC_WT_MOB_KILLCOUNT_SET_ACK @ LAB_0059dc60, 0x5C0C NC_WT_TITLE_SET_ACK @ LAB_0059dcb0
    empty bodies (disassembly: profiler enter/leave only); the zone ignores the DB answers to 0x5C09 / 0x5C0B
```
Codes: 0x9B9 set OK, 0x9E1 clear OK, 0x9BB "Cannot register the same monster." (client FUN_004ae340), 0x9BC/0x9BD other
attribute refusals, 0x9BE wrong weapon, 0x9BF wrong mode / licence item, 0x9C0 the weapon has no licence for that mob.
The client picks the success text from `bSet` (offset 4), which the zone leaves uninitialised on the set path
(original bug, Z08-B11). Kill counts and weapon titles are updated elsewhere (`so_weapontitle`, 0x5C03
NC_WT_GRADE_CMD; Z03/Z09).

### 7.2 Character titles

The title state is `CCharacterTitleZone` (`vt 0x420`; current title at +0x488 type, +0x489 element). Title → abstate
table `DAT_1328c128` (`[type 0..127][element 0..3]`, 0x4C bytes: count, then {abstate rows} × count).

```
0x6001 NC_CT_SET_CURRENT_REQ {u8 Type, u8 ElementNo, u16 MobID} @ FUN_005cb100
    reply 0x6002 NC_CT_SET_CURRENT_ACK {Type, ElementNo, MobID, u16 Error}
    if mode ∉ {1,2} (mask 6): Error 0xA03            // client then says "while Camping" or "while on a Mover"
    elif g_Now ≤ p+0x2aa48: Error 0xA04             // "Please wait 10 seconds between changing titles."
    elif !title.Owns(Type, ElementNo) (FUN_0062e250): Error 0xA02
    elif Type == 10 (weapon title): the equipped weapon (vt 0x7ac) must hold a weapon title for MobID
         (FUN_0059d720 over the WT table DAT_1328bf78), else 0xA02; write MobID into the weapon attribute (+0x23) and save
         it (sp_AttrChange2DB); the element comes from the WT row
    else:
        old = current title; re-evaluate it (FUN_005ca6d0 levels 1/2, FUN_005caf70); set the new current title
        (FUN_0062e2e0, FUN_0062e440(…, 3))
        → DB 0x6008 NC_CT_SET_CURRENT_DB_CMD {ref, CurrentTitle, CurrentTitleElement, CurrentTitleMobID, CT_INFO UseTitle,
              CT_INFO UseAbleTitle} (flag bits 0xC0 / 0x8000 mark the entries)
        reply Error 0xA01; p+0x2aa48 = g_Now + 100 (10 s)
        recompute the character (vt 0x4b4, position kept)
        remove the old title's abstates (vt 0x650 + asl_AbstateReset), run the abstate routine, apply the new title's
        abstates (vt 0x638, BriefAbstateBit_Set, so_AbnormalState_BroadcastSet)

0x6006 NC_CT_CHARTTING_CMD {ref} @ FUN_005a3ce0
    p by handle, not closing → title: clear the u64 counter at +0x728 (dirty flag +0x730), re-evaluate condition 0x29
    (FUN_005cc2a0)                                       // WM-reported chat event for a chat title
0x6007 NC_CT_ADD_FRIEND_CMD {ref, u16 NumberOfFriends} @ FUN_005a3dc0
    title: friend counter (+0x6b8) = NumberOfFriends (dirty +0x6c0); re-evaluate condition 0x22 (FUN_005cc230)
```
Both WM commands look the player up by handle only (charNo not compared; original bug, Z08-B14).

## 8. Guild, guild war and guild tournament: zone side (dept 29)

Guild membership on the zone: `vt 0x818` guild number (`p+0x2a31c`), `vt 0x81c` set it, `vt 0x820` set the guild record,
`vt 0x824` `so_ply_BroadcastGuildInfo`. The zone's guild list is `CGuildZone` (`g_GuildWars` in the names file,
DAT_13296e08; records = `GUILD_ZONE` *(pdb2017, 0x31 bytes: nNo, sName[16], nMoney, nType, nGrade, nFame, nStoneLevel,
nExp, nWarStatus, nWarEnemy)* plus +0x34 "enemy of" and a list index); `CGuildZone_Find(no)` @ FUN_005ccd70. Guild war
pairs are also kept in `DAT_00755298` (FUN_004810e0 add, FUN_00481140 remove, FUN_00481040 clear). Guild storage
records: `g_GuildStorage` (`FUN_004751f0(&g_GuildStorage, guildNo, &idx)`, +0x1068 guildNo, token count FUN_004749e0 /
FUN_004749f0). The tournament state is per map (`FieldMap_fm_GetGuildTournamentSystem(p.map)`) plus a seed table
`DAT_0d55a3e0[seed]` (0x24 bytes per seed, seed map numbers in `DAT_0d55a860[seed·13]`).

### 8.1 Client requests

```
0x7491 NC_GUILD_STORAGEOPEN_REQ (no body) @ FUN_004762d0
    if p.guildNo == 0: sp_GuildStorageError(0x1242)       // 0x7492 NC_GUILD_STORAGEOPEN_ACK, "not registered in any guild"
    else: → DB 0x3471 NC_ITEMDB_OPEN_GUILD_STORAGE_REQ {ref, u32 guildregnum}
          → WM 0x749E NC_GUILD_STORAGE_WITHDRAW_GRADE_REQ {ref}
    // no mode check, no NPC/range check

0x74A0 NC_ITEMDB_CLOSE_GUILD_STORAGE_CMD (no body) @ FUN_00476220 → vt 0x82c @ FUN_00477420
    if p has an open guild-storage handle (vt 0x830 ≠ −1): find the storage record; count the players that still have
    it open (ShineGuildStorageDeactive visitor over g_PlayerList); if fewer than 2, release the record (FUN_00474970);
    clear the handle (vt 0x834(0xFFFF))

0x74AC NC_GUILD_RENAME_REQ {u8 nItemSlot, Name4 sGuildName} @ FUN_00473550
    errors → SendErrorCode(29, 173) = 0x74AD NC_GUILD_RENAME_ACK {err}
    mode ∉ {1,2,4,6} (mask 0x56) / map forbids items (FieldList CanItem +0x9e == 0): 0x1A41 / 0x1A42
        (0x1A42 = "Request cannot be processed at a current location"; which of the two belongs to which test is not
        certain from the decompile)
    an NPC menu or storage open (p+0x18248 & 0x0C): 0x1A42
    slot ≥ bag size: 0x1A43 ("wrong slot"); cell locked: 0x1A44; item ≠ the rename item (special item table +0x3c):
    0x1A43 "Incorrect item."; lot 0 / empty cell: 0x1A45
    else → WM 0x74AF NC_GUILD_WORLD_RENAME_REQ {ref, u8 nItemSlot, Name4 sGuildName} (0x17)

0x74B4 NC_GUILD_RETYPE_REQ {u8 nItemSlot, u8 nType} @ FUN_00473860
    same checks with codes 0x1A59/0x1A5A (mode / location), 0x1A5B (slot/item), 0x1A5C (locked), 0x1A5D (lot 0 / empty)
    → SendErrorCode(29, 181) = 0x74B5; else → WM 0x74B7 NC_GUILD_WORLD_RETYPE_REQ {ref, nItemSlot, nType}

0x749C NC_GUILD_TOURNAMENT_RECALL_ENTER_REQ {u8 ack} @ FUN_004783c0
    reply 0x749D NC_GUILD_TOURNAMENT_RECALL_ENTER_ACK {u16 err} through send object vt 0x2f8
    if ack == 0: err 0x1441 (declined)
    seed = p+0x5e0e (0xFF none, must be < 32)
    if the seed's entry window is closed (FUN_004757f0): err 0x1444 ("Entry Time is Over")
    elif p is not registered for the seed (FUN_004782d0): log only
    elif FUN_00478320 (may enter): err 0x1440; so_ply_Summon2GuildTournament(seed entry, 0, 0) (vt 0x924)
    // other combinations send nothing

0x74CA NC_GUILD_TOURNAMENT_FLAGCAPTURE_REQ {u16 hTargetFlag} @ FUN_00475b80 → vt 0x930 so_ply_FlagCaptureCast @ FUN_00477d90
    replies 0x74CB NC_GUILD_TOURNAMENT_FLAGCAPTURE_ACK {err} (FUN_00475cd0); texts from TextData2:
    no tournament on this map 0x1B42 "It is not the Guild Tournament Map"; flag already captured 0x1B48;
    not a participant 0x1B4F; flag object farther than 100 units 0x1B52 "The Flag is a long way off"
    riding a mount (mode 6, ride kind 2): get off first (MoverSystem_RideOff, sp_HorseOff)
    mode in mask 0x38 {3,4,5} or abstate 0x123 / movement-locked (Fear bit, vt 0xf20, FUN_004c8e80): 0x1B45
    already casting (p+0x5e06 ≠ −1): 0x1B46 "You are capturing the flag"
    else: stop any action (vt 0xea0 → 0x8d0); remove abstates 0x4B and 0x175; ack 0x1B40 and broadcast (FUN_00475d40);
          cast timer (p+0x2a784, 4000, callback FUN_00477c00); p+0x5e06 = flag handle;
          → client 0x2047 NC_ACT_CREATECASTBAR {u16 4000}

0x74CF NC_GUILD_TOURNAMENT_USESKILL_REQ {u16 wUseSkillNumber} @ FUN_00477b20
    no tournament: 0x74D0 NC_GUILD_TOURNAMENT_USESKILL_ACK {0x1B42, 0xFFFF}
    else: error sink = FUN_00476d70; if GTSystem.UseSkill(p, n) @ FUN_0047b9a0: ack {0x1B40, n} and broadcast
          0x74D1 NC_GUILD_TOURNAMENT_USESKILL_CMD {u32 guildNo, u16 n} to the map (FUN_00475bd0)
    // skill errors (0x1B4B points, 0x1B4C authority, 0x1B4D invalid, 0x1B50 cool time) come from the GT system

0x74D3 NC_GUILD_TOURNAMENT_DICEGAME_THROW_REQ (no body) @ FUN_00477ba0
    no tournament: 0x74D4 NC_GUILD_TOURNAMENT_DICEGAME_THROW_ACK {0x1B42}; else GTSystem.DiceThrow(p) @ FUN_0047af20
    (errors through FUN_00475e30, e.g. 0x1B4E "The Dice is cast")

0x74D7 NC_GUILD_TOURNAMENT_OBSERVER_ENTER_REQ {u8 nTournamentSeed} @ FUN_00476c50
    → WM 0x74D9 NC_GUILD_TOURNAMENT_ZONE_OBSERVER_ENTER_REQ {u8 seed, u16 p.handle}       // no checks

0x74DB NC_GUILD_TOURNAMENT_OBSERVER_OUT_REQ {u8 seed} @ FUN_00476cc0
    if FUN_00570b80(p) == 0 and the map is a tournament map (FUN_00475770): sp_2Roumen(p)    // back to Roumen; no ack
```

### 8.2 WM / DB messages

```
0x7443 NC_GUILD_ZONE_WAR_START_CMD {u32 nNo, u32 nEnemyNo} @ FUN_005a3ea0
    war pair add; CGuildZone_StartWar @ FUN_005cce70: guild nNo nWarStatus = 2, nWarEnemy = nEnemyNo; enemy +0x34 = nNo
0x7444 NC_GUILD_ZONE_WAR_END_CMD {nNo, nEnemyNo} @ FUN_005a3f60       → pair remove; CGuildZone_EndWar @ FUN_005ccec0
0x7479 NC_GUILD_GUILDWARCONFIRM_ACK {guildwarA, guildwarB} @ FUN_0042e520 → StartWar for each pair with both numbers ≠ 0
0x7496 NC_GUILD_GUILDWARSTATUS_ACK {u16 warnumber, {nNo, nEnemyNo}[]} @ FUN_005a46d0
    clear all war states (FUN_005ccce0) and pairs; StartWar + pair add for every entry

0x7447 NC_GUILD_ZONE_LIST_ACK {u8 PartMask, u16 NumOfList, GUILD_ZONE[]} @ FUN_005a4020 → @ FUN_005cd070
    PartMask bit 0: clear the list first; append every record ("CGuildZone::ClearWar : Guild Buffer Full."); bit 1: list
    complete (+4 = 1)                                         // sent in parts at zone start
0x7448 NC_GUILD_ZONE_MAKE_CMD {u32 nGuildMasterCharNo, GUILD_ZONE} @ FUN_005a40d0 → @ FUN_005cca80
    add the record; if the master is here: set guild number/record; lock and take 1,000,000 cen (lock list vt 0x48 money
    lock + apply; "Recv_NC_GUILD_ZONE_MAKE_CMD" log on failure) = the guild creation fee; broadcast guild info
0x7449 NC_GUILD_ZONE_DELETE_CMD {u32 nNo} @ FUN_005a4180 → @ FUN_005cd1e0
    DeleteDungeon{kind 1 (guild), nNo}; every local member: guild 0, record NULL, broadcast; then vt 0x85c (academy side)
    and the record is removed (not expanded); the player loop has the same unchecked list-cell pattern as 0x441C
0x744A NC_GUILD_ZONE_MEMBER_JOIN_CMD {u32 nNo, u32 nCharNo} @ FUN_005a4230
    q = som_FindPlayer(nCharNo), not closing, guild record exists: set guild nNo + record; broadcast; FUN_0063ec90
0x744B NC_GUILD_ZONE_MEMBER_LEAVE_CMD {u32 nCharNo} @ FUN_005a4340
    q not closing: close guild storage (vt 0x82c); vt 0x844; InstanceEjectAfterLeave(q, guildNo, 1) (§5.4);
    guild 0, record NULL; broadcast; FUN_0063ec90

0x749F NC_GUILD_STORAGE_WITHDRAW_GRADE_ACK {ref, u16 err, u8 Grade} @ FUN_005a48f0
    if err == 0xC41 and ref.charNo ≠ −1: q = som_FindPlayer(charNo), not closing: vt 0x5ec(Grade) (withdraw rights)
0x74B0 NC_GUILD_WORLD_RENAME_ACK {ref, u8 nItemSlot, Name4 sGuildName, u16 err} @ FUN_005a4ad0
    q by ref.charNo: err 0x1A40 → so_ply_GuildReName(slot, name) @ FUN_00474650 (consumes the item, renames, informs);
    else SendErrorCode(29, 173, err)
0x74B8 NC_GUILD_WORLD_RETYPE_ACK {ref, u8 nItemSlot, u8 nType, u16 err} @ FUN_005a4bf0
    err 0x1A58 → so_ply_GuildReType(slot, type) @ FUN_00473c00; else SendErrorCode(29, 181, err)
0x74C1 NC_GUILD_WORLD_USE_GUILD_TOKEN_CMD {u32 nGuildNo, u64 nDecreaseGuildToken, u64 nRestGuildToken} @ FUN_00477810
    storage record of nGuildNo: tokens = max(0, tokens − nDecrease); if tokens ≠ nRestGuildToken: tokens = nRest (WM wins)

0x7481 NC_GUILD_TOURNAMENT_START_CMD {u8 nTournamentSeed, u16 nTournamentMapNo, u16 nExploerTimeMin, u16 nWaitPlayTimeSec,
        u16 nPlayTimeMin, u32 nNo1, u32 nNo2} @ FUN_00477a10
    seed ≥ 33: log "Invalid seed"
    if the seed entry is in use: log "Seed not empty. May be RE-Match."; mark it 0xFF
    nTournamentMapNo is overwritten with the zone's own map number for the seed (DAT_0d55a860[seed·13])
    wms_GuildTournamantStart(body)                       // builds the tournament map (not expanded)
    // the seed bound is 33 here but 32 in 0x749C (original bug, Z08-B12)
0x74C7 NC_GUILD_TOURNAMENT_ZONE_MEMBERGRADE_ACK {u16 Error, u8 seed, u32 nGuildNo, u16 nGuildMemberCnt, {u32 charNo, u8 grade}[]}
        @ FUN_00476460 (profiler name …TOURNAMENT_MEMBERGRADE_ACK)
    Error 7000: FUN_0047ccd0(charNo, grade) for each entry; 0x1B59 / 0x1B5A logged as
    ERR_GUILDTOURNAMENT_MEMBERGRADE_NOT_FOUND / …_NOT_TOURNAMENT; other codes logged
0x74DA NC_GUILD_TOURNAMENT_ZONE_OBSERVER_ENTER_ACK {u16 err, u8 seed, u16 nPlayerHnd} @ FUN_00478be0
    q = ShinePlayer at nPlayerHnd: err 0x1B60 → enter as observer (FUN_004788c0(q, seed));
    0x1B61 → client 0x74D8 OBSERVER_ENTER_ACK {0x1B61} (FUN_004781a0); 0x1B62 → {0x1B54}; other codes ignored
0x74E3 NC_GUILD_TOURNAMENT_ZONE_JOIN_NEW_REQ {u16 hWMChar, u32 nCharNo, u32 nGTNo, u32 nGuildNo, u8 nMinLevel, u16 nMinMember,
        u64 nProposalMoney} @ FUN_004766f0
    q = som_FindPlayer(nCharNo) not closing; e = q.vt0x934(body) @ FUN_00476860 (checks; on success locks the proposal
    money and asks the DB with 0x74E5 NC_GUILD_TOURNAMENT_DB_JOIN_NEW_REQ)
    if e ≠ 0x1C40: → WM 0x74E4 NC_GUILD_TOURNAMENT_ZONE_JOIN_NEW_ACK {e, body}
0x74E6 NC_GUILD_TOURNAMENT_DB_JOIN_NEW_ACK {ref, u16 lockindex, u16 Error, hWMChar, nCharNo, nGTNo, nGuildNo, nMinLevel,
        nMinMember, nProposalMoney} @ FUN_00476a10
    → WM 0x74E4 {Error, hWMChar, nCharNo, nGTNo, nGuildNo, ?, ?, nProposalMoney}
       // nMinLevel and nMinMember are not copied (stale g_buf bytes, original bug Z08-B13)
    q by ref: Error 0x1C40 → lock list.apply(lockindex) (money taken); else lock list.cancel(lockindex)
0x74F4 NC_GUILD_TOURNAMENT_GOLD_REFUND_ZONE_CMD @ LAB_00476c00: empty body (disassembly)
```

## 9. Holy promise (master / trainee, dept 37)

```
0x943C NC_HOLY_PROMISE_GET_CEN_REWARD_REQ (no body) @ FUN_00483c10
    → DB 0x943E NC_HOLY_PROMISE_DB_GET_CEN_REWARD_REQ {ref}               // no mode or other checks
0x943F NC_HOLY_PROMISE_DB_GET_CEN_REWARD_ACK {ref, u16 nError, u64 nMoney} @ FUN_00483d10
    p = som_GetObject(ref.handle) (charNo and closing not checked) → vt 0x9d0 @ FUN_00483dd0:
    → client 0x943D NC_HOLY_PROMISE_GET_CEN_REWARD_ACK {nError, nMoney}    // shows the reward that can be withdrawn

0x9440 NC_HOLY_PROMISE_WITHDRAW_CEN_REWARD_REQ (no body) @ FUN_00483ed0
    if the inventory has locked cells (InventoryLocking vt 0x10): → client 0x9441 {0x1C6C, 0}
    else → DB 0x9442 NC_HOLY_PROMISE_DB_WITHDRAW_CEN_REWARD_REQ {ref}
0x9443 NC_HOLY_PROMISE_DB_WITHDRAW_CEN_REWARD_ACK {ref, u16 nError, u64 nMoney} @ FUN_00484040
    p = som_GetObject(ref.handle) (no charNo / closing check) → vt 0x9d4 @ FUN_00484100:
    if nError == 0x1C68 (success): p.money += nMoney (vt 0x434 / 0x440, no upper limit), send the money update (vt 0x448)
    → client 0x9441 NC_HOLY_PROMISE_WITHDRAW_CEN_REWARD_ACK {nError, nMoney}
    // money goes to whatever object now has that handle (original bug, Z08-B14)

0x9432 NC_HOLY_PROMISE_MY_UP_ZONE {u32 nCharNo, u32 nUpCharNo} @ FUN_004835f0 (profiler string "…MYUPPER_ACK")
0x9435 NC_HOLY_PROMISE_MYUPPER_ACK {ref, u32 nUpCharNo} @ FUN_004836b0
    both call so_ply_HolyPromiseSet (vt 0x9c0) @ FUN_00483780, an **empty function** in 2016: the zone does not keep the
    master's charNo; the request 0x9434 NC_HOLY_PROMISE_MYUPPER_REQ is still sent at login (W04)
```

## 10. Guild academy (dept 38)

Academy membership: `vt 0x858` kind (0 guild member, 1 academy member), `vt 0x85c` academy number, `vt 0x860` set it,
`vt 0x864` set the academy's guild record, `vt 0x854` `so_ply_BroadcastGuildAcademyInfo`; reward-storage "open" flags
`p+0x17d06…+0x17d08` (one per open type).

```
0x986D NC_GUILD_ACADEMY_REWARD_STORAGE_OPEN_REQ {u8 nOpenType} @ FUN_0046f550
    no = kind 0 ? guildNo : kind 1 ? academyNo : —; otherwise (or no == 0) error 0x17DA (FUN_00470d50)
    → DB 0x3482 NC_ITEMDB_GUILD_ACADEMY_REWARD_STORAGE_OPEN_REQ {ref, u32 guildregnum = no, u8 nOpenType}
    → WM 0x9870 NC_GUILD_ACADEMY_REWARD_STORAGE_WITHDRAW_GRADE_REQ {ref}
0x986F NC_GUILD_ACADEMY_REWARD_STORAGE_CLOSE_CMD {u8 nCloseType} @ FUN_0046f460
    nCloseType ≥ 3: log "nCloseType Error"
    else: flag[nCloseType] = 0; when none of the three is still open: close the reward storage (vt 0x844 @ FUN_0046f7f0)
0x986C NC_GUILD_ACADEMY_DB_ACADEMY_REWARD_ACK {ref, u16 Error, nCharNo, nGuildNo, nWantMoney, nWantItemCnt, WantItem,
        nSubAcademyMoney, nStorageMoney, u8 nModifyItemCnt, EACH_MODIFY_ITEM[]} @ FUN_0046f380
    p by ref (charNo, not closing) → so_ply_GuildAcademyRewardStorageRewardZoneRng (vt 0x878) @ FUN_0046e750 (not expanded)

0x9871 NC_GUILD_ACADEMY_REWARD_STORAGE_WITHDRAW_GRADE_ACK {ref, u16 err, u8 Grade} @ FUN_005a49e0
    err 0x1780 and charNo ≠ −1: q = som_FindPlayer(charNo) not closing → vt 0x870(Grade) @ FUN_0046dea0
0x9886 NC_GUILD_ACADEMY_REWARDSTORAGE_GRADE_INFO_CMD {u32 nCharNo, u32 nGuildNo, u8 Grade} @ FUN_0046f0d0
    q = som_FindPlayer(nCharNo) ("shineobject null"); if q.guildNo == nGuildNo: vt 0x870(Grade) (else log "guild number")
0x9876 NC_GUILD_ACADEMY_ZONE_MEMBER_JOIN_CMD {u32 nNo, u32 nCharNo} @ FUN_0046eaa0
    q not closing and guild nNo known: academy = nNo, record; broadcast academy info; FUN_0063ec90
0x9877 NC_GUILD_ACADEMY_ZONE_MEMBER_LEAVE_CMD {u32 nCharNo} @ FUN_0046ebb0 (profiler string "…MEMBER_JOIN_CMD")
    q not closing: close the reward storage; academy 0, record NULL; broadcast; FUN_0063ec90
0x9879 NC_GUILD_ACADEMY_ZONE_MEMBER_GUILD_JOIN_CMD {u32 nNo, u32 nCharNo} @ FUN_0046ee20
    academy member promoted into the guild: guild = nNo + record, academy 0 / NULL, broadcast guild info; FUN_0063ec90
0x9878 NC_GUILD_ACADEMY_ZONE_MASTER_TELEPORT_CMD {u32 nMasterCharNo, Name5 sTargetCharID} @ FUN_0046ecb0
    master = som_FindPlayer(nMasterCharNo), not closing
    if the target is on this zone: r = FUN_004621f0(master, target) (local summon to the member);
        r == 2 → SendErrorCode(38, 32, 0x3E00) = 0x9820 NC_GUILD_ACADEMY_MASTER_TELEPORT_ACK
        ("Unable to Travel to Academy Member due Level Restriction on Map", …)
    elif master.vt0xa74(): ZoneRingPacketFindPlayerByNormalUser.zrpb_Request(master, {name, …}) (cross-zone lookup)
0x987A NC_GUILD_ACADEMY_ZONE_GUILD_BUFF_CMD {char BuffName[32], u32 NumOfGuild, u32 Guild[]} @ FUN_0046ef50
    visitor FUN_0046e070 over g_PlayerList: members of the listed guilds get the named buff
0x987B NC_GUILD_ACADEMY_ZONE_GUILD_ACADEMY_MASTER_BUFF_CMD {u32 NumOfMaster, GUILD_MASTER_BUFF[]} @ FUN_0046f010
    visitor ShineGuildAcademyMasterBuff over g_PlayerList (not expanded)
```

## 11. Charged stat / skill-empower reset (dept 36, DB answers)

The reset items (Z04/Z07 item use) lock the item cell and ask the DB with 0x9005 / 0x9006
`{ref, lockindex, restatitemkey, restatitemid, isdelete, attr}`.

```
0x9007 NC_CHARGED_STAT_INITIALIZE_DB_SUC_ACK {ref, u16 lockindex} @ FUN_00518650
    p by ref (charNo, not closing); lock list.apply(lockindex) ("…DB_SUC_ACK" log on failure)
    so_ply_InitFreeStat (vt 0x378) @ FUN_00518ab0: spent points STR…SPR (p+0x7f94…0x7f98) = 0; rebuild the stats
        (FUN_00517b60); → client 0x900C NC_CHARGED_STAT_INITIALIZE_SUC_CMD {u8 free points = points of the level (class table +0x33) − spent}; vt 0x34(1)
0x9008 NC_CHARGED_SKILLEMPOW_INITIALIZE_DB_SUC_ACK {ref, lockindex} @ FUN_00518780
    apply; so_ply_InitSkillEmpow (vt 0x37c) @ FUN_00518c00: csl_EmpowerClear; → client 0x900D NC_CHARGED_SKILLEMPOW_INITIALIZE_SUC_CMD {u8 free empower points}
0x9009 NC_CHARGED_STAT_INITIALIZE_DB_FAIL_ACK {ref, lockindex, u16 err} @ FUN_005188b0
    lock list.cancel(lockindex); SendErrorCode(36, 14, err) = 0x900E NC_CHARGED_STAT_INITIALIZE_FAIL_CMD
0x900A NC_CHARGED_SKILLEMPOW_INITIALIZE_DB_FAIL_ACK {ref, lockindex, err} @ FUN_005189b0
    cancel; SendErrorCode(36, 15, err) = 0x900F
    // the 2016 GameFrameWork ignores 0x900E/0x900F (C01): failures are silent for the player
```

## 12. Prison (dept 31, WM → zone)

```
0x7C13 NC_ZONE_PRISON_GO_REQ {nGmHandler, nGmRegNum, sGmUserID[256], sCharID, nCharSessHandle, nCharZoneHandle, nCharRegNum,
        u16 nMinute, sReason[16], sRemark[64]} @ FUN_005a4470                                   (GM command)
    err = 0xDC0
    q = som_GetObject(nCharZoneHandle), not closing, charNo == nCharRegNum:
        err = so_Prison_Go(nMinute) @ FUN_005b94b0 ? 0xDC1 : 0xDC2
        // so_Prison_Go: needs mode ≠ 0 and a map; links to map "EldPri" at its regen point (a dead player is revived
        // first with HP = maxHP·0x133/1024 ≈ 30 %); the minutes are kept for the release timer (not expanded)
    → WM 0x7C14 NC_ZONE_PRISON_GO_ACK {copy of the request, u16 err} (0x176)
0x7C12 NC_ZONE_PRISON_END_CMD {u16 nCharZoneHandle, u32 nCharRegNum} @ FUN_005a60f0
    q = ShinePlayer at the handle, not closing, charNo matches → so_Prison_End(0, 0) (vt 0x8a8) @ FUN_005b9730
```

## 13. GM events (dept 52, WM → zone)

```
0xD00B NC_EVENT_ADD_UPDATE_EVENT_CMD {GM_EVENT_DATA EventData (0x553)} @ FUN_0046ddf0 → @ FUN_0046dce0
    g_GMEvents *(ours)* = vector at DAT_14d42940 of 0x958-byte records keyed by u16 event number (first field):
    an existing number is overwritten in place, otherwise the record is appended; then FUN_0046d5c0 (activate) runs
0xD00C NC_EVENT_DEL_EVENT_CMD {u16 nEventNo} @ FUN_0046dae0 → FUN_0046da60 removes it
```
The event effects (exp/drop rates etc.) are applied where the records are read (Z09).

## 14. Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z08-B1 | `pm_Sendmemberinfo` @ FUN_004cc9f0 (0x3801/0x3808) | builds a full 0x3832 member list in `g_buf` and never sends it | wasted work; harmless (the tick sender §1.2 covers it) | send the list to the members, or drop the build |
| Z08-B2 | 0x380C / 0x3816 @ FUN_004cda00 / FUN_004cdb20 | a member who is on this zone but has no party key (`GetPartyKey` false) is skipped entirely | the zone's party record keeps a member the WM removed | always remove from the record; only the instance eject needs the key |
| Z08-B3 | 0x382A → `Party_SetMaster` @ FUN_00645870 | unknown new master → `FUN_0064f3c0(1, "Msg", "%s")` with no argument | reads a random stack value as a string (debug dialog / log) | pass the message text |
| Z08-B4 | 0x384D @ FUN_004cc2a0 | logs the 0x381F DISMISS text on a bad partyNo | misleading log | own text |
| Z08-B5 | 0xB01C NC_RAID_ZONE_VANISH_CMD @ FUN_005a5040 | calls `InstanceEjectAfterLeave(q, nVanishCharNo, 3)` twice, passing the **charNo** as raidNo | the raid-dungeon eject never matches; a vanished member stays inside | `(q, nRaidNo, 3)` once, as 0xB017 does |
| Z08-B6 | 0x4407 → `Recv_NC_QUEST_GIVE_UP_REQ` @ FUN_005bd960 | when FUN_006304d0 refuses the give-up, no 0x4408 is sent | client waits without feedback | answer with an error code |
| Z08-B7 | 0x441C @ FUN_005a6520 (same pattern in 0x7449 @ FUN_005cd1e0) | the player-list loop calls a virtual method through the cell pointer without testing the "used" flag / NULL | crash if an unused cell is linked in the list | skip empty cells |
| Z08-B8 | 0x580D @ FUN_00497790 | when a KQ map is not hosted on this zone, the KQ is created but no 0x580E answer is sent (uncertain whether the WM expects one) | WM may wait for a MAKE answer | always answer |
| Z08-B9 | 0xA409 @ FUN_00485540 | failure paths (NPC gone, out of range, no level rows) only log and leave the "request in flight" bit (`p+0x5cb9` bit 7) set *(inferred)* | ModeIDGate and MENU_ACK stay blocked for the player | clear the bit on every exit |
| Z08-B10 | 0x5421 @ FUN_0045a730 | an empty FriendPointReward table (or all rates 0) leaves the item-name buffer uninitialised and looks it up | undefined item lookup; usually silent failure, no reply | reply with an error |
| Z08-B11 | 0x5C01 / 0x5C06 → 0x5C02 | `bSet` (payload +4) is never written on the request-error and set paths | the client chooses its result text from a stale byte | copy `bSet` from the request (echo) |
| Z08-B12 | 0x7481 @ FUN_00477a10 vs 0x749C @ FUN_004783c0 | seed accepted when `< 33` at start but only `< 32` for recall | seed 32 can start but its players cannot enter | one bound (table size) |
| Z08-B13 | 0x74E6 @ FUN_00476a10 | forwards 0x74E4 without copying `nMinLevel` / `nMinMember` | WM gets stale bytes for both fields | copy the full body |
| Z08-B14 | 0x943F / 0x9443 @ FUN_00483d10 / FUN_00484040 (also 0x5C06, 0x6006, 0x6007) | the player is looked up by the handle of `ref` only; charNo and closing are not compared | after a reconnect a different player with the reused handle gets the answer — for 0x9443 the **money** | compare `ref.charNo` like the other DB handlers |
| Z08-B15 | 0x4414 @ FUN_00578e90 | `this + 0x173e8 == NULL` test (address of a member) | dead check | none needed |

## 15. Not reconstructed / uncertain

- **Quest script engine:** the runner (`+0xb8`, FUN_006387f0), IF/GOTO/MARK semantics, CALLPS (`PsStart`), scenario
  run/done (`QuestPlayer_ScenarioRun` / `ScenarioDone_Server`), `QuestCheckReward` / `QuestTakeReward` (0x441A body,
  inventory locks) and the start/end condition functions (FUN_0062fee0, FUN_006300d0, FUN_00630570) are named, not
  expanded. NPC-click quest start (`QuestPlayer_NPCClick*`) and mob-kill progress (`QuestActionMobKill`,
  0x440D NOTIFY_MOB_KILL) are reached from Z02/Z09 paths, not from this item's handlers.
- **Quest error numbers 0xB41…0xC10** have no client error-table text; meanings are from the code paths only.
- **KQ:** `kqe_QuestStart`, the KQ map script (ScenarioBookShelf), `KQPlayerInfoList` (knock-downs, revives), contribution
  scoring (`KQContributeList`) and the reward request (0x5815) are not expanded. How the client obtains `EncHandle` for
  0x581A is open (the 2016 GameFrameWork ignores 0x5819).
- **Instance dungeons:** `MapClusterManager` internals (empty/exist search, routine, limit time/items, films), the zone-ring
  FIND/EMPTY handlers on the ZoneListenSession side (0xA404 / 0x10B1, not in this item) and the IDGate menu data path
  (`ServerMenuActor` data layout `{regnum, key, …, category}`) are described from the senders only. Map data type 3 =
  instance is inferred.
- **Guild tournament:** `wms_GuildTournamantStart`, the per-map GT system (flag capture end, skills, dice game, observer
  handling, recall), `so_ply_Summon2GuildTournament` and `FUN_00476860` (JOIN_NEW checks) are not expanded. The order
  of 0x1A41 / 0x1A42 (and 0x1A59 / 0x1A5A) between "mode" and "location" is uncertain (decompiler inversion).
- **Raid status packets** (FUN_005cd9c0 / FUN_005cdb50 / FUN_005cda50 / FUN_005cdc00) and the raid record class (FUN_0063d…)
  are not expanded; raid opcodes 0xB020–0xB026 are *(pdb2017)* names.
- **Guild academy reward storage** (`so_ply_GuildAcademyRewardStorageRewardZoneRng`, 0x986C body), academy buffs and the
  cross-zone master teleport ring packet are not expanded.
- **Prison:** the release timer and the meaning of 0xDC1 vs 0xDC2 (`so_Prison_Go` result) are not verified.
- **GM events:** `GM_EVENT_DATA` fields and what `FUN_0046d5c0` activates (Z09).
- No capture contains any of these messages; nothing here is *(captured)*.
