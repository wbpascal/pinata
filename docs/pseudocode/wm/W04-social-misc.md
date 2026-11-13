# World Manager: friends, chat routing, KQ, holy promise, instances, misc (W04)

Source: `Files/Server/2016/w00_WorldManager/4WorldManagerServer2.exe` (2016), Ghidra export `re-data/exports/wm`.
Each block cites the function it was reconstructed from (`@ FUN_xxxxxxxx`). View the original with

```
python3 -I tools/protocol-re/clean.py re-data/exports/wm tools/protocol-re/names/wm 41c610
```

Names are ours unless they come from a string in the binary (`fc_NC_*` log texts, `CKQ::Add`) or the 2017 client PDB.
Opcode and field names are the official ones from the 2017 PDB *(pdb2017)*; every field offset below was read in the
2016 WM code, so the layouts are plain facts and only the names come from the PDB. *(inferred)* marks deductions.
Payload offsets are from the start of the payload (after the 2-byte opcode). Client cross-references use
`re-data/client-handlers.json` (C01) and the client export; error texts come from `docs/protocol/client-error-codes.json`
or, where that table has no entry, from the client handler itself. Session basics (CheckAlive, the session table,
character blobs) are in [`W01-core.md`](W01-core.md) §1, §6.3; parties in [`W02-party-raid.md`](W02-party-raid.md);
guilds and the guild tournament in [`W03-guild.md`](W03-guild.md). Verified layouts: `docs/protocol/annotations/W04.json`.

W01-core §9 lists the OPTool opcodes in one line each; §4 below is the full reconstruction and supersedes it.

---

## 1. Shared data and helpers

### 1.1 Client-session fields used by this item (see W01-core §1.1 for the rest)

| Offset | Field | Notes |
|---|---|---|
| +0x114 | wmHandle (u16) | W01 |
| +0x117 / +0x118 | zoneNo (u8) / zoneHandle (u16) | the 6-byte zone header `{u16 zoneHandle, u32 charNo}` sent to the zone is built from +0x118 and CHARDATA.charNo |
| +0x128 | userId (char[256]) | W01 |
| +0x560 | CHARDATA = `PROTO_NC_CHAR_BASE_CMD` *(pdb2017; offsets used here confirmed)*: +0x00 chrregnum, +0x04 charid (Name5), +0x42 logininfo (map Name3 first), **+0x5E u32 pkcount**, **+0x62 u16 prisonmin** (≠ 0 = in prison), **+0x64 u8 adminlevel** | W01 called +0x64 "level-like"; the PDB name is `adminlevel`, and 0x2010 requires 100 |
| +0x5C8 / +0x5CC | passive-skill blob (ptr, size) = `{u16 count, u16 skillId[count]}` | filled by CharDB 0x100E (W01 §6.3), appended by zone 0x4820 (§3.3), sent to zones in 0x1025 |
| +0x638 | `PROTO_GAMEDATA_CMD` *(pdb2017)*: +0x638 u8 **bIsGM**, +0x639 u16 partyno, +0x63B u16 nRaidNo | W02; bIsGM bit 0 becomes the whisper `GMColor` flag |
| +0x658 | single-option blob; u32 at blob+10 = **nChatBan** (≠ 0 = chat-banned) | W02 §1.1 |
| +0x704 | inGame (1 after character login) | W01 |
| +0x708 | friend list | part 2 (friends); 0x281F uses `FUN_0045c6f0` find / `FUN_0045c630` remove on it |
| +0x1E280 | **inArena** (u32): 1 while the character fights in the guild-tournament arena (zone 0x74C8 / 0x74C9, W03 §8.3) | chat filters below |

### 1.2 Helpers (named here)

| Function | Name (ours) | What |
|---|---|---|
| `FUN_00437990` | `Clients_FindByCharName` | `__fastcall` with a Name5 passed by value on the stack: walks the client list (+0x10), skips sessions without CHARDATA, compares the lower-cased (`FUN_004375c0`, A–Z only) names with `_mbscmp`. No state or inGame check |
| `FUN_00437b00` | `Clients_BroadcastRaw` | SendRaw to **every** client session in the list (also those at character select); returns the AND of the results |
| `FUN_00437b40` | `Clients_BroadcastInGame(pkt, skipArena)` (W01 name) | SendPacket to sessions with inGame == 1; `skipArena == 1` also skips sessions with inArena == 1 |
| `FUN_00439440` | `Zones_SendRawTo(zoneNo, buf, len)` | SendRaw to `g_Zones.array[zoneNo]` if zoneNo < count and the slot is set |
| `FUN_00424c30` | `Name4_Differs` | 16-byte compare, 0 = equal, 1 = different |
| `FUN_004382d0` | `Clients_OnCharacterDeleted(charNo)` | fan-out of a character deletion (§4.3) |

`Pkt_Init` (FUN_0045fd30) sets only the header bytes of the 0x2004-byte `CSendPacket` stack buffer (payload capacity
0x1FFB at +5); `Pkt_SetOpcode` checks the size *after* the handler has already written the payload. Any payload byte a
handler does not write is therefore stale stack data.

---

## 2. Chat routing (dept 8 ACT)

### 2.1 Whisper: client 0x200C NC_ACT_WHISPER_REQ (CParserClient)

```pseudo
0x200C NC_ACT_WHISPER_REQ { u8 itemLinkDataCount; Name5 receiver; u8 len; char content[len]; ItemLink links[itemLinkDataCount] (0x67 each) }
                                                                                      @ FUN_0041c610
    if not Client_CheckAlive(s): return
    if len == 0 or s.CHARDATA == null:
        Send s 0x200F NC_ACT_WHISPERSUCCESS_ACK (size 0x16) { u8 itemLinkDataCount = stale stack byte,
            Name5 receiver = request.receiver, u8 len = request.len }          # no content
        # (original bug) W04-B4: the count byte is never written; len is echoed even when s has no character
        return
    if s.CHARDATA.prisonmin != 0:  fail(0x0F6A)                                  # sender in prison
    t = Clients_FindByCharName(receiver)                                         @ FUN_00437990
    if t == null:                  fail(0x0F69)
    if s.inArena == 0 and t.inArena == 1:  fail(0x0F6C)                          # arena fighters only hear arena fighters
    if Client_GetPrison(t) != 0:   fail(0x0F6A)                                  # receiver in prison (FUN_00409a10: CHARDATA.prisonmin)
    if len >= 0x81:                fail(0x0F6B)
    if s.singleOption.nChatBan == 0:                                             # chat-banned: receiver gets nothing
        Send t 0x200D NC_ACT_SOMEONEWHISPER_CMD {
            u8 itemLinkDataCount = request.count, Name5 talker = s.CHARDATA.charid,
            u8 flag: bit0 GMColor = s.bIsGM & 1, bits 1–7 stale stack data,
            u8 len, content[len] (_mbsnbcpy), links = request links (count × 0x67) }   # size 0x17 + len + count·0x67
    Send s 0x200F NC_ACT_WHISPERSUCCESS_ACK { u8 count, Name5 receiver = t.CHARDATA.charid (the stored spelling),
        u8 len, content[len], links }                                           # size 0x16 + len + count·0x67
    Zones_SendRawTo(s.zoneNo, 0x6006 NC_CT_CHARTTING_CMD { u16 s.zoneHandle, u32 s.charNo })
        # zone: chat-title counter (Z08 §7.2, `FUN_005a3ce0`)

fail(code): SendRaw s 0x200E NC_ACT_WHISPERFAIL_ACK { u16 ErrorType = code, Name5 receiver = request.receiver }   (25 bytes raw)
```

- The item-link count is never checked: `count·0x67` bytes are copied from the request (past its end when the sender
  lies) into the 8 KB stack packet before `Pkt_SetOpcode` checks the size. With `count ≥ 79` the copy runs past the
  buffer (from about count 80; 79 with a 128-byte text) and the stack cookie check terminates the WM (original bug) W04-B2. Same for the 0x200F copy.
- Client (`GameFrameWork::On_NC_ACT_WHISPERFAIL_ACK`, FUN_004a9ea0): 0x0F69 "Cannot find the recipient.", 0x0F6A
  "Cannot send whisper to someone in prison." (shown for both a jailed sender and a jailed receiver), 0x0F6C "You
  cannot whisper to the person who is participating in the Guild Tournament" (TextData2). **0x0F6B is not handled**:
  a too-long whisper fails silently (original bug) W04-B5.
- Client 0x200D (`On_NC_ACT_SOMEONEWHISPER_CMD`, FUN_004a9c80): adds the item links, drops the message if the talker
  is on the client's own chat-restrict list (`CChatRestrict::Get`, dept 42, part 5), clamps len to 0x80, shows it with
  `AddGMWhisperChat` when flag bit 0 is set, else `AddWhisperChat`, and adds the talker to the whisper list.
- A chat-banned sender gets a normal success echo; the receiver never sees the message (silent mute) *(inferred intent)*.

### 2.2 Notice: 0x2010 NC_ACT_NOTICE_REQ (three parsers)

```pseudo
Client 0x2010 NC_ACT_NOTICE_REQ { u8 itemLinkDataCount (ignored); u8 len; char content[len] }   @ FUN_00413450
    if not Client_CheckAlive(s) or s.CHARDATA == null: return
    if s.CHARDATA.prisonmin != 0: return
    if s.CHARDATA.adminlevel != 100: return                                     # silently ignored for players
    Notice_Broadcast(len, content)

Zone 0x2010 (same payload)     @ FUN_0042a920:  if Zone_CheckAlive:   Notice_Broadcast(len, content)
OPTool 0x2010 (same payload)   @ FUN_00425c90:  if OPTool_CheckAlive: Notice_Broadcast(len, content)

Notice_Broadcast (inlined in all three):
    raw = { u8 size = len + 4, u16 0x2011, u8 stale stack byte, u8 len, content (_mbsnbcpy, len bytes) }
    Clients_BroadcastRaw(raw, len + 5)                                          # every client session, any scene
    # 0x2011 NC_ACT_NOTICE_CMD payload { u8 itemLinkDataCount (never written), u8 len, char content[len] }
```

- The text goes to a 0x83-byte stack area, but `len` is up to 255: a notice longer than 131 bytes overruns the stack
  buffer and the cookie check ends the process; `size = len + 4` also wraps for len > 251 (original bug) W04-B1. For
  the client parser only an adminlevel-100 character can trigger it.
- Client: only `GameFrameWork::On_NC_ACT_NOTICE_CMD` (FUN_004b5420) acts; the other scenes accept and ignore it. It
  copies `len` bytes (no clamp; its own buffer is 0x80, so the client overflows too for len > 0x80), formats them with
  TextData 0x3830508a and shows an announcement plus an author message. The literal text `Admin level is 100` sets a
  client flag (`this+0x91 = 1`) *(meaning not traced; client-side)*.

### 2.3 Party chat: client 0x2014 NC_ACT_PARTYCHAT_REQ

```pseudo
0x2014 NC_ACT_PARTYCHAT_REQ { u8 itemLinkDataCount; u8 len; char content[len]; links[count] (0x67 each) }   @ FUN_00413510
    if not Client_CheckAlive(s) or s.CHARDATA == null: return
    p = s.partyNo (+0x639)
    if not Party_IsConfirmed(g_Parties, p, s.charNo):   SendRaw s 0x2016 NC_ACT_PARTYCHAT_ACK { u16 error = 0x07C1 }; return
    if len >= 0x81:                                      SendRaw s 0x2016 { 0x07C2 }; return
    pkt = 0x2015 NC_ACT_PARTYCHAT_CMD { Name5 talker = s.CHARDATA.charid, u8 itemLinkDataCount, u8 len, content, links }
          # size 0x16 + len + count·0x67; count unchecked → same stack overflow as 2.1 (original bug) W04-B3
    if s.singleOption.nChatBan != 0:
        Send s pkt                                       # banned: only the sender sees it
    else for each member slot i < Party_GetMemberCount(p) of PARTY p (W02 §1.2):
        m = Clients_GetByHandle(member.wmcharhandle)
        if m and m.CHARDATA and not Party_IsPending(p, member.chrregnum) and member.chrregnum == m.charNo
           and (s.inArena != 0 or m.inArena != 1):
            Send m pkt                                   # includes the sender itself
    if SendRaw s 0x2016 { 0x07C0 } succeeded:
        Zones_SendRawTo(s.zoneNo, 0x6006 NC_CT_CHARTTING_CMD { s.zoneHandle, s.charNo })
```

Client (`On_NC_ACT_PARTYCHAT_ACK`, FUN_004a9f00): 0x07C0 ignored (success); 0x07C1 "Not a member of any Party.";
anything else (0x07C2) "An Error has occurred in party chatting.". 0x2015 is shown by `On_NC_ACT_PARTYCHAT_CMD`
(FUN_004a1890). Raid chat is W02 §5.12; guild chat W03 §3.6.

### 2.4 Zone 0x207D NC_ACT_SCRIPT_MSG_WORLD_CMD (CParserZone)

```pseudo
0x207D NC_ACT_SCRIPT_MSG_WORLD_CMD { u16 nHandle; u8 sScriptMsgIndex[32]; u8 nlen[5]; u8 sContent[Σ nlen] }   @ FUN_0042cea0
    if not Zone_CheckAlive: return
    n = nlen[0] + nlen[1] + nlen[2] + nlen[3] + nlen[4]                          # five argument strings, back to back
    Clients_BroadcastInGame(0x2079 NC_ACT_SCRIPT_MSG_CMD { same fields, size 0x27 + n }, skipArena = 0)
```

Client `On_NC_ACT_SCRIPT_MSG_CMD` (FUN_004bc020) formats the script message (index string + arguments). The zone
sends 0x207D from its script engine (Z15) to make a world-wide script message.

---

## 3. Zone notifications (dept 9 BAT, 18 SKILL)

### 3.1 0x244A NC_BAT_PKINPKFIELD_WMS_CMD

```pseudo
0x244A { u16 wldmanhandle; u32 chrregnum; u32 pkcount }                         @ FUN_0042b3b0
    if not Zone_CheckAlive: return
    c = Clients_GetByHandle(wldmanhandle); if c is null, has no CHARDATA or c.charNo != chrregnum:
        c = Clients_FindByCharNo(chrregnum)
    if c == null or c.CHARDATA == null:
        log "WARNING - fc_NC_BAT_PKINPKFIELD_WMS_CMD, Not found attacker, wmshandle=%d, regnum=%d, pkcount=%d"
    else c.CHARDATA.pkcount (+0x5E) = pkcount                                   # cached; reaches the next zone in 0x101C
```

The client-facing `0x244B NC_BAT_PKINPKFIELD_CLIENT_CMD` is sent by the zone itself, not by the WM.

### 3.2 0x2458 NC_BAT_WORLD_MOB_KILL_ANNOUNCE_CMD

```pseudo
0x2458 { u32 nTextIndex (MobKillAnnounceType) }                                  @ FUN_0042b490
    Clients_BroadcastInGame(0x2459 NC_BAT_CLIENT_MOB_KILL_ANNOUNCE_CMD { u32 nTextIndex }, skipArena = 0)
```

`MobKillAnnounceType` *(pdb2017)*: 0 Helga, 1 Karen, 2 B_CrackerHumar, 3 BH_Helga, 4 BH_Humar, 5 Chimera,
6 B_Albireo, 7 BH_Albireo, 8 BH_Karen, 9 IS_Blakhan. Client (FUN_004b59c0) looks the type up in
`MobKillAnnounceTextTab` and shows it as an announcement in colour 0x32; unknown types are ignored. No range check
on the WM.

### 3.3 0x4820 NC_SKILL_PASSIVESKILL_LEARN_CMD

```pseudo
0x4820 { u16 wmshandle; u32 chrregnum; u16 passiveskillid }                     @ FUN_0042a870
    c = Clients_GetByHandle(wmshandle); require c.CHARDATA and c.charNo == chrregnum (no fallback search)
    passive blob (+0x5C8/+0x5CC) = copy of the old blob + 2 bytes; ids[count] = passiveskillid; count += 1
    # malloc (FUN_004698f1) / free (FUN_00469d34); no duplicate check
```

The WM keeps the cache current so the next zone gets the learned passive in 0x1025 (W01 §6.3).

---

## 4. Operator tool (dept 10 OPTOOL and the other CParserOPTool handlers in scope)

All handlers start with `OPTool_CheckAlive` (FUN_00424510, state == 1) except 0x2803. Replies go to the requesting
OPTool session only.

### 4.1 Server status

```pseudo
0x2801 NC_OPTOOL_S2SCONNECT_LIST_REQ { u8 echo_data }                           @ FUN_004251a0
    entries = []
    for link in AccountDB, AccountLogDB, CharDB, GameLogDB, Login: if link.state == 1: entries += info(link)
    for every session in g_Clients, g_Zones, g_OPTools (list order): if state == 1: entries += info(session)
    Send 0x2802 NC_OPTOOL_S2SCONNECT_LIST_ACK { u8 echo_data, u8 my_server_id = g_WM.myServerType (5),
        u16 num_of_connections, SERVER_CONN_INFO[n] }                           # size 4 + 7n
    info(x) = SERVER_CONN_INFO { u8 connect_server_world = x+8, u8 connect_server_zone = x+0xC,
              u8 connect_server_id = x+4 (server type), SHINE_DATETIME connect_time from the SYSTEMTIME at x+0x10:
              bits 0–3 year % 16, 4–7 month, 8–12 day, 13–17 hour, 18–23 minute, 24–29 second }
```

Every connected game client is listed. The list is written straight into the 8 KB stack packet: more than 1169
sessions in total overrun it before the size check (original bug) W04-B8 *(only with a large client capacity)*.

```pseudo
0x2803 NC_OPTOOL_CLOSE_SERVER_REQ { u8 req_server_id; u8 closekey[32] }        @ FUN_00425860 (OPTool_CloseServer_2803)
    log "SERVER STOP - fc_NC_OPTOOL_CLOSE_SERVER_REQ"
    Send 0x2804 NC_OPTOOL_CLOSE_SERVER_ACK { u16 error = 0x0600 }
    g_Shutdown (DAT_006c5548) = 1                                                # main loop exits (W01 §2)
```

No `OPTool_CheckAlive`, and neither `req_server_id` nor `closekey` is read: any connection on the OPTool port,
even before its 0x0802 handshake, stops the world manager (original bug) W04-B7.

```pseudo
0x2805 NC_OPTOOL_MAP_USER_LIST_REQ, 0x0828 NC_MISC_XTRAP2_OPTOOL_READ_CODEMAP_REQ   @ FUN_00425930
    return OPTool_CheckAlive(...)                    # no reply: the 2016 WM has no map user list / XTrap code map

0x2807 NC_OPTOOL_CONNECT_BRIF_REQ { u8 echo_data }                              @ FUN_00425950
    count[21][2][2] = 0 (u16)
    for the five links and every client / zone / OPTool session with state == 1:
        type = x+4 (> 20 → 10), world = x+8 (> 1 → 0), zone = x+0xC (> 1 → 0); count[type][world][zone] += 1
    Send 0x2808 NC_OPTOOL_CONNECT_BRIF_ACK { u8 echo_data, u8 my_server_id = 5, u16 count[21][2][2] }   # size 0xAA

0x280E NC_OPTOOL_SET_CLIENT_NUM_OF_USER_LIMIT { i32 NumOfUserLimit }            @ FUN_00426390 (OPTool_SetUserLimit_280E)
    if NumOfUserLimit < -1: return
    g_Clients.userLimit (DAT_00556bac) = NumOfUserLimit > capacity (DAT_00556bb8) ? -1 : NumOfUserLimit
    Login_WorldStatus_0808(g_LoginLink, force = 1)                               # W01 §2: Login sees the new limit

0x280F NC_OPTOOL_REQ_CLIENT_NUM_OF_USER_LIMIT {}                               @ FUN_004263f0
    Send 0x2810 NC_OPTOOL_ACK_CLIENT_NUM_OF_USER_LIMIT { u8 WorldNo = g_WorldNo, i32 NumOfUserLimit = userLimit,
        i32 NumOfMax = capacity }

0x281A NC_OPTOOL_WM_SEND_PACKET_STATISTICS_CLR                                 → LAB_00414e40 (no-op stub)
0x281B NC_OPTOOL_WM_SEND_PACKET_STATISTICS_REQ {}                              @ FUN_004265a0
    Send 0x281C NC_OPTOOL_WM_SEND_PACKET_STATISTICS_ACK { u8 bPart = 4, u16 nDataCount = 0 }   # statistics not kept
```

### 4.2 Kingdom-quest schedule (OPTool side)

The KQ list object is the global at `DAT_0055e15c` (W01 called it `g_InstanceMaps`; the log string
`ERROR - CKQ::Add's MAX_KINGDOM_QUEST BUFFER OVERFLOW` shows it is the `CKQ` object):

```
CKQ (DAT_0055e15c)
  +0x0      i32 count (max 300)
  +0x4      PROTO_KQ_INFO entries[300] (0x179 each, pdb2017 layout; +0 Handle, +4 Status, +7 ID, +9 Title[64], …)
  +0x1BA48  (DAT_00579ba4) pointer to a map-allocation object; its +0x28 = number of rows
  +0x1BB14  (DAT_00579c70) KQ_MAP_ALLOC_TABLE rows (0x28 = u32 AllocatedQuest[10] each)
```

The rest of the KQ subsystem (schedule load, status machine, map allocation) is part 2 (dept 22 KQ).

```pseudo
0x2809 NC_OPTOOL_KQ_SCHEDULE_REQ {}                                             @ FUN_00427790
    if CKQ.count == 0:
        Send 0x280A NC_OPTOOL_KQ_SCHEDULE_ACK (size 7) { u16 NumOfTotal = stale, u8 bPart = 3, u16 StartDataIndex = 0,
            u16 NumOfQuest = stale }                                             # (original bug) W04-B9
        return
    in chunks of 10 entries (KQInfo_Copy FUN_00427380 copies the full 0x179-byte PROTO_KQ_INFO):
        Send 0x280A { u16 NumOfTotal = count, u8 bPart (bit0 first chunk, bit1 last chunk), u16 StartDataIndex,
            u16 NumOfQuest, PROTO_KQ_INFO QuestArray[NumOfQuest] }               # full chunk: size 0xEC1
        stop if a send fails
    # the last packet always carries bit1; when count is a multiple of 10 it has NumOfQuest = 0

0x280B NC_OPTOOL_KQ_CHANGE_CMD { PROTO_KQ_INFO KQInfo }                          @ FUN_00425d30
    CKQ::Add(KQInfo)                                                             @ FUN_00455550
        if count > 299: log the overflow string; return 0
        i = KQ_FindIndexByHandle(KQInfo.Handle)                                  @ FUN_0045cd80
        if i != -1: entries[i] = KQInfo (overwrite) else entries[count++] = KQInfo
    # no reply, nothing sent to zones or the DB here

0x280C NC_OPTOOL_KQ_MAP_ALLOC_INFO_REQ {}                                       @ FUN_00425e20
    n = (CKQ+0x1BA48 pointer) ? its +0x28 : 0
    Send 0x280D NC_OPTOOL_KQ_MAP_ALLOC_INFO_ACK { i32 nNumOfMapArray = n, KQ_MAP_ALLOC_TABLE MapArray[n] }

0x2811 NC_OPTOOL_KQ_DELETE_CMD { u32 Handle }                                    @ FUN_00425d70
    i = KQ_FindIndexByHandle(Handle)
    if i == -1: log "FAILED - fc_NC_OPTOOL_KQ_DELETE_CMD, Handle=%d, NOT FOUND."
    else entries[i].Status = 0x0B                                               # meaning of 0x0B: part 2

0x2826 NC_OPTOOL_KQ_ALL_RESET_CMD {}                                             @ FUN_00426c10
    log "--- NO SUPPORT - KQ ALL RESET---"                                       # not implemented
```

### 4.3 Users and characters

```pseudo
0x281D NC_OPTOOL_CHARACTER_DELETE_REQ { u32 nCharNo }                            @ FUN_00426660
    Send 0x281E NC_OPTOOL_CHARACTER_DELETE_ACK { u8 status = Clients_FindInGameByCharNo(nCharNo) ? 0 : 1 }
    # 1 = not playing, safe to delete (inferred); the WM deletes nothing here

0x281F NC_OPTOOL_CHARACTER_DELETE_CMD { u32 nCharNo }                            @ FUN_00426730
    Clients_OnCharacterDeleted(nCharNo)                                          @ FUN_004382d0
        for every in-game client c whose friend list (+0x708) holds nCharNo (FUN_0045c6f0):
            SendRaw c 0x540C NC_FRIEND_DEL_CMD { Name5 charid = the friend entry's name }   # opcode via register;
            remove the entry (FUN_0045c630)                                      # the decompiler drops it
        for the first guild g (list DAT_006c4ce4) whose member table holds nCharNo (Members_FindByCharNo):
            if the member is the academy master (Academy_IsMaster == 0):
                new master = first grade-0 member (FUN_00443110 / FUN_00443140);
                if found: CharDB 0x987F NC_GUILD_ACADEMY_DB_SET_MASTER_BY_LEAVE_REQ (FUN_0044c4c0, W03 §2.6)
            if remove (FUN_00449100) succeeds:
                Members_Broadcast 0x7438 NC_GUILD_MEMBER_LEAVE_CMD { Name5 } (FUN_00444650); g.nNumMembers = M.count
                stop the guild scan
        SendRaw CharDB 0x9424 NC_HOLY_PROMISE_DB_DEL_CHAR_REQ { u32 nCharNo }    # answer 0x9425: part 4
        Zones_BroadcastRaw 0x10B2 NC_CHAR_WEDDING_CANCEL_WEDDING { u32 nCharNo }
        for the first guild g whose academy table holds nCharNo (FUN_00441000):
            if remove (FUN_0044b840) succeeds:
                0x9860 NC_GUILD_ACADEMY_MEMBER_LEAVE_CMD to academy and guild members (FUN_00447580, FUN_004406c0)
                g.nNumAcademyMembers (+0x494) = A.count; stop

0x2827 NC_OPTOOL_FIND_USER_REQ { u32 nUserNo }                                   @ FUN_00426c50
0x2829 NC_OPTOOL_KICK_USER_REQ { u32 nUserNo }                                   @ FUN_00426e20 (OPTool_KickUser_2829)
    c = Clients_FindByUserNo(nUserNo)
    reply (0x2828 NC_OPTOOL_FIND_USER_ACK / 0x282A NC_OPTOOL_KICK_USER_ACK, size 0x129) {
        u32 nUserNo, u8 bIsLogin / bKick = (c != null), Name256Byte sUserID = c.userId,
        u32 nCharNo, Name5 sCharID, Name3 sMapName }
        c in game with CHARDATA: nCharNo = charNo, sCharID = charid, sMapName = CHARDATA+0x42 (login map)
        c not in game:           nCharNo = 0xFFFFFFFF, sCharID = "", sMapName = ""
        c == null:               everything after the flag byte is stale stack data (original bug) W04-B10
    kick only, c != null: Zones_BroadcastKick_0C16(nUserNo) (FUN_00439540); Client_SendKick_0C17(c, 0x068F) (FUN_004305a0);
        c.closeReason = 0x790; c.state = 3; log "fc_NC_OPTOOL_KICK_USER_REQ, nUserNo=%d"     (W01 §5.2)
```

### 4.4 Guild and guild tournament (OPTool side; W03 owns the guild data)

Guild entry offsets are W03 §1.2 (`GUILD_CLIENT` at entry+0x0C, `GUILD_SERVER` at +0x788). The guild list head is
`g_GuildManager+0x24` (`DAT_006c4ce4`).

```pseudo
0x2815 NC_OPTOOL_GUILD_TOURNAMENT_CHANGE_CMD { u8 nMatchType; i32 Time[9] (Time_Start, Time_Practic,
        Time_PracticEnd, Time_Match_161, Time_Match_162, Time_Match_8, Time_Match_4, Time_Match_2, Time_Match_End);
        GUILD_TOURNAMENT_LIST TournamentTree[31] (0x15 each) }   (0x2B0)      @ FUN_004264d0 → FUN_0043d830
    T = g_GuildTournament (W03 §8.1)
    error = Tournament_OPToolChange(T, cmd):
        Time_Start != T.Time_Start                         → 0x1401   # only the running tournament can be edited
        nMatchType > 9                                     → 0x1405
        Time[i] >= Time[i+1] for any i in 0..7             → 0x1402
        d = ((row.WaitPlayTimeSec + 59) / 60 + row.PlayTime + row.ExploerTimeMin) · 60  (active GuildTournament.shn row)
        any gap Time_Match_161→162→8→4→2→End shorter than d → 0x1404
        log "pCmd->nMatchType : %d,  %d < %d " (nMatchType, Time[nMatchType], now)
        nMatchType != 9 and Time[nMatchType] <= now        → 0x1403
        else: T.MatchTime[9] = Time; T.phase (+0x2C0) = nMatchType; T bracket (+0x2E, 31 × 0x15) = TournamentTree
              → 0x1400
    Send 0x2816 NC_OPTOOL_GUILD_TOURNAMENT_CHANGE_ACK { u16 error }
    # memory only: no DB write, no message to zones or clients (inferred from the code: none is sent)
```

Ghidra shows `Tournament_OPToolChange` as `void`; the result codes are visible only in the disassembly
(`mov eax, 0x140x` before each return, stored by `mov [ebp-0x200f], ax` at 0x426553).

```pseudo
0x2820 NC_OPTOOL_GUILD_CHANGE_MEMBER_GRADE_REQ { u32 nGuildNo; u32 nCharNo; u8 nOldGrade; u8 nNewGrade }   @ FUN_00427630
    error = 0x1581                                             # guild not found
    g = first guild in the list with GUILD_CLIENT.nNo == nGuildNo
    if g: error = 0x1580
        m = Members_FindByCharNo(g.M, nCharNo); if !m → 0x1582
        elif m.grade (record +0x14) != nOldGrade → 0x1583
        else m.grade = nNewGrade; Members_Broadcast 0x7439 NC_GUILD_MEMBER_GRADE_CMD { Name5 m.name, u8 nNewGrade }   @ FUN_00444700
    Send 0x2821 NC_OPTOOL_GUILD_CHANGE_MEMBER_GRADE_ACK { u16 error }
    # no grade range check, no DB write, zones not told (inferred: the tool writes the DB itself)

0x2822 NC_OPTOOL_GUILD_TOURNAMENT_SCHEDULE_RESET_REQ {}                         @ FUN_00426990
    r = active GuildTournament.shn row (T+0x314 = DAT_006c5000): +1 Weeks, +2 Week, +3 Hour, +4 Minute,
        +5 TermHour, +6 TermMinute (column names from the SHN header)
    t = localtime(now); t.sec = 0
    if r.Minute != 60: t.min = r.Minute
    if r.Hour != 25:   t.hour = r.Hour
    if r.TermMinute not in {0, 60}: t.min = t.min rounded down to a multiple of TermMinute
    if r.TermHour not in {0, 25}:   t.hour = t.hour rounded down to a multiple of TermHour
    if r.Week != 0: t.mday += (r.Week − 1) − t.wday; if t.mday < 1: t.mday += 7; normalise   # weekday Week−1 (1 = Sunday)
    if r.Weeks != 0: move t by ±7 days until ceil(t.mday / 7) == r.Weeks                  # n-th week of the month
    when = mktime(t)
    Tournament_Reset(g_GuildManager) (FUN_0044a270, W03 §8.4: every guild's GT_COND_INFO cleared, bracket logged)
    log "CurrentTime-%d" (when)
    Send 0x2823 NC_OPTOOL_GUILD_TOURNAMENT_SCHEDULE_RESET_ACK { i32 nGTNo = when }
    # `when` is not stored anywhere: the tournament times stay as they were (see §uncertain)

0x2824 NC_OPTOOL_GUILD_DATA_CHANGE_REQ { u32 nNo; Name4 sName; Name3 sPassword; u64 nMoney; u8 nType; u8 nGrade;
        u32 nFame; u16 nStoneLevel; u64 nExp; u16 nMaxMembers; u32 nWarWinCount; u32 nWarLoseCount;
        u32 nWarDrawCount; u8 nDismissStatus; i32 dDismissDate; i32 dNotifyDate; Name5 sNotifyCharID;
        char sIntro[128]; char sNotify[512] }   (0x2E3)                         @ FUN_00427980
    if nNo == 0:                        reply 0x1641
    g = Guilds_FindByNo(nNo); if !g:    reply 0x1642
    if g.nNumMembers != 0xFFFF and g.nNumMembers > nMaxMembers: reply 0x1643
    renamed = Name4_Differs(g.sName, sName)
    copy into g: sName, GUILD_SERVER.sPassword (+0x78C), nMoney, nType, nGrade, nFame, nStoneLevel, nExp, nMaxMembers,
        win/lose/draw counts, nDismissStatus, dDismissDate (+ its tm via localtime), dNotifyDate (+ tm),
        sNotifyCharID, sIntro, sNotify
    reply 0x1640
    Members_Broadcast(g.M) 0x7419 NC_GUILD_MY_GUILD_INFO_ACK { u16 0x0C41, GUILD_CLIENT g }       # size 0x42D
    if renamed: Clients_BroadcastRaw 0x7477 NC_GUILD_NAME_ACK { u32 nNo, Name4 sName,
        GUILD_EMBLEM_INFO = 0xFFFF if emblem state ∈ {1, 4, 0xFF} else g+0x774 }
    reply(code) = SendRaw 0x2825 NC_OPTOOL_GUILD_DATA_CHANGE_ACK { u16 error = code }               @ FUN_0043f390
    # memory only: no CharDB request, zones not told (inferred: the tool writes the DB itself)

0x282B NC_OPTOOL_GUILD_DISMISS_CANCEL_REQ { u32 nNo }                            @ FUN_00427030
    if nNo == 0:                         SendRaw 0x282C NC_OPTOOL_GUILD_DISMISS_CANCEL_ACK { 0x1E49 }   @ FUN_00443170
    g = Guilds_FindByNo(nNo); if !g:     SendRaw 0x2825 { 0x1E4A }        # wrong opcode (original bug) W04-B11
    if g.nDismissStatus != 1:            SendRaw 0x2825 { 0x1E4B }        # wrong opcode (W04-B11)
    SendRaw CharDB 0x74EE NC_GUILD_DB_DELETE_CANCEL_REQ { u32 nNo, u16 hTool = t.wmHandle (+0x114) }  @ FUN_004431a0
    # answer CharDB 0x74EF → 0x282C (W03 §9.2, `FUN_00443200`)
```

---

## 5. Friends (dept 21 FRIEND)

### 5.1 Friend list in the client session

`FriendList` at session +0x708 (struct ours; the helpers below are its methods):

| Offset (list) | Session | Field |
|---|---|---|
| +0 | +0x708 | i32 count (≤ 100) |
| +4 + i·0x48 | +0x70C | `PROTO_FRIEND_INFO` entries[100] *(pdb2017 layout, offsets agree)*: +0 `PROTO_FRIEND_DATE logininfo` (bit 0 = online; bits 1–25 year:11 month:4 day:5 hour:5 of the last logout), +4 Name5 charid, +0x18 classid, +0x19 level, +0x1A isparty, +0x1B flag, +0x1C Name3 map, +0x28 statustitle[32] |
| +0x1C24 | +0x232C | i32 pendingRequestCharNo (−1 none): the one charNo whose friend request this player may answer |
| +0x1C28 | +0x2330 | u32 listFresh: 1 after the CharDB push 0x1010, cleared after the first map login processed it |
| +0x1C2C + i·4 | +0x2334 | u32 friendCharNo[100] (parallel to entries) |
| +0x1DBC + i·2 | +0x24C4 | u16 friendWmHandle[100] (0xFFFF offline) |

Other session fields: +0x1ED90 i32 findFriendsNextTime, +0x1ED94 u16 friendPoint, +0x1ED96 u16 pendingFriendPoint
(the "received today" difference, reported and cleared at map login, W01 §7 0x180C). +0x704 is W01's `inGame`.

Helpers (all `@` the listed function, names ours):

```pseudo
FriendList_CheckAdd(list, charNo)      @ FUN_0045c830   # Ghidra types it bool; the asm returns 0/1/2
    charNo in friendCharNo[] → 2 (already a friend);  count ≥ 100 → 1 (full);  else 0
FriendList_SetPendingRequest(list, charNo)   @ FUN_0045c4f0
    charNo == −1 → 0x949;  pending == charNo → 0x94C;  pending ≠ −1 → 0x94D;  else pending = charNo → 0x941
FriendList_ClearPending @ FUN_0045c570 (pending = −1);  FriendList_IsPending(list, charNo) @ FUN_0045c540
FriendList_AddOrUpdate(list, info, charNo)  @ FUN_0045c580
    count > 100 → 0;  entry with the same charid (20-byte compare) → overwrite info + charNo → 2
    count ≥ 100 → 0;  else append → 1
FriendList_SetOnline(list, name, wmHandle)  @ FUN_0045c730   # by name: logininfo |= 1, friendWmHandle = wmHandle
FriendList_IsOnline(list, charNo) @ FUN_0045c7a0;  FriendList_Contains @ FUN_0045c870;  FriendList_IsFull (≥ 100) @ FUN_0045c8a0
FriendList_RemoveByName(list, name) @ FUN_0045c630;  FriendList_FindEntry(list, charNo) @ FUN_0045c6f0;  Clear @ FUN_0045c320
FriendList_SetOfflineAt(list, i)   @ FUN_0045c7f0 → FUN_0045c330: logininfo = local time (year:11 month:4 day:5 hour:5) << 1,
                                     login bit 0, top 6 bits kept; friendWmHandle[i] = 0xFFFF
FriendList_SetOfflineByName(list, name) @ FUN_0045c940 (same stamp, by name)
FriendList_SetMap(list, name, map[12]) @ FUN_0045c3c0;  FriendList_SetLevel(list, name, level) @ FUN_0045c490
FriendInfo_Copy @ FUN_0040ac30 (0x48 bytes)
Session accessors: friendPoint get/set FUN_00433d00 / FUN_00433ce0, pendingFriendPoint set/get FUN_00433d10 /
FUN_00433d30, findFriendsNextTime set/get FUN_00433cc0 / FUN_00433cd0, own charNo FUN_004037c0 (0 without CHARDATA);
Name5 from a C string (zero-filled, strncpy 20) FUN_00403790; zero two Name5 FUN_00413950.
```

### 5.2 Loading and presence (not handlers; reached from W01's login / map login / logout / level change)

```pseudo
CharDB 0x1010 NC_CHAR_FRIEND_CMD { u16 wmHandle, u16 count, entries[count] { u32 charNo, Name5 name, u8 flag } (25 bytes) }
                                                                                         @ FUN_0040a570
    s = Clients_GetByHandle(wmHandle) else return
    count > 100: log "ERROR - OVER MAX FRIEND, nCharNo=%d, Friend count=%d"; count = 100
    list.Clear(); listFresh = 1; list.count = count
    each i: entry.login bit = 0; entry.charid = name; entry.flag = flag; entry.classid = 0; friendCharNo[i] = charNo
    # level, map, date, isparty stay whatever the previous character left there (not cleared; the 0x5415 answer
    # overwrites them for offline friends, online friends are filled below)

Friends_OnMapLogin(s)          called from 0x180C map login (W01 §7)                   @ FUN_00436900
    if list.count == 0: return
    if listFresh:                                   # first map login after character login
        for every client session o with CHARDATA:              (Clients first/next FUN_004376c0 / FUN_004376f0)
            i = index of o.charNo in s.friendCharNo[] (first match) else continue
            s.friendWmHandle[i] = o.handle
            o.list.SetOnline(s.name, s.handle)                  # even if o.list is not loaded yet
            Send o 0x5409 NC_FRIEND_LOGIN_CMD { Name5 charid = s.name, Name3 map = s.map }     (0x20)
            s.entry[i]: online, charid = o.name, classid = o.shape.class, level = o.level,
                        isparty = Party_IsValidNo(o.partyNo), map = o.map, statustitle = "-" (2 bytes written)
        Send s 0x5407 NC_FRIEND_LIST_CMD { u8 count, PROTO_FRIEND_INFO[count] }                @ FUN_00430ae0
        for every offline entry i:
            Send CharDB 0x5414 NC_FRIEND_DB_GET_REQ { u16 handle_char = s.handle, u32 charno = s.charNo,
                                                      u32 friendno = friendCharNo[i] }     (0xA; D04 §3)
        listFresh = 0
    Friends_SendMap(s)                                                                     @ FUN_00435cd0

Friends_SendMap(s)  (every map login)            @ FUN_00435cd0
Friends_SendLevel(s) (0x1074 level change, W01)   @ FUN_004355a0
Friends_SendLogout(s) (CharacterLogout, W01 §5.4) @ FUN_004353a0
Friends_SendPartyState(s) 0x540E                   @ FUN_00435ee0 (W02, called by party join/leave)
    common loop, for each entry i with the online bit:
        f = Clients_GetByHandle(friendWmHandle[i])
        f null or f has no CHARDATA:
            s.list.SetOfflineAt(i)
            if f exists: log (DAT_0048a240 / 0048a2f8 / 0048a360) and Friends_SendLogout(f)   # f has no CHARDATA,
                                                                                         # so that call does nothing
        f.charNo ≠ friendCharNo[i]: log only (logout variant; the map/level variants skip silently)
        else, per variant:
            map:    f.list.SetMap(s.name, s.map);   Send f 0x540D NC_FRIEND_MAP_CMD { Name5 charid, Name3 map } (0x20)
            level:  Send f 0x540F NC_FRIEND_LEVEL_CMD { Name5 charid, u8 level } (0x15); f.list.SetLevel(s.name, level)
            logout: Send f 0x540A NC_FRIEND_LOGOUT_CMD { Name5 charid } (0x14); f.list.SetOfflineByName(s.name)
```

The client (`GameFrameWork`, C01): 0x5407 rebuilds the friend window, 0x5408 "%s has been added to Friend List. ",
0x5409 "%s has logged in.", 0x540A/0x540D/0x540E/0x540F update the window. 0x5418 NC_FRIEND_CLASS_CHANGE_CMD exists in
the 2017 enum but the 2016 WM never sends it.

### 5.3 Friend request (CParserClient 0x5401 → 0x5403 → client 0x5404 → CharDB 0x5410 / 0x5411)

Result codes, as the client shows them (`On_NC_FRIEND_SET_ACK` FUN_004ad950; shown only when `charid` equals the
client's own character name): 0x941 success / 0x94A / 0x94B silent; 0x942 "You cannot add yourself to your Buddy
List."; 0x943 "Cannot register anymore friend."; 0x945 and 0x948 "%s is already registered in the friends list.";
0x946 "Cannot find %s."; 0x947 "%s cannot register anymore friend."; 0x949 "DB Error" (literal); 0x94C "Already have a
friend request."; 0x94D "Already have a friend request from other user."; 0x94E "Target user is not the friend
request target."; anything else "An unknown error has occurred while inviting a friend.". (D04 §3 quotes 0x949 as
"Already have a friend request."; the client code says "DB Error".)

```pseudo
0x5401 NC_FRIEND_SET_REQ { Name5 charid, Name5 friendid }   (no length check)        @ FUN_0041ca90
    # reply = 0x5402 NC_FRIEND_SET_ACK { Name5 charid = req.charid, Name5 friendid = req.friendid, u16 err } (0x2A) to s
    s has no CHARDATA: return
    s.prisonMin ≠ 0: err 0x94A
    t = Clients_FindByCharName(req.friendid); t null or no CHARDATA: err 0x946
    t in prison (Client_GetPrison): err 0x94B
    t.charNo == s.charNo: err 0x942
    s.list.CheckAdd(t.charNo): 1 → 0x943, 2 → 0x945
    t.list.CheckAdd(s.charNo): 1 → 0x947, 2 → 0x948
    err = t.list.SetPendingRequest(s.charNo)            # 0x941 / 0x94C / 0x94D (one pending request per target)
    Send s 0x5402 { …, err }
    err == 0x941: Send t 0x5403 NC_FRIEND_SET_CONFIRM_REQ { Name5 charid = req.friendid, Name5 friendid = req.charid } (0x28)
    # req.charid is never compared with s's own name (original bug) W04-B20: t sees whatever name s typed; the
    # confirmation then fails with 0x94E because the pending charNo is s's real one
    # client: 0x5403 → "%s would like to add you as a friend. Would you agree?"

0x5404 NC_FRIEND_SET_CONFIRM_ACK { Name5 charid (the answering player), Name5 friendid (the requester), u8 accept_friend }
                                                                                         @ FUN_0041cd70
    r = Clients_FindByCharName(req.friendid)
    s has no CHARDATA or s not inGame: return (no answer)
    r null / no CHARDATA / not inGame: s.list.ClearPending; Send s 0x5402 { req.charid, req.friendid, 0x946 }; return
    accept_friend == 1:
        s.list.CheckAdd(r.charNo) == 1 → ClearPending; Send s 0x5402 {…, 0x947}       # own list full, shown with
        s.list.CheckAdd(r.charNo) == 2 → ClearPending; Send s 0x5402 {…, 0x948}       # the requester's name
        r.list.CheckAdd(s.charNo) == 1 → ClearPending; Send r 0x5402 { charid = req.friendid, friendid = req.charid, 0x947 }
        r.list.CheckAdd(s.charNo) == 2 → ClearPending; Send s 0x5402 {…, 0x948}
        !s.list.IsPending(r.charNo)    → ClearPending; Send s 0x5402 {…, 0x94E}
        else: ClearPending
              Send CharDB 0x5410 NC_FRIEND_DB_SET_REQ { u16 handle_charno = r.handle, u16 handle_friendno = s.handle,
                                                        u32 charno = r.charNo, u32 friendno = s.charNo, u8 flag = 0 } (0xD)
    else (refused):
        s.list.ClearPending
        r.list.CheckAdd(s.charNo) ≠ 2: Send r 0x540B NC_FRIEND_REFUSE_CMD { Name5 friendid = req.charid }   (0x14)
        # client: "%s rejected the friend invitation."

CharDB 0x5411 NC_FRIEND_DB_SET_ACK { u16 handle_charno, u16 handle_friendno, u32 charno, u32 friendno, u16 err }
                                                                                         @ FUN_00411600
    r = Clients_GetByHandle(handle_charno) (requester);  c = Clients_GetByHandle(handle_friendno) (accepter)
    # by handle only; charno / friendno are not compared with the sessions found
    err == 0x941 and both found:
        if c has CHARDATA, shape and c.inGame == 1:
            Send r 0x5408 NC_FRIEND_ADD_CMD { PROTO_FRIEND_INFO of c: logininfo |= 1, charid, classid = shape>>2 & 0x1F,
                   level, isparty = (c.partyNo ≠ −1), flag 0, map, statustitle "-" }                    (0x48)
            if r.inGame == 1: r.list.AddOrUpdate(that info, c.charNo); r.list.SetOnline(c.name, c.handle)
        if r has CHARDATA and r.inGame == 1:
            Send r's zone 0x6007 NC_CT_ADD_FRIEND_CMD { u16 zoneHandle (+0x118), u32 r.charNo, u16 NumberOfFriends = r.list.count }
                                                                                         # Z08 §7.2 title counter
        the same two steps mirrored (r's info → c, c added to c's list, 0x6007 for c)
        # (original bug) W04-B12: logininfo bits 1–31 and statustitle bytes 2–31 of both 0x5408 are stack garbage
    err ≠ 0x941:
        both online and inGame: Send r and c 0x5402 { charid = r.name, friendid = c.name, err }
        only r: Send r 0x5402 { r.name, "UNKNWONED", err }
        only c: Send c 0x5402 { "UNKNWONED", c.name, err }
        # (original bug) W04-B13: the client shows 0x5402 only when charid is its own name, so the accepting
        # player never sees the failure; the requester sees it, with "UNKNWONED" for %s when the accepter left
    # D04 §3: err from p_Friend_Set: 0x941 / 0x942 / 0x943 / 0x947 / 0x949 (every DB error incl. "already friends")
```

### 5.4 Delete

```pseudo
0x5405 NC_FRIEND_DEL_REQ { Name5 charid, Name5 friendid }                               @ FUN_0041d230
    s.CHARDATA present and prisonMin ≠ 0:
        Send s 0x5406 NC_FRIEND_DEL_ACK { charid, friendid, u16 err = 0x954 }   (0x2A; client: 0x954 silent)
    else:
        Send CharDB 0x5412 NC_FRIEND_DB_DEL_REQ { u16 handle_charno = s.handle, u32 charno = *CHARDATA,
                                                  Name5 charid = req.charid, Name5 friendid = req.friendid } (0x2E)
        # with no CHARDATA *CHARDATA is a null read (the client cannot reach this before character select)
        # req.charid is not checked against s's name; the DB deletes (charno, friend by name) regardless

CharDB 0x5413 NC_FRIEND_DB_DEL_ACK { u16 handle_charno, u32 charno, Name5 charid, Name5 friendid, u16 err }
                                                                                         @ FUN_004105d0
    s = Clients_GetByHandle(handle_charno):
        Send s 0x5406 { charid, friendid, err }      # client: 0x951 "%s has been deleted from the friends list." (and
                                                     # removes the row), 0x952 " DB Error", 0x953 "Cannot find %s.",
                                                     # other "An unknown error has occurred while deleting a friend."
        err == 0x951: s.list.RemoveByName(friendid)
    f = Clients_FindByCharName(friendid); f and err == 0x951:
        Send f 0x540C NC_FRIEND_DEL_CMD { Name5 charid }   (0x14)   # "%s has deleted you from the friends list."
        f.list.RemoveByName(charid)
    # no 0x6007 for either side (original bug, inferred) W04-B14: the zone's friend counter (title condition 0x22)
    # keeps the old number until the next friend is added
```

0x540C is also sent by W01's character-delete paths (`Clients_OnCharacterDeleted` FUN_004382d0, §4.3; CharDB 0x140B
FUN_0040a010) and the rename path FUN_00431dd0 (W01) removes the old name from friends' lists.

### 5.5 Offline friend details

```pseudo
CharDB 0x5415 NC_FRIEND_DB_GET_ACK { u16 handle_char, u32 charno, u32 friendno, u16 err, PROTO_FRIEND_INFO friendinfo }
                                                                                         @ FUN_00410740
    s = Clients_GetByHandle(handle_char) with CHARDATA, else return
    err == 0x951:
        if !s.list.IsOnline(friendno) and s.list.AddOrUpdate(friendinfo, friendno) > 0:
            Send s 0x5408 NC_FRIEND_ADD_CMD { friendinfo }        # last login date, class, level, map of the offline friend
            # the client prints "%s has been added to Friend List. " for each one (inferred from the client's 0x5408 text)
    else: log sprintf(DAT_00486440, s.charNo, friendno)
```

### 5.6 Friend points, find friends, special item

```pseudo
CharDB 0x541C NC_FRIEND_DB_POINT_CMD { u16 numoffriend, { u32 charregnum, u16 friendpoint, u16 diffpoint }[n] }
                                                                                         @ FUN_0040e5b0
    # sent by the CharDB at character login and to every friend on the first login of a day (D02 §4)
    each entry: s = Clients_FindByCharNo(charregnum): s.friendPoint = friendpoint; diffpoint ≠ 0: s.pendingFriendPoint = diffpoint
    # pendingFriendPoint → client 0x5425 NC_FRIEND_GET_DIFF_FRIEND_POINT_CMD at the next map login (W01 §7)

0x541D NC_FRIEND_POINT_REQ {}  (needs CHARDATA)                                          @ FUN_00418e60
    Send s 0x541E NC_FRIEND_POINT_ACK { u16 friendpoint = s.friendPoint }

0x541F NC_FRIEND_FIND_FRIENDS_REQ {}  (needs CHARDATA)                                  @ FUN_00423110
    # reply 0x5420 NC_FRIEND_FIND_FRIENDS_ACK { u16 error, u16 numoffriend, PROTO_FRIEND_INFO[n] }
    now < s.findFriendsNextTime: error 0x36C5, n 0          # client: "Please try again in a few minutes."
    s.findFriendsNextTime = now + 5 s
    s.list.IsFull: error 0x36C6, n 0                         # client has no case for 0x36C6: silent (original bug) W04-B21
    else error 0x36C0:
        maxDiff = ServerParam "FriendLvDiff" (read once, cached in a static)
        walk all client sessions in table order; take o with CHARDATA, o ≠ s, o not in s.list, |o.level − s.level| ≤ maxDiff
            entry = { logininfo |= 1 (other bits stale), charid, classid, level, isparty, flag 0, map, statustitle "-" }
            stop once the 8 KB packet has room for no more (≈ 113 entries)
        qsort by |level − s.level| ascending (FUN_0045c8b0); keep the first 50
    # client 0x36C0: fills the "find" list; 0x36C1 "Cannot be used right now." is never produced by the WM
    # (original bug) W04-B21: candidates are cut at ≈ 113 in table order before the sort, so on a busy world the
    # closest levels may never be offered; stale logininfo / statustitle bytes as W04-B12

Zone 0x5423 NC_FRIEND_SOMEONE_GET_SPECIALITEM_ZONE_CMD { Name5 charid }  (no ref prefix)  @ FUN_0042d0f0
    Clients_BroadcastInGame(0x5424 NC_FRIEND_SOMEONE_GET_SPECIALITEM_WORLD_CMD { Name5 charid }, skipArena = 1)
    failure: log "ERROR - CParserZone::fc_NC_FRIEND_SOMEONE_GET_SPECIALITEM_ZONE_CMD : World broadcast fail"
    # client: "%s has received Karis with friend points." (zone side: Z05 0x34C0 "FriendBroadcastItemID")
```

---

## 6. Kingdom quest (dept 22 KQ)

### 6.1 The `CKQ` object (`g_InstanceMaps`, DAT_0055e15c) and the player fields

Offsets from the object (W01 named the global; `CKQ::Add` string). Names ours unless quoted.

| Offset | Field |
|---|---|
| +0 | i32 count (≤ 300) |
| +4 + i·0x179 | `PROTO_KQ_INFO` kq[i] *(pdb2017 layout; Handle +0, Status +4, NumOfJoiner +5, ID +7, Title +9, StartTime +0x4B, StartWaitTime +0x73, MinLevel +0x75, MaxLevel +0x76, MinPlayers +0x77, MaxPlayers +0x79, DemandClass +0x84 (u64 bit per class), DemandGender +0x8C (bit per gender), RunCounter +0xBF, MapLink[4] +0xC0 (0x1A each: u8 slot, Name3 map, Name3 instance map, u8 flag), all used at these offsets)* |
| +0x1B9D4 | KQ data table (rows: u16 ID, …, map indices u16[4] @+0x66, schedule fields @+0x46…+0x4D); +0x1BA08 → row count @+0x28 |
| +0x1BA14 / +0x1BA48 | map-allocation table (rows: map name @+1, 10 instance names @+0x21 + slot·0x20, flags @+0x161 + slot); +0x1BB14 → slot owner array (10 i32 handles per row) |
| +0x1BA54 / +0x1BA88 | vote-rate table (row byte 0 = required "for" percentage, indexed by how often the target was voted on) |
| +0x1BA94 / +0x1BAC8 | vote-allowed table (u16 ID, u8 allowed == 1) |
| +0x1BAD4 / +0x1BB08 | team table (u16 ID, u8 maxImbalance @+2, u16 teamMode @+4: 1 random teams at start, 2 player-chosen teams) |
| +0x1BB18 | i32 now (tick time); +0x1BB1C tm; +0x1BB40 next tick time; +0x1BB48 last schedule minute |
| +0x1BB4C + i·4 | i32 joinerCount[i] |
| +0x1BFFC + i·0x1130 + j·0x2C | joiner[i][100]: +0 u32 charNo, +4 u16 wmHandle, +6 u8 level, +7 u8 class, +8 Name5 name, +0x1C u8 team (0 red, 1 blue, 2 none; `KQ_TEAM_TYPE`), +0x20 u32 ballotOpen, +0x24 u32 banned, +0x28 u8 timesVotedOn |
| +0x15E43C + i·2 | u8 redCount, u8 blueCount |
| +0x15E694 + i·0x14 | vote: u8 voteTeam (2 idle), i32 starterIdx (−1), i32 targetIdx (−1), i32 endTime, u8 yes, u8 no, u8 outstanding |

Player session: +0x258C i32 joinedKQ (handle, −1 none); +0x2590 u32 listTimeSent; +0x2594 a private copy of the
last KQ list sent (count + PROTO_KQ_INFO[]) used for diffs; +0x1DF68 u32 wantsListRefresh, +0x1DF6C i32 lastRefresh;
+0x1DF70 i32 voteSuggestNextTime; +0x1DF74 u32 bannedWhileAway (0x5830 at next map login; setter not read);
+0x1DF78 i32 joinListTime.

**Status** (byte kq+4; names ours): 0 scheduled, 1 making (0x580D sent), 2 recruiting, 3 starting (10-s countdown),
4 running, 5 ended (0x5810), 6 cancelled (`CKQServer::SetDoneSkip`), 8 make failed, 9 make timed out, 0x0B removed
(OPTool 0x2811, a late 0x580E, or superseded); 10 only appears in 0x5804 as "no such KQ". Lists sent to clients
contain Status < 5 only.

Helpers: `KQ_FindByHandle` FUN_0045ce90 (→ entry ptr), W01/part 1's `KQ_FindIndexByHandle` FUN_0045cd80,
`KQ_IsJoiner(s, handle)` FUN_004524d0 (by wmHandle), `KQ_FindJoinerByName` FUN_00452db0, `KQ_GetJoinerName` FUN_00452530,
`KQ_FindTeamRow(ID)` FUN_00451e50 (needs the ID in the data table, then the team table row), `KQ_IsVoteAllowed(ID)`
FUN_00451da0, `KQ_IsVoteRunning` FUN_00452d40 (starter and target ≠ −1), `KQ_ResetVote` FUN_00452cf0,
`KQ_IsRunning(handle)` FUN_00452d70 (Status 4). The temporary list in `KQ_SendListDiff` is a CKQ-shaped stack object: init FUN_0045cfd0,
add FUN_0045cdb0, destroy FUN_0045cf90 (time stamp, count 0, per-entry destructor FUN_00454060 over the 4 MapLink
strings). Log helper with varargs `Log(1, "Msg", fmt, …)`: FUN_00460340 → FUN_00460130 / FUN_0045ff90 (W01 logging).

### 6.2 Tick (once per second)

```pseudo
KQ_Tick(kq)        called from the WM main loop FUN_00406760                          @ FUN_00456190
    if now < nextTick: return;  store now and localtime; nextTick = now + 1 s
    KQ_TickMakeTimeout   @ FUN_00452270: Status 1 and now ≥ StartTime + 1 min → Status 9; free its map slots
                                         (no 0x5811 is sent)
    KQ_TickSchedule      @ FUN_00455e40: once per new minute, for each KQ data row compute the next occurrence
                                         (FUN_00452160) and add it (FUN_004555d0) — not expanded (see "Not reconstructed")
    KQ_TickMake          @ FUN_00455980: Status 0 and StartTime ≤ now:
                             KQ_AllocMaps (FUN_00453eb0): for each of the row's 4 map indices (0xFFFF = unused) take a
                             free instance slot (FUN_00451fd0) and fill MapLink[j]; any failure → 0
                             ok → Status 1, CKQServer::Send_NC_KQ_W2Z_MAKE_REQ: broadcast to all zones
                                  0x580D NC_KQ_W2Z_MAKE_REQ { PROTO_KQ_INFO } (0x179)          @ FUN_00454b50
                             fail → Status 8
    KQ_TickStart         @ FUN_00455f90:
        Status 2:
            joinerCount ≥ MaxPlayers: log "m_JoinerCount == %u > MaxPlayers: %u"; Status 3; RunCounter = 10
            elif StartTime + StartWaitTime min ≤ now:
                joinerCount < MinPlayers: log (same text, with MinPlayers); SetDoneSkip(i, 2)
                elif KQ_CheckTeamsBeforeStart(i) (FUN_004553c0; teamMode 2: a team empty → SetDoneSkip(i, 2),
                     |red − blue| > maxImbalance → SetDoneSkip(i, 3)): Status 3; RunCounter = 10
        Status 3:
            RunCounter == 0: Status 4
                KQ_AssignRandomTeams FUN_00453540 (teamMode 1: per joiner a random side, forced to the side below half)
                KQ_RemoveJoinersFromParties FUN_00453490 (online joiners: Client_RaidOnMapLogin; in a raid → FUN_00435ad0,
                     else in a party → Party_Leave; W02)
                Send all zones 0x580F NC_KQ_W2Z_START_CMD { PROTO_KQ_INFO, u16 NumOfJoiner, { u32 chrregnum, u8 nTeamType }[n] }
                                                                                         @ FUN_00454a10
            else: RunCounter == 10: notice WM text #1 (Title, 10) to the joiners (0x580B, below)
                  broadcast 0x5825 (Status ≠ 2); RunCounter −= 1
    KQ_TickPurge         @ FUN_00454080: a KQ with Status 5…10 whose ID has a later-starting KQ also in 5…10 → Status 0x0B;
                         the removal pass (FUN_00452040, FUN_004526e0, FUN_00451ab0) is guarded by a local Ghidra
                         shows unset (uncertain, see "Not reconstructed")
    KQ_RefreshOneClient  @ FUN_00455dd0: among sessions with wantsListRefresh == 1 pick the one with the oldest
                         lastRefresh (< now); lastRefresh = now; KQ_SendListDiff (§6.3)    # one client per second
    KQ_TickVote          @ FUN_00454f60 (§6.5)

CKQServer::SetDoneSkip(i, reason)                                                      @ FUN_004548c0
    Status 6; log "DEBUG - CKQServer::SetDoneSkip, HANDLE=%d"
    broadcast zones 0x5811 NC_KQ_W2Z_DESTROY_CMD { u32 hquest } (FUN_00452880); free its map slots (FUN_00452040)
    reason 2: notice WM text #2 (Title, NumOfJoiner, MinPlayers) to the joiners
    reason 3: notices WM text #3 and #4 to the joiners
    joiners' joinedKQ = −1 (FUN_004526e0; joiner list itself kept); broadcast 0x5825

Notices and alarms:
    KQ_SendNotify(i, text)          @ FUN_00452750: 0x580B NC_KQ_NOTIFY_CMD { u8 MsgLength, Msg (+NUL) } to each joiner
                                    online, inGame, charNo matching
    KQ_SendJoiningAlarm(text, i)    @ FUN_00452930: only Status 2: every client session (also not in game) ←
                                    0x5824 NC_KQ_JOINING_ALARM_CMD { KQ_JOINING_ALARM_INFO { u32 Handle, u16 ID, u8 MinLevel,
                                    u8 MaxLevel }, u8 MsgLength, Msg }
    KQ_SendJoiningAlarmEnd(i)       @ FUN_00452a70: Status ≠ 2: every client session ← 0x5825 { u32 nHandle, u16 nID }
    KQ_SendJoiningAlarmList(s)      @ FUN_00452b60 (map login, W01 §7): s ← 0x5826 { u16 n, KQ_JOINING_ALARM_INFO[n] }
                                    for every Status-2 KQ
    (WM texts #0…#4: `FUN_00404570(&g_WM, n)`, a message table loaded by W01's config; contents not traced)
```

The 2016 in-game client has no 0x580B handler (C01 lists 0x580B only in the character-select scene, as the option
blob), so the KQ notices are not shown in game *(inferred from C01's table)*.

### 6.3 Zone answers (CParserZone)

```pseudo
0x580E NC_KQ_Z2W_MAKE_ACK { u32 hquest, u16 err }                                       @ FUN_0042a9c0
    err == 0x981: KQ_OnMakeOk(hquest)                                                    @ FUN_00454170
        unknown handle: broadcast 0x5811 { hquest }; log "WARNING - KQ UNKNOWNED HANDLE FROM ZONE, Handle=%d"
        Status ∉ {1, 2}: log "WARNING - KQ FROM ZONE Over 1 minute or unknowned handle come, KQ HANDLE=%d,STATUS=%d";
            Status 0x0B; broadcast 0x5811; free its map slots; joiners' joinedKQ = −1
        else: joinerCount = 0; NumOfJoiner = 0; vote reset; red/blue = 0; Status 2
            KQ_SendJoiningAlarm(WM text #0 with Title, i)
        # a second 0x580E for a KQ already in Status 2 empties its joiner list again without telling the joiners
    else: KQ_OnMakeFail (FUN_00452440): Status 8 (unknown handle: log DAT_0048c3a4)
          FUN_00460340("Check - CParserZone::fc_NC_KQ_Z2W_MAKE_ACK, NOMAP, KQ_HANDLE=%d, KQ_ID=%d, KQ_Title='%s'")
    # Z08 §4 / Z08-B8: a zone that does not host the maps sends nothing; the WM waits 1 minute in Status 1, then
    # Status 9 (KQ_TickMakeTimeout). So the missing answer is covered by the timeout.

0x5810 NC_KQ_Z2W_END_CMD { u32 Handle }                                                 @ FUN_0042aac0
    log "DEBUG - CParserZone::fc_NC_KQ_Z2W_END_CMD, HANDLE=%d"
    KQ_OnEnd (FUN_00454860): Status 5; broadcast 0x5811 { Handle }; free its map slots; joiners' joinedKQ = −1
```

### 6.4 Client requests: list, status, join (CParserClient)

```pseudo
0x5801 NC_KQ_LIST_REQ { u32 StartHandle, u32 EndHandle }  (ignored)                    @ FUN_00413980
    n = number of KQs with Status < 5
    Send s 0x5802 NC_KQ_LIST_ACK { i32 ServerTime = time(), tm tm_ServerTime (localtime), u32 NewStartHandle (first listed,
        −1 when n = 0), u32 NewEndHandle (last listed; unwritten when n = 0), u16 NumOfNewQuest = n,
        PROTO_KQ_INFO_CLIENT[n] (first 0x8D bytes of each entry) }
    # the 2016 client ignores 0x5802 (C01); its KQ window uses 0x581C…0x581F
    # (original bug) W04-B16: entries are copied into the 8 KB stack packet without a bound: > 57 listed KQs overflow it

0x5803 NC_KQ_STATUS_REQ { u32 Handle }                                                  @ FUN_00413b20
    k = KQ_FindByHandle(Handle)
    none: Send 0x5804 NC_KQ_STATUS_ACK { Handle, u8 Status = 10, u16 NumOfJoiner = 0 }
    else: Send 0x5804 { Handle, k.Status, k.NumOfJoiner, Name5 JoinerNameList[n] = name of each joiner's session
          (KQ_GetJoinerName by wmHandle; "" when that handle has no CHARDATA) }

0x5805 NC_KQ_JOIN_REQ { u32 Handle }                                                    @ FUN_00413cc0
    # reply 0x5806 NC_KQ_JOIN_ACK { u32 Handle, u16 Error }
    s.CHARDATA present and prisonMin ≠ 0: 0x999 (client silent)
    KQ_IsJoiner(s, Handle): 0x99A "Selected Kingdom Quest has been already registered"
    else:
        KQ_LeaveJoinList(s)                    # leaves the KQ s was registered for, before checking the new one
        Error = 0x991 + KQ_Join(s, Handle)     # (original bug) W04-B15: a failed join still loses the old registration
    # (original bug) W04-B17: with no CHARDATA (any validated session before character select) the checks fall through
    # and KQ_Join dereferences the null CHARDATA when the KQ exists and has room → WM crash; KQ handles are broadcast to
    # every session in 0x5824

KQ_Join(s, h) → 0…7                                                                     @ FUN_004542f0
    k = KQ_FindByHandle(h) none → 1                                       0x992 "Cannot find the Kingdom Quest."
    joinerCount ≥ 100 or ≥ MaxPlayers → 2                                 0x993 "There are too many participants."
    KQ_CheckJoinCondition(h, level, class, gender) @ FUN_0045ced0:
        Status ≠ 2 → 3                                                    0x994 "…Please check your status."
        level ∉ [MinLevel, MaxLevel] → 4                                  0x995 "…due to the level limit."
        DemandClass bit (1 << class) clear → 5                            0x996 "…due to the class limit."
        DemandGender bit (1 << gender) clear → 6                          0x997 "…due to the gender limit."
        (other → 7                                                        0x998 "You cannot participate in the Kingdom Quest.")
    ok → 0 (0x991 "Successfully participating in the Kingdom Quest."): append joiner { charNo, wmHandle, level, class,
        name, ballot 0, banned 0, timesVotedOn 0 }; team: teamMode 2 → the smaller of red/blue (ties → blue), else 2;
        NumOfJoiner = joinerCount; s.joinedKQ = h
        KQ_SendJoinListToJoiners(h)                                              @ FUN_00453bd0
            every joiner session with CHARDATA ← 0x5832 NC_KQ_JOIN_LIST_ACK { u16 nError = 0x3118, u8 nNum,
                KQ_JOIN_CHAR_INFO[n] { u8 level, u8 class, Name5 name, u8 team } }; its joinListTime = now
    # DemandQuest / DemandItem / PlayerRepeat* are not checked by the WM (the zone checks at entry, Z08 §4, inferred)

0x5807 NC_KQ_JOIN_CANCEL_REQ { u32 Handle }                                             @ FUN_00413d70
    Send 0x5808 NC_KQ_JOIN_CANCEL_ACK { Handle (echoed), Error = KQ_LeaveJoinList(s) ? 0x9A1 : 0x9A2 }
    # leaves whatever KQ s is in, whatever Handle says. Client: 0x9A1 "Kingdom Quest participation is canceled.",
    # 0x9A2 "Failed to cancel Kingdom Quest participation."

KQ_LeaveJoinList(s) → 1 removed / 0                                                     @ FUN_00454510
    s.joinedKQ == −1 or unknown, or no joiner with s.wmHandle and s.charNo: return 0
    if s is the vote target and not banned:
        every other joiner (online, inGame) ← 0x582E NC_KQ_VOTE_CANCEL_CMD { Name5 sTarget }  # "Voting interrupted
        clear all ballots; reset the vote                                                   # because %s went to another region."
    team < 2: that team's count −= 1
    remove the joiner (memmove), joinerCount −= 1, NumOfJoiner = joinerCount, fix starter/target indexes
    broadcast zones 0x583B NC_KQ_PLAYER_DISJOIN_CMD { u32 nHandle, u32 nCharNum }          @ FUN_00453b10
    KQ_SendJoinListToJoiners(handle); s.joinedKQ = −1; return 1
    # also called by CharacterLogout (W01 §5.4), the prison add 0x7C0C (part 3), FUN_00410040 (W01) and map login

0x5809 NC_KQ_SCHEDULE_REQ { u32 StartHandle, u32 EndHandle } (ignored)                  @ FUN_00413e00
    Send 0x580A NC_KQ_SCHEDULE_ACK { u32 NewStartHandle = kq[0].Handle, u32 NewEndHandle = kq[count−1].Handle,
        u16 NumOfNewQuest = count, PROTO_KQ_INFO_CLIENT[count] (all statuses) }
    count == 0: { −1, (unwritten), 0 }
    # client ignores 0x580A (C01). Same unbounded stack copy as 0x5802 (W04-B16; > 57 KQs)

0x581B NC_KQ_LIST_REFRESH_REQ {}                                                        @ FUN_00413f80
    s.wantsListRefresh = 1 (never cleared); s.lastRefresh = now; KQ_SendListDiff(s)

KQ_SendListDiff(s)                                                                      @ FUN_004559e0
    if !s.listTimeSent: Send 0x581C NC_KQ_LIST_TIME_ACK { i32 ServerTime, tm } (0x28); fail → return; listTimeSent = 1
    cur = the KQs with Status < 5 (temporary list, FUN_0045cfd0 / FUN_0045cdb0)
    for each KQ in s's copy: gone from cur → delete list; Status or NumOfJoiner changed → update list
    deletes: Send 0x581E NC_KQ_LIST_DELETE_ACK { u16 n, u32 Handle[n] }
    updates: Send 0x581F NC_KQ_LIST_UPDATE_ACK { u16 n, KQ_UPDATE_ITEMS { u32 Handle, u8 Status, u16 NumOfJoiner }[n] }
    new ones: Send 0x581D NC_KQ_LIST_ADD_ACK { u16 n, PROTO_KQ_INFO_CLIENT[n] }, split when the size passes 0x1D25
    s's copy = cur (FUN_00454c30); any failed send aborts without updating the copy
```

### 6.5 Vote ban, team choice, joiner list

Error codes and client texts: 0x5828 VOTE_START_ACK (`On_NC_KQ_VOTE_START_ACK` FUN_004b4180) shows 0x3103 "A vote is
currently under way. You cannot give an opinion.", 0x3108 "Try again later.", 0x3109 "This Kingdom Quest is not for
vote."; the other codes are silent. 0x5835 (FUN_004b43d0): 0x3120 opens the vote dialog, 0x3122 "Please wait 5minutes
before starting another vote.". 0x5838 (FUN_004b4460): 0x31F0 "You've joined the Red Team." / "…Blue Team."
(nTeamType 0/1), 0x31F1–0x31F3, 0x31F5–0x31F7 "You cannot change teams.", 0x31F4 "You cannot change teams because they
are not balanced" *(the last mapping inferred from the remaining text id)*.

```pseudo
0x5827 NC_KQ_VOTE_START_REQ { Name5 sTarget, u8 nVoteType, u8 nLen, char sContents[nLen] }   (needs CHARDATA)
                                                                     @ FUN_004185e0 → KQ_VoteStart FUN_00456310
    s not inGame: return.  Reply 0x5828 NC_KQ_VOTE_START_ACK { u16 nError }
    s.joinedKQ −1 / unknown / s not a joiner (by name)           → 0x3101
    Status ≠ 4 (running)                                         → 0x3102
    vote already running                                         → 0x3103
    !KQ_IsVoteAllowed(ID)                                        → 0x3109
    target not a joiner, not online, not inGame, already banned,
        or on another team than s                                → 0x3105
    target == s                                                  → 0x3106
    nLen == 0                                                    → 0x3107
    now < s.voteSuggestNextTime                                  → 0x3108
    ok: Send s 0x5828 { 0x3100 }
        s.voteSuggestNextTime = now + ServerParam "KQVote_SuggestCoolTime"
        vote = { voteTeam = s.team, starterIdx, targetIdx, endTime = now + "KQVote_VoteLimitTime", counts 0 }
        every other joiner (not starter, not target) on voteTeam, online and inGame ←
            0x5829 NC_KQ_VOTE_VOTING_CMD { Name5 sStarter, Name5 sTarget, u8 nVoteType, tm tEndTime (FUN_00456250),
                                           u8 nLen, sContents[nLen] }  (0x4E + nLen)
            and gets ballotOpen = 1, outstanding += 1
    # nLen is not checked against the request length (reads past a short packet)

0x582A NC_KQ_VOTE_VOTING_REQ { u32 eVoteType (KQ_VOTING_TYPE: 0 cancel, 1 yes, 2 no) }  @ FUN_00418630 → FUN_00452ee0
    reply 0x582B NC_KQ_VOTE_VOTING_ACK { u16 nError }
    not in a KQ / not a joiner → 0x3111;  no vote running or voter's team ≠ voteTeam → 0x3112;  ballot not open → 0x3113
    ok: ballotOpen = 0; Send 0x3110; eVoteType 1: outstanding −1, yes +1;  2: outstanding −1, no +1;  other: nothing
        (the ballot is used up but stays counted as "outstanding" = void)
    # client 0x3110: "You have voted "For"/"Against" the banning." for its own choice; otherwise "Refraining from
    # voting will result in your vote being declared as void."

KQ_TickVote (every second, per KQ)                                                       @ FUN_00454f60
    every banned joiner online and inGame: KQ_SendLinkToForceByBan(s)                      @ FUN_004531a0
        → s's zone 0x5833 NC_KQ_LINK_TO_FORCE_BY_BAN_CMD { u32 nCharNum, Name3 sMapName[4] = MapLink[0…3].instance map }
        # repeated every second while the player stays online (Z08 §4 sends them to Roumen)
    vote running and endTime < now:
        need = vote-rate row [min(target.timesVotedOn, rows − 1)] byte 0 (0 when no row); target.timesVotedOn += 1
        pct = yes · 100 / (yes + no)  (0 when yes == 0)
        pct ≥ need: 0x582C NC_KQ_VOTE_RESULT_SUC_CMD { Name5 sTarget, u8 nVoteRate = need, u8 yes, u8 no, u8 cancel = outstanding }
        else:       0x582D NC_KQ_VOTE_RESULT_FAIL_CMD { Name5 sTarget, u8 yes, u8 no, u8 cancel }
        → every joiner on voteTeam (ballot cleared) online and inGame
        success: target.banned = 1; target (online, inGame == 1) ← 0x582F NC_KQ_VOTE_BAN_MSG_CMD { u8 nVoteRate,
                 u8 nYesNum, u8 nNoNum, u8 nCancelNum }
        reset the vote

0x5834 NC_KQ_VOTE_START_CHECK_REQ {}                                    @ FUN_004186d0 → FUN_00453340
    only if s inGame, in a known KQ with Status 4 (else no reply):
    Send 0x5835 NC_KQ_VOTE_START_CHECK_ACK { u16: 0x3121 vote running, 0x3122 now < voteSuggestNextTime, else 0x3120 }

0x5831 NC_KQ_JOIN_LIST_REQ { u32 nHandle }                              @ FUN_00418680 → KQ_SendJoinList FUN_004568c0
    handle = s.joinedKQ if that KQ is running, else nHandle
    unknown: 0x5832 { 0x3119, 0 }
    now < s.joinListTime + ServerParam "KQPlayerList_ResetListCoolTime": 0x5832 { 0x311A, 0 }
    else s.joinListTime = now; 0x5832 { 0x3118, n, KQ_JOIN_CHAR_INFO[n] } (as KQ_SendJoinListToJoiners)
    # any player may list the joiners of any KQ by handle

0x5837 NC_KQ_TEAM_SELECT_REQ { u8 nTeamType }                           @ FUN_00418e10 → KQ_TeamSelect FUN_004536c0
    reply 0x5838 NC_KQ_TEAM_SELECT_ACK { u16 nError, u8 nTeamType (2 unless success) }
    not in a KQ → 0x31F1;  Status ≠ 2 → 0x31F2;  no team row → 0x31F6;  teamMode ≠ 2 → 0x31F7
    find s's joiner entry (by charNo):
        same team → 0x31F3
        newCount = count[nTeamType] + 1;  newCount ≥ MaxPlayers / 2 → 0x31F4
        newCount − (count[oldTeam] − 1) > maxImbalance → 0x31F5
        ok: team = nTeamType; count[old] −= 1 (clamped at 0); count[new] = newCount
            Send s 0x5838 { 0x31F0, team }; every other joiner with CHARDATA ← 0x5839 NC_KQ_TEAM_SELECT_CMD { Name5 sCharID, u8 nTeamType }
    # (original bug) W04-B18: nTeamType is not range-checked: values ≥ 2 index count[] past the KQ's two bytes (writes
    # into the next KQs' team counters, up to 255 bytes on) and store an invalid team. "≥ MaxPlayers / 2" also keeps a
    # team one short of half. If s is not in the joiner list, an uninitialised 0x5839 goes to every joiner.

KQ_OnMapLogin(s, map)            from 0x180C (W01 §7 "g_InstanceMaps.OnEnter")           @ FUN_00456b20
    s.bannedWhileAway == 1: Send s 0x5830 NC_KQ_VOTE_BAN_MSG_LOGOFF_CMD {}; clear       # "Banned by the voting result…"
    s's KQ is running and map is none of its 4 MapLink maps (FUN_00454dc0): KQ_LeaveJoinList(s)
    s's KQ is running and map is one of them (FUN_00454e50): KQ_SendJoinList(s, s.joinedKQ)

KQ_CanReturnToMap(handle, map, packedDate)       W01's "Redirect" at character login      @ FUN_00452580
    for the KQ with that handle: if map is one of its MapLink maps, the map's zone is up, and now < packedDate + 10 min
    (packed: year:4 (+2000), month:4, day:5, hour:5, minute:6, second:6): return early  # the character may go back to
    the KQ map; the result is returned in a register Ghidra drops (W01 §5 reads it as the redirect condition)
```

---

## 7. Character title relay (dept 24 CT)

```pseudo
Zone 0x6009 NC_CT_LUASCRIPT_SET_WORLD_CMD { u32 nCharNo, CT_INFO CTInfo { u8 Type, u8 ElementNo:6, ElementValue:2 } }
                                                                                         @ FUN_0042cda0
    # sent by the zone's Lua `cSetCharacterTitle` (zone FUN_005eb310) when the player is not on that zone
    s = Clients_FindByCharNo(nCharNo) with CHARDATA; z = the zone session of s.zoneNo (+0x117)
    Send z 0x380A { u32 nCharNo, u16 CTInfo }   (6)
    # (original bug) W04-B19: 0x380A is dept 14 (party) cmd 10; the 2017 enum has 0x600A NC_CT_LUASCRIPT_SET_ZONE_CMD
    # for this. No 2016 zone registers 0x380A or 0x600A, so a script title grant for a player on another zone is lost.
```

0x6006 NC_CT_CHARTTING_CMD (whisper/party chat, §2) and 0x6007 NC_CT_ADD_FRIEND_CMD (§5.3) are the WM's other CT sends.

---

## Original-server bugs

(Running list; the sweep part completes it.)

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| W04-B1 | 0x2010 (client, zone, OPTool) | notice text (len ≤ 255) copied into a 0x83-byte stack area; size byte `len+4` wraps for len > 251; payload byte 0 of 0x2011 never written | notices over 131 bytes crash the WM (stack cookie); the client also overflows its 0x80 buffer | clamp len to 0x80 like the client's chat input |
| W04-B2 | 0x200C | `itemLinkDataCount` unchecked; `count·0x67` bytes copied into the 8 KB stack packet (and read past the request) before the size check | any player can crash the WM with count ≳ 80 | reject count above the client's link limit |
| W04-B3 | 0x2014 | same unchecked `itemLinkDataCount` in party chat | same crash | same |
| W04-B4 | 0x200C | empty whisper (len 0) answered with 0x200F whose count byte is stale stack data | client may parse garbage item links | write count = 0 |
| W04-B5 | 0x200C | too-long whisper answered with 0x200E code 0x0F6B, which the client ignores | message silently lost | use a code the client shows |
| W04-B7 | 0x2803 | no CheckAlive, `closekey` and `req_server_id` never checked | anything that connects to the OPTool port stops the WM | require the handshake and a key |
| W04-B8 | 0x2801 | connection list (5 + clients + zones + tools, 7 bytes each) written into an 8 KB stack packet without a bound | stack overflow with > 1169 live sessions | cap the list or split it |
| W04-B9 | 0x2809 | empty KQ list: NumOfTotal and NumOfQuest of 0x280A not written | tool reads stale numbers | write 0 |
| W04-B10 | 0x2827 / 0x2829 | user not found: 0x124 bytes after the flag are stale stack data | leaks WM stack memory to the tool | zero the reply |
| W04-B11 | 0x282B | "guild not found" (0x1E4A) and "not scheduled" (0x1E4B) sent as 0x2825 NC_OPTOOL_GUILD_DATA_CHANGE_ACK | tool never gets its 0x282C answer on these errors | send 0x282C |
| W04-B12 | 0x5411, 0x541F | 0x5408 / 0x5420 friend entries: `logininfo` bits 1–31 and `statustitle` bytes 2–31 are never written (stack / packet-buffer garbage) | client may show a garbage last-login date or status title | zero the PROTO_FRIEND_INFO first |
| W04-B13 | 0x5411 (error) | the DB error goes to the accepting player as 0x5402 with `charid` = the requester (or "UNKNWONED") | the client drops it (shows 0x5402 only for its own charid): the accepter never sees why the friendship failed | send the accepter a 0x5402 with its own name as charid |
| W04-B14 | 0x5413 | after a delete neither side's zone gets 0x6007 NC_CT_ADD_FRIEND_CMD (inferred: only adds send it) | title condition 0x22 (number of friends) keeps the old count | send 0x6007 with the new count on delete too |
| W04-B15 | 0x5805 | the old KQ registration is dropped (`KQ_LeaveJoinList`) before the new join is checked | a refused join (level, class, full…) silently loses the player's current KQ place | check first, then leave |
| W04-B16 | 0x5801, 0x5809 | KQ entries (0x8D bytes each) copied into the 8 KB stack packet without a bound; 0x5809 with no KQ leaves NewEndHandle unwritten | more than 57 listed KQs overflow the WM stack | cap or split the list |
| W04-B17 | 0x5805 | no CHARDATA check: before character select the prison check is skipped and `KQ_Join` reads level/class through the null CHARDATA | any validated session can crash the WM with a recruiting KQ's handle (handles are broadcast in 0x5824) | require CHARDATA and inGame |
| W04-B18 | 0x5837 | `nTeamType` not range-checked; ≥ 2 indexes the per-KQ team counters out of bounds; `newCount ≥ MaxPlayers/2` refuses exactly half; joiner not found → uninitialised 0x5839 broadcast | memory corruption of other KQs' counters; teams can never fill to half by choice | accept 0/1 only; `>`; return when not found |
| W04-B19 | zone 0x6009 | forwarded to the player's zone as 0x380A (dept 14) instead of 0x600A NC_CT_LUASCRIPT_SET_ZONE_CMD (dept 24), which no zone handles either | Lua title grants for a player on another zone are lost | send 0x600A and handle it on the zone |
| W04-B20 | 0x5401 | `charid` of the request is not compared with the sender's name; it is echoed to the target in 0x5403 | a player can send friend requests under any name (the confirm then fails with 0x94E) | use the session's own name |
| W04-B21 | 0x541F | candidates cut at ≈ 113 in table order before the level sort; error 0x36C6 (own list full) has no client text | on busy worlds close-level players are missed; a full list gets no feedback | sort over all, then cut; use 0x36C1 |

(W04-B6 is reserved; not used.)

## Not reconstructed / uncertain (running list)

- KQ schedule (`KQ_TickSchedule` FUN_00455e40 → FUN_00452160 next-occurrence, FUN_004555d0 add) and the KQ data /
  map-allocation / vote-rate / vote-allowed / team tables at CKQ+0x1B9D4…+0x1BB08: who loads them (SHN or DB) and the
  row layouts beyond the fields used in §6 are not read. `KQ_AllocMaps` FUN_00453eb0 and its slot finder FUN_00451fd0
  only as far as §6.2.
- `KQ_TickPurge` FUN_00454080: the removal pass for Status-0x0B entries (FUN_00451ab0) depends on a local that Ghidra
  shows as never written; check the asm whether it runs.
- The WM message texts #0…#4 (`FUN_00404570(&g_WM, n)`) used for KQ alarms/notices: source table not traced.
- Who sets session +0x1DF74 (0x5830 "banned while away"); FUN_00410040 (W01) also calls `KQ_LeaveJoinList` and
  `KQ_CanReturnToMap`.
- 0x582A voter index: Ghidra shows the voter's joiner index as `extraout_EDX` after `KQ_IsVoteRunning`; read as the
  index returned by `KQ_FindJoinerByName` *(inferred)*.
- A banned KQ player stays in the joiner list and gets 0x5833 every second while online; whether the zone ignores the
  repeats once the player has left the KQ maps is Z08's (§4).
- KQ handles: 0x5819 NC_KQ_ENTRYRESPONCE_REQ (Z08 question) is not sent by the 2016 WM (no send site); the client
  learns KQ handles from 0x5824 / 0x5826 / 0x581D.
- 0x2822 computes the "next scheduled start" from the active GuildTournament.shn row but only returns it (`nGTNo`)
  and resets the guilds' GT_COND_INFO; whether the OPTool then sends 0x2815 with that time is unknown (tool binary
  not available).
- 0x2815 / 0x2820 / 0x2824 change WM memory only. No CharDB request is sent; we assume the operator tool writes the
  database itself *(inferred)*. Zones are not told of a guild rename or grade change by these paths.
- The client flag set by the notice text "Admin level is 100" (client `this+0x91`).
- 0x281C `bPart = 4` with no data: the 2016 WM keeps no send statistics; the tool's reading of bPart 4 is unknown.
