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

(W04-B6 is reserved; not used.)

## Not reconstructed / uncertain (running list)

- 0x2822 computes the "next scheduled start" from the active GuildTournament.shn row but only returns it (`nGTNo`)
  and resets the guilds' GT_COND_INFO; whether the OPTool then sends 0x2815 with that time is unknown (tool binary
  not available).
- 0x2815 / 0x2820 / 0x2824 change WM memory only. No CharDB request is sent; we assume the operator tool writes the
  database itself *(inferred)*. Zones are not told of a guild rename or grade change by these paths.
- The meaning of KQ Status 0x0B (set by 0x2811) and of the map-allocation object at CKQ+0x1BA48: part 2.
- The client flag set by the notice text "Admin level is 100" (client `this+0x91`).
- 0x281C `bPart = 4` with no data: the 2016 WM keeps no send statistics; the tool's reading of bPart 4 is unknown.
