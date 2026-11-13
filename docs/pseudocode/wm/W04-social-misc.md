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
| +0x1E290 … +0x1ECBF | chat block list (count, info[100], listFresh, charNo[100]) | §14.1 |
| +0x1ED04 | gamble-house return map (Name3) | §15.2 |

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

Library code reached from this item's handlers (no behaviour of its own; listed so later readers do not reopen it):
W01's `ServerParam_GetInt` (FUN_00459f10) looks the name up in a `std::map<std::string, int>`: `operator[]`
FUN_00459d00 = lower-bound walk FUN_00459220 + string compare FUN_004590b0, and on a miss inserts a 0 entry
(FUN_004599a0 make node, FUN_00459a80 insert/rebalance), so an unknown parameter name reads as 0. The `PrisonMap`
of §9.1 is a `std::map` too; FUN_00457950 / FUN_00457970 are its right-most / left-most node walks used by
`PrisonMap_Erase`. `LogLevel` FUN_00407ae0 (W01) formats a log line with the level byte and prefix of a 0x41-byte
table entry.

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

### 2.5 Gold-spammer alert to GMs (0x200D, reached from W01's 0x085F)

The handler of client 0x085F NC_MISC_SPAMMER_REPORT_REQ *(pdb2017 name)* `FUN_00417ef0` (W01 hand-off, full block in §17.4)
ends in a whisper-shaped alert that this section documents. Table: `SpamerReport.shn`, loaded by
W01's FUN_00404100 into the data object DAT_006c5220 (= WM +0x22B1F8; the same object later loads `GBHouse.shn`, §15.1).
Row 0 only: `SR_Term` u32 @+0 (2016 data: 3600 s), `SR_Number` u16 @+4 (5), `SR_Message` char[128] @+6
("Gold spammer has been reported"); getters FUN_0043a280 / FUN_0043a2a0 / FUN_0043a2c0 (0 / null when the table is empty).

Per reported session (names ours): +0x1ECEC → u32 reportTime[SR_Number], +0x1ECF0 → u32 reporterCharNo[SR_Number]
(ring buffers), +0x1ECF4 i32 ringIndex.

```pseudo
Spam_AlreadyReported(t, reporterCharNo)                                                @ FUN_00432b10
    any slot i < SR_Number with reporterCharNo[i] == reporterCharNo and now < reportTime[i] + SR_Term → 1 (reply 0x2163)

Spam_AddReport(t, reporterCharNo)                                                      @ FUN_00435200
    needs CHARDATA, reporterCharNo ≠ −1 and both ring buffers, else 0 (the handler replies 0x2163)
    reportTime[ringIndex] = now; reporterCharNo[ringIndex] = reporterCharNo
    ringIndex = (ringIndex + 1) % SR_Number
    if now − reportTime[ringIndex] ≤ SR_Term:          # the oldest of the last SR_Number reports is younger than SR_Term
        Spam_AlertGMs(t.CHARDATA.charid)                                               # every further report re-alerts
    return 1

Spam_AlertGMs(Name5 name)                                                              @ FUN_00432bb0
    msg = SR_Message (none → nothing sent)
    pkt 0x200D NC_ACT_SOMEONEWHISPER_CMD {               # size 0x17 + strlen(msg)
        u8 itemLinkDataCount = never written: stale stack byte (original bug) W04-B54
        Name5 talker = name of the reported character
        u8 flag: bit0 (GM colour) = 1, bits 1–7 stale
        u8 len = strlen(msg); content = msg }
    Clients_SendToGMs(pkt, minAdminLevel = 1)                                          @ FUN_00437bd0
        # every in-game session (+0x704 == 1) with CHARDATA, CHARDATA.adminlevel (+0x64) ≥ 1 and inArena ≠ 1
```

The client (§2.1) shows it as a GM-coloured whisper "from" the reported character and adds that name to the GM's
whisper list. With a non-zero stale count it also reads `count × 0x67` item-link bytes after the text, past the end of the
packet (W04-B54).

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
    else entries[i].Status = 0x0B          # nothing else: removal waits for KQ_TickPurge (§6.2, W04-B55)

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
        SendRaw CharDB 0x9424 NC_HOLY_PROMISE_DB_DEL_CHAR_REQ { u32 nCharNo }    # answer 0x9425: §12.4
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
    # client `On_NC_FRIEND_POINT_ACK` FUN_0049ad90: FriendWin::SetFriendPoint(friendpoint) if the friend window exists

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
+0x1DF70 i32 voteSuggestNextTime; +0x1DF74 u32 bannedWhileAway (set below, 0x5830 at the next map login, then 0);
+0x1DF78 i32 joinListTime.

**Construction and tables.** The object lives at WM +0xC4134. Constructor `CKQ_Construct` FUN_00455460: list init
(FUN_0045cfd0), five SHN table objects (FUN_00458a70), 30 000 joiner records (300 × 100), slot-owner pointer, now /
next-tick / last-minute = 0, `joinerCount[300]` = 0, vote state reset FUN_00452cb0 (voteTeam 2, starter / target −1,
rest 0); destructor FUN_00453da0. W01's data loader FUN_00404100 reads the tables into it at start-up; any failure is
fatal ("*FATAL ERROR* - KINGDOM QUEST … DATA READ FAILED"). The loader FUN_00458f00 checks the SHN header key and the
row size (header row size − 2) and refuses a mismatch.

| Offset | File (loader) | Header key / row size | Columns used (row offset) |
|---|---|---|---|
| +0x1B9D4 | `KingdomQuest.shn` (FUN_00451b40) | 0x2535 / 0xB4 | ID u16 +0, Title[64] +2, LimitTime +0x42, ST_Year/Month/Day/Hour/Minute/Second +0x44…+0x49, StartWaitTime +0x4A, NextStartMode +0x4C, NextStartDeleyMin u16 +0x4D, RepeatMode +0x4F, RepeatCount +0x50, MinLevel +0x52, MaxLevel +0x53, MinPlayers +0x54, MaxPlayers +0x56, PlayerRepeatMode +0x58, PlayerRepeatCount +0x59, PlayerRevivalMode +0x5B, PlayerRevivalCount +0x5C, DemandQuest +0x5D, DemandItem +0x5F, DemandMobKill +0x61, RewardIndex u32 +0x62, MapLink u16[4] +0x66, ScriptLanguage[32] +0x6E, InitValue[32] +0x8E, UseClass u32 +0xAE, DemandGender u8[2] +0xB2 (column names from the file) |
| +0x1BA14 | `KingdomQuestMap.shn` (FUN_00453e70) | 0x2085 / 0x16B | NumOfMap, BaseMap[32], Map[10][32], Clear[10]; on success FUN_00451ee0 (re)allocates the slot-owner array (+0x1BB14, 10 × −1 per row) |
| +0x1BA54 | `KQVoteMajorityRate.shn` (FUN_00451b60) | 1 / 1 | VoteAgreeRate (2016 data: 70, 50) |
| +0x1BA94 | `KQIsVote.shn` (FUN_00451b80 `CKQServer::ReadIsVote`) | 5 / 3 | ID, IsVote. Also checks that IDs are unique ("Same ID Exist - Line %d, %d") and that every KingdomQuest ID has a row ("Need IsVote Data - %d"); both only log, the load still succeeds |
| +0x1BAD4 | `KQTeam.shn` (FUN_00451d80) | 0xF1 / 0x16 | ID, MaxMemberGap +2, IsTeamPVP +3, KQTeamDivideType u16 +4, RegenXRed/YRed/XBlue/YBlue u32 +6…+0x12 |

**Rejoin after a reconnect** (called from W01's CharDB 0x1005 `CharDB_CharDataAck_1005` FUN_00410040 when
`KQ_CanReturnToMap` accepts the saved map link of blob 0x101A, session +0x648):

```pseudo
KQ_RejoinOnCharData(s)                                                                 @ FUN_00452e40
    i = KQ by the link's handle; j = KQ_FindJoinerByName(i, s.CHARDATA.charid); either missing → 0
    s.joinedKQ = handle; joiner[i][j].wmHandle = s.handle                    # the new session handle
KQ_IsJoinerBanned(s)                                                                   @ FUN_00454ee0
    joiner[i][j].banned == 1 (KQ or joiner not found → true; no session data → false)
FUN_00410040: banned → s.bannedWhileAway = 1; KQ_LeaveJoinList (§6.4); the character stays on its normal map
              else → CHARDATA map / x / y = the instance link (W01 §4.2)
```

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
    KQ_TickSchedule      @ FUN_00455e40: once per new minute (local time, seconds cut; stored at +0x1BB48):
        for each KingdomQuest.shn row:
            base = this month (current year / month), day ST_Day, ST_Hour:ST_Minute:00   # ST_Year, ST_Month, ST_Second unused
            KQ_NextOccurrences(base, NextStartDeleyMin, nowMinute)                       @ FUN_00452160
                add NextStartDeleyMin minutes to base until base ≥ nowMinute (mktime normalises); return that time
                and the one after it (2 entries; mktime failure → 0 entries)
                # NextStartDeleyMin == 0 with base < now never ends (original bug) W04-B57 (2016 data: 60…360)
            KQ_AddScheduled(row, times)                                                  @ FUN_004555d0
                for each time T: skip if a KQ with this ID and ScheduleTime (+0x97) == T exists; else build a
                PROTO_KQ_INFO: Handle = nextHandle (+0x1BB44, then +1), Status 0, NumOfJoiner 0, ID, Title,
                LimitTime, StartTime = ScheduleTime = T (+ both `tm`s), StartWaitTime, Min/MaxLevel, Min/MaxPlayers,
                PlayerRepeatMode/Count, PlayerRevivalMode/Count, DemandQuest, DemandItem,
                DemandClass = u64 class mask of UseClass (FUN_00465a90 over W01's UseClassTypeInfo table DAT_006c54ac),
                DemandGender = gender[1]·2 + gender[0], NextStartMode, NextStartDelayMin, RepeatMode, RepeatCount,
                RewardIndex (low 16 bits), DemandMobKill, MapLink[4] empty, ScriptLanguage, ScriptInitValue,
                from the KQTeam row if any: IsTeamPVP, TeamRegenXY[2] (else 0)          # names: PROTO_KQ_INFO (pdb2017)
                count < 300 → KQInfo_Copy into kq[count++] (the handle-exists branch never triggers: new handle);
                else log only
        # result: each row always has its next two start times listed; NextStartMode, RepeatMode and RepeatCount are
        # copied but never read by the WM (inferred: zone or unused)
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
    KQ_TickPurge         @ FUN_00454080 (read from the disassembly; Ghidra drops the flag store at 0x454100):
        marked = 0
        for each KQ i with Status 5…10: if some KQ with the same ID and Status 5…10 starts later → Status 0x0B; marked = 1
        if marked:                                         # only then; see W04-B55
            for each KQ with Status 0x0B (index not advanced after a removal):
                KQ_FreeMapSlots FUN_00452040; KQ_ClearJoinersKQ FUN_004526e0 (joiners' joinedKQ = −1)
                KQ_Remove FUN_00451ab0: FUN_0045ce20 removes kq[i] (count −1, entries shifted down), then the
                    joinerCount, joiner and red/blue arrays are shifted the same way
        # Status-0x0B entries made elsewhere (OPTool 0x2811, a late 0x580E) do not set `marked`: they stay in the
        # array and count toward the 300 limit until some other KQ is purged; after 0x2811 the KQ also keeps its map
        # slots and its joiners keep joinedKQ, and no 0x5811 reaches the zones (original bug) W04-B55
    KQ_RefreshOneClient  @ FUN_00455dd0: among sessions with wantsListRefresh == 1 pick the one with the oldest
                         lastRefresh (< now); lastRefresh = now; KQ_SendListDiff (§6.3)    # one client per second
    KQ_TickVote          @ FUN_00454f60 (§6.5)

CKQServer::SetDoneSkip(i, reason)                                                      @ FUN_004548c0
    Status 6; log "DEBUG - CKQServer::SetDoneSkip, HANDLE=%d"
    broadcast zones 0x5811 NC_KQ_W2Z_DESTROY_CMD { u32 hquest } (FUN_00452880); free its map slots (FUN_00452040)
    reason 2: notice WM text #2 (Title, NumOfJoiner, MinPlayers) to the joiners
    reason 3: notices WM text #3 and #4 to the joiners  # both empty in 2016 (table has 3 rows) (original bug) W04-B58
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
    # client (minimap = frame +0x234):
    #   0x5824 `ON_NC_KQ_JOINING_ALARM_CMD` FUN_004b6050: only if MiniMapWin::ConfirmKQAlarmInfo(Handle) accepts it;
    #     eligible = MinLevel ≤ own level ≤ MaxLevel; eligible → opens play-guide window 0xA9 and shows Msg (cut at
    #     MsgLength) as an announcement; adds the alarm { Handle, ID, eligible } to the minimap either way
    #   0x5825 `ON_NC_KQ_JOINING_ALARM_END_CMD` FUN_0049bb70: removes the alarm by Handle (and clears the minimap's
    #     KQ flag when it is the KQ open in the KQ window)
    #   0x5826 `ON_NC_KQ_JOINING_ALARM_LIST` FUN_0049bbf0: resets the minimap alarms and adds every entry with the same
    #     level test (no announcement)
    WM texts: `WM_GetMsg(n)` FUN_00404570 = row n of `MsgWorldManager.shn` (WM +0xC40C0, column Desc; loaded first by
    W01's FUN_00404100, fatal if missing); n ≥ row count → "" (PTR_DAT_00497038). 2016 rows:
        #0 "Recruitment for Kingdom Quest - '%s' has begun."
        #1 "Kingdom Quest - %s will begin in  %d seconds."
        #2 "Kingdom Quest - %s has been canceled due to lack of participants(%d/%d)."
        #3, #4 missing → empty text
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
    # client `KingdomQuestWin::SetKQuestStatus` FUN_005ef680: stores Handle (+0), NumOfJoiner (+5) and the n names
    # (+7, 20 bytes each) in the KQ window and redraws it; it never reads Status (+4), so "10 = no such KQ" only shows
    # as an empty joiner list

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
    # client (GameFrameWork, KQ window = frame +0x2F0):
    #   0x581C `On_NC_KQ_LIST_TIME_ACK` FUN_0049add0: SetServerTime on the KQ window (if open) and on mhRepairObjWin
    #   0x581D `On_NC_KQ_LIST_ADD_ACK` FUN_0049ae00: KingdomQuestWin::AddKQuest(packet)
    #   0x581E `On_NC_KQ_LIST_DELETE_ACK` FUN_0049ae20: DeleteKQuestInfo(Handle[i]) for each, then UpdateAllList
    #   0x581F `On_NC_KQ_LIST_UPDATE_ACK` FUN_0049ae70: KingdomQuestWin::UpdateListState(packet)
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
    # client `On_NC_KQ_VOTE_VOTING_CMD` FUN_004a6390: fills VoteWin with proposer sStarter, target sTarget, reason type
    # nVoteType (+0x28), end time tEndTime (+0x29, mktime), reason text sContents (+0x4E, nLen bytes) and shows the
    # ballot window; the player's choice goes back as 0x582A

0x582A NC_KQ_VOTE_VOTING_REQ { u32 eVoteType (KQ_VOTING_TYPE: 0 cancel, 1 yes, 2 no) }  @ FUN_00418630 → FUN_00452ee0
    reply 0x582B NC_KQ_VOTE_VOTING_ACK { u16 nError }
    s has no CHARDATA (+0x560) or is not in game (+0x704 == 0): return, no reply
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
    # client: the client loads its own KQVoteMajorityRate.shn (FUN_004695e0 → DAT_00a81200; 2016 rows {70, 50}, same
    # as the server's) and looks up the row whose rate equals nVoteRate (by value, not by index):
    #   0x582C `On_NC_KQ_VOTE_RESULT_SUC_CMD` FUN_004b7000: nothing when sTarget is the own character (it gets 0x582F);
    #     row 0 → announcement + system text TextData3 0x2477878c "%s has been banned according to voting result of For
    #     (%d votes), Against (%d votes), Void (%d votes). More than 70%% of participants have decided in favor of it.";
    #     later rows → 0x2119557b "%s has been the subject of voting more than twice. More than half the participants
    #     voted for the player being banned." + 0x26195f84 "Voting result: For (%d votes), Against (%d votes), Void (%d
    #     votes)"; no matching row (e.g. need 0 because the server table is empty) → nothing shown
    #   0x582D `On_NC_KQ_VOTE_RESULT_FAIL_CMD` FUN_004b7250: announcement (not for the target) + system text 0x25292a38
    #     "Voting result for %s: … Voting has been cancelled because not enough players participated."
    #     (original bug) W04-B68: the WM sends 0x582D for every failed vote, also when enough players voted and the
    #     majority was against; the client always says "not enough players participated"
    #   0x582F `On_NC_KQ_VOTE_BAN_MSG_CMD` FUN_004b4300: row 0 → TextData2 0x90a79cda "Voting result: For (%d votes),
    #     Against (%d votes), Void (%d votes). More than 70%% of participants voted "For." You will therefore be banned
    #     from the current Kingdom Quest!"; later rows → 0x19484a1d "You have already been the cause for voting by the
    #     participants of the Kingdom Quest more than twice. More than half the participants voted for you being banned."

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
    # client `On_NC_KQ_TEAM_SELECT_CMD` FUN_0049d950: KingdomQuestTeamList::SetElement(sCharID, nTeamType) + UpdateList
    # on the KQ window's team list (window +0x1C3F8)

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

## 8. Character options (dept 28 CHAR_OPTION)

The WM is a pure relay between the client and the Character server (DB side: D04 §5). Two generations exist
(`CHAR_OPTION_DATA_TYPE` *(pdb2017)*: 0 `CODT_NO_RECV`, 1 `CODT_BINARY_DATA` (old blobs), 2 `CODT_IMPROVE_DATA` (rows)).
All client handlers below start with `Client_CheckAlive` and need CHARDATA (+0x560); they send nothing back themselves.
The CharDB requests use the raw long frame `{0x00, u16 len, u16 opcode, payload}` (old) or `CSendPacket` (improved).

### 8.1 Session cache and the login push

| Session field | Name (from the log strings of FUN_00431680) | Filled by | Notes |
|---|---|---|---|
| +0x670 … +0x6A4 (7 ptr/size pairs) | `m_pCharOptionDataBinary_{ShortCutData, ShortCutSize, Video, Sound, Game, WindowPos, KeyMapping}` | **nothing** in 2016 (only zeroed by `FUN_00430600` and freed by `FUN_00434530`) | the old blobs reach the client directly through §8.3 |
| +0x6A8 / +0x6AC | `m_pCharOptionDataImprove_ShortCutData` = `{u16 n, SHORT_CUT_DATA[n] (7)}` | CharDB 0x702D | |
| +0x6B0 / +0x6B4 | `m_pCharOptionDataImprove_KeyMap` = `{u16 n, KEY_MAP_DATA[n] (4)}` | CharDB 0x702E, 0x7058 | |
| +0x6B8 / +0x6BC | `m_pCharOptionDataImprove_GameOption` = `{u16 n, GAME_OPTION_DATA[n] (3)}` | CharDB 0x702F; **freed** by 0x705A | |
| +0x1ECD8 | data type (`CHAR_OPTION_DATA_TYPE`) | CharDB 0x702C | |
| +0x1ECDC | "push pending" | set to 1 by CharDB 0x1005 (W01 §4) | |

```pseudo
CharDB 0x702C NC_CHAR_OPTION_IMPROVE_DB_GET_DATA_TYPE_CMD { u32 nCharNo, u32 DataType }          @ FUN_0040acb0
    s = Clients_FindByCharNo(nCharNo); s: s.+0x1ECD8 = DataType
CharDB 0x702D …_IMPROVE_DB_GET_SHORTCUTDATA_CMD { u32 nCharNo, u16 n, SHORT_CUT_DATA[n] }        @ FUN_0040ad00
CharDB 0x702E …_IMPROVE_DB_GET_KEYMAP_CMD       { u32 nCharNo, u16 n, KEY_MAP_DATA[n] }          @ FUN_0040ad70
CharDB 0x702F …_IMPROVE_DB_GET_GAMEOPTION_CMD   { u32 nCharNo, u16 n, GAME_OPTION_DATA[n] }      @ FUN_0040add0
    s = Clients_FindByCharNo(nCharNo); s: Session_StoreBlob(payload+4, 2 + n·size) into +0x6A8 / +0x6B0 / +0x6B8
    # no answer; these arrive during the character load, before 0x1005 (D02 §4 step 20)

CWMClientSession::SendToClient_CharOptionData(s)                                                 @ FUN_00431680
    # called once, from CharDB 0x1005 NC_CHAR_CHARDATA_ACK (FUN_00410040, W01 §4) right after it sets +0x1ECDC = 1
    if s.+0x1ECDC == 0: return;  s.+0x1ECDC = 0
    type 2 (improved), each only if its blob is set and size ≥ 1:
        Send s 0x7032 NC_CHAR_OPTION_IMPROVE_GET_SHORTCUTDATA_CMD = blob +0x6A8   (len = 2 + 7·(low byte of n))
        Send s 0x7033 NC_CHAR_OPTION_IMPROVE_GET_KEYMAP_CMD       = blob +0x6B0   (len = 2 + 4·(low byte of n))
        Send s 0x7034 NC_CHAR_OPTION_IMPROVE_GET_GAMEOPTION_CMD   = blob +0x6B8   (len = 2 + 3·(low byte of n))
        # a send failure logs "ERROR - CWMClientSession::SendToClient_CharOptionData, m_pCharOptionDataImprove_<x>,
        # nCharNo=%d" and stops. The length uses only the count's low byte (the PDB count is u16); the DB limits keep
        # the counts below 256 in practice (key map ≤ 95)
    type 1 (binary): would send 0x7003 / 0x7005 / 0x7007 / 0x7009 / 0x700B / 0x700D / 0x700F from +0x670…+0x6A4,
        but those slots are never filled in 2016: dead path. Type 0: nothing.
```

Client (game scene): 0x7032 resets the shortcut bar and adds each entry, 0x7033 loads the key map (and from then on
ignores 0x700F), 0x7034 loads the game options (C01 §client table). The cache is not updated by the SET requests below
and is read only by this push, so after login it is dead weight until logout frees it.

### 8.2 Client requests

```pseudo
0x7001 NC_CHAR_OPTION_GET_ALL_REQ                     @ LAB_00413fd0   no-op (not a function; the parser returns)
0x7002 NC_CHAR_OPTION_GET_SHORTCUTDATA_REQ            @ FUN_00413fe0   no-op (empty function)

0x7004 / 0x7006 / 0x7008 / 0x700A / 0x700C / 0x700E NC_CHAR_OPTION_GET_<kind>_REQ {}
        @ FUN_00414000 / FUN_00414080 / FUN_00414100 / FUN_00414180 / FUN_00414200 / FUN_00414280
    Send CharDB raw { 0x00, u16 8, u16 op, PROTO_NC_CHAR_OPTION_DB_GET_<kind>_REQ { u16 WorldManagerHandle = s.+0x114,
        u32 nCharNo } }                                                                          (11 bytes)
        op: SHORTCUTSIZE 0x7019, VIDEO 0x701B, SOUND 0x701D, GAME 0x701F, WINDOWPOS 0x7021, KEYMAPPING 0x7023
    # the client sends 0x7004 and 0x700C after NC_MAP_LOGIN_ACK (C01). There is no WM route to 0x7017
    # (short-cut data): 0x7002 is a no-op, so the 0x400-byte blob only reaches the client in the character load

0x7010 / 0x7011 / 0x7012 / 0x7013 / 0x7014 / 0x7015 / 0x7016 NC_CHAR_OPTION_SET_<kind>_CMD { u8 Data[size] }
        @ FUN_00414300 / FUN_004143a0 / FUN_00414440 / FUN_004144d0 / FUN_00414550 / FUN_004145e0 / FUN_00414680
    Send CharDB raw { 0x00, u16 4 + size + 2, u16 op, { u32 nCharNo, u8 Data[size] } }  # no answer (D04 §5.1)
        SHORTCUTDATA 0x7025 (0x400), SHORTCUTSIZE 0x7026 (0x18), VIDEO 0x7027 (0x3C), SOUND 0x7028 (1),
        GAME 0x7029 (0x40), WINDOWPOS 0x702A (0x188), KEYMAPPING 0x702B (0x134)
    # fixed-size copies; the packet length is not checked (a short packet sends receive-buffer bytes)

0x7037 NC_CHAR_OPTION_IMPROVE_SET_SHORTCUTDATA_REQ { u8 nShortCutDataCnt, SHORT_CUT_DATA[n] { u8 nSlotNo,
        u16 nCodeNo, i32 nValue } }                                                              @ FUN_00414720
    Send CharDB 0x704B { u32 nCharNo, u8 n, SHORT_CUT_DATA[n] }   (5 + 7n; n ≤ 255 fits the 8 KB packet)
0x7039 NC_CHAR_OPTION_IMPROVE_SET_KEYMAP_REQ { u16 nKeyMapDataCnt, KEY_MAP_DATA[n] { u16 nFunctionNo, u8 nExtendKey,
        u8 nASCIICode } }                                                                        @ FUN_004148f0
    n ≥ 0x60: log "ERROR - CParserClient::fc_NC_CHAR_OPTION_IMPROVE_SET_KEYMAP_REQ : nKeyMapDataCnt(%d)", drop
    else Send CharDB 0x704D { u32 nCharNo, u16 n, KEY_MAP_DATA[n] }   (6 + 4n)
0x703B NC_CHAR_OPTION_IMPROVE_SET_GAMEOPTION_REQ { u16 nGameOptionDataCnt, GAME_OPTION_DATA[n] { u16 nOptionNo,
        u8 nValue } }                                                                            @ FUN_00414af0
    Send CharDB 0x704F { u32 nCharNo, u16 n, GAME_OPTION_DATA[n] }   (6 + 3n)
    # (original bug) W04-B22: n is not checked: n·3 bytes (up to 196 605) are copied into the 8 KB stack packet
    # before Pkt_SetOpcode checks the size; n above ≈ 2730 smashes the WM stack (any logged-in player)
0x7043 NC_CHAR_OPTION_IMPROVE_INIT_KEYMAP_REQ {}       → Send CharDB 0x7057 { u32 nCharNo }      @ FUN_00414820
0x7045 NC_CHAR_OPTION_IMPROVE_INIT_GAMEOPTION_REQ {}   → Send CharDB 0x7059 { u32 nCharNo }      @ FUN_00414a20
0x705F NC_CHAR_OPTION_LOGIN_BLOCKDATA_ERR {}           → Send CharDB 0x7060 NC_CHAR_OPTION_LOGIN_BLOCKDATA_ERR_REQ
        { u32 nCharNo } (pdb2017 name)                                                           @ FUN_00414bf0
    # (original bug) W04-B23: the 2016 Character server registers no handler for 0x7060: the client's report that
    # its stored option blocks are broken has no effect
```

### 8.3 CharDB answers

```pseudo
CharDB 0x7018 / 0x701A / 0x701C / 0x701E / 0x7020 / 0x7022 / 0x7024 NC_CHAR_OPTION_DB_GET_<kind>_ACK
        { u16 WorldManagerHandle, u8 bSuccess, u8 Data[size] }
        @ FUN_0040b390 / FUN_0040b440 / FUN_0040b4f0 / FUN_0040b580 / FUN_0040b610 / FUN_0040b6a0 / FUN_0040b750
    s = Clients_GetByHandle(WorldManagerHandle); none: drop
    Send s raw { 0x00, u16 1 + size + 2, u16 opcode − 0x15 (0x7003 / 0x7005 / 0x7007 / 0x7009 / 0x700B / 0x700D / 0x700F),
        PROTO_NC_CHAR_OPTION_GET_<kind>_ACK { u8 bSuccess, u8 Data[size] } }
    # bSuccess and Data are copied as received; with bSuccess 0 Data is the Character server's stale stack (D04-B12)
    # These come both from the client's GET requests (§8.2) and unasked from the character load (old format:
    # 0x7018, 0x701A, 0x7020, 0x7022, 0x7024; D02 §4 step 20). The client handles 0x7003…0x700F in the
    # character-select scene (C01): present + matching 6-byte header → load, else defaults; 0x7007 / 0x7009 ignored

CharDB 0x704C / 0x704E / 0x7050 NC_CHAR_OPTION_IMPROVE_DB_SET_<x>_ACK { u16 nError, u32 nCharNo }
        @ FUN_0040ae30 / FUN_0040af00 / FUN_0040afd0
    s = Clients_FindByCharNo(nCharNo); none: drop
    Send s 0x7038 / 0x703A / 0x703C NC_CHAR_OPTION_IMPROVE_SET_<x>_ACK { u16 nError }
        # 0x2100 / 0x2108 / 0x2118 ok, 0x2101 / 0x2109 / 0x2119 a row failed (D04 §5.2)
    # 0x704E / 0x7050 carry an unwritten nCharNo (D04-B13), so 0x703A / 0x703C normally reach nobody.
    # The 2016 client has no handler for 0x7038 / 0x703A (C01: ignored, not missing) and accepts 0x703C without action

CharDB 0x7058 NC_CHAR_OPTION_IMPROVE_DB_INIT_KEYMAP_ACK { u16 nError, u32 nCharNo, u16 n, KEY_MAP_DATA[n] }   @ FUN_0040b0a0
    s = Clients_FindByCharNo(nCharNo); none: drop
    n ≥ 0x60: log "ERROR - CParserCharDB::fc_NC_CHAR_OPTION_IMPROVE_DB_INIT_KEYMAP_ACK : nCharNo(%d), nKeyMapDataCnt(%d)";
        no answer (unreachable: the DB caps n at 95)
    Session_StoreBlob({n, data}) into +0x6B0
    Send s 0x7044 NC_CHAR_OPTION_IMPROVE_INIT_KEYMAP_ACK { u16 nError, u16 n, KEY_MAP_DATA[n] }   (4 + 4n)
        # entries copied field by field only when nError == 0x2110 (the DB sends n = 0 with 0x2111)
    # client (FUN_0049ca00): 0x2110 → writes each key into the key-remapping window and refreshes it; else ignored

CharDB 0x705A NC_CHAR_OPTION_IMPROVE_DB_INIT_GAMEOPTION_ACK { u16 nError, u32 nCharNo, u16 n, GAME_OPTION_DATA[n] }  @ FUN_0040b250
    s = Clients_FindByCharNo(nCharNo); none: drop
    free blob +0x6B8 (FUN_00430750: free, ptr = size = 0)     # unlike 0x7058 the new data is not cached (harmless, §8.1)
    Send s 0x7046 NC_CHAR_OPTION_IMPROVE_INIT_GAMEOPTION_ACK { u16 nError, u16 n, GAME_OPTION_DATA[n] }   (4 + 3n)
    # client (FUN_004a5980): 0x2120 → MachineOpt::SetGameOpt(n, data) and refreshes the option window
```

No CharDB failure answer exists for 0x7057 / 0x7059 when the read-back fails (D04-B14): the client then waits forever.

---

## 9. Prison (dept 31)

### 9.1 `CPrisonServer` (the WM's release timer)

`CPrisonServer` (class name from its RTTI vftable) is a lazily built singleton (`CPrisonServer_Instance` FUN_004589b0,
init FUN_004588d0, `g_PrisonServer` DAT_006d4ce4 → DAT_006d4cf0, destructor FUN_00458850). It holds one
`std::map<session*, i64 remainingMs>` (tree at +4; node +0x10 key, +0x18 i64 remaining; internals FUN_00458130 find,
FUN_00458050 / FUN_004581f0 insert, FUN_00457dc0 erase, FUN_004585d0 erase range, FUN_00457b00 equal range, FUN_004581a0
clear; MSVC `std::_Tree` helpers below them: FUN_00457b90 insert-rebalance, FUN_00457990 / FUN_004579e0 iterator
increment / decrement, FUN_00457a40 / FUN_00457aa0 rotations; `atexit` destructor FUN_00482990). Only online prisoners whose client asked 0x7C06 (§9.2) are in it; CHARDATA.prisonmin (+0x62) is the minute count
the rest of the WM tests.

```pseudo
CPrisonServer_Add(s, minutes) → inserted                                                       @ FUN_00458670
    s and CHARDATA set: insert { s, minutes·60000 + 30000 }      # 30 s grace; an existing entry is kept (returns false)
CPrisonServer_Update(s, minutes) → bool                                                        @ FUN_004584e0
    in map: remaining = minutes·60000 + 30000; return 1
    else (not a timed prisoner): CHARDATA.prisonmin = 0
        Send CharDB raw 0x7C0D NC_DATA_PRISON_UPDATE_MIN_CMD { u32 nImprisonRegNum = charNo, u16 nMinute 0 }
        Send s's zone raw 0x7C12 NC_ZONE_PRISON_END_CMD { u16 nCharZoneHandle = s.+0x118, u32 nCharRegNum }
        return 0
CPrisonServer_Release(s)                                                                       @ FUN_00458270
    in map:
        Send s raw 0x7C05 NC_PRISON_END_ACK { u16 err 0x0DA8, u32 nPrisonSecond 0 }   # opcode/code read in the asm
        Send s's zone 0x7C12 { zoneHandle, charNo }          # zone: so_Prison_End (Z08 §12)
        CHARDATA.prisonmin = 0
        Send CharDB 0x7C0D { charNo, 0 }                     # DB: nPrisonMin 0, login position Rou (D04 §7)
        erase
CPrisonServer_Remove(s)                                                                        @ FUN_004586e0
    CHARDATA.prisonmin = 0;  in map: Send s's zone 0x7C12 { zoneHandle, charNo }; erase     # no DB write, no client msg
CPrisonServer_IsPrisoner(s, charNo) = in map and s.CHARDATA.charNo == charNo                    @ FUN_00458490
CPrisonServer_EndRequest(s) → i64                                                              @ FUN_00458430
    not in map → −1;  remaining ≤ 30000 → Release(s), 0;  else remaining (ms)
CPrisonServer_SaveOnLogout(s)            # from CharacterLogout (W01 §5.4, FUN_00436d50)       @ FUN_00458790
    in map: Send CharDB 0x7C0D { charNo, ceil(remaining / 60000) }; erase
    # W01 §5.4 calls this "remove from a name registry (inferred)"; it is the prison-minute save

CPrisonServer_Tick()          # every main-loop pass (W01 main tick FUN_00406760)              @ FUN_00458360
    now = timeGetTime(); now < next: return
    next = now + 2000; elapsed = now − last; last = now
    for each entry: remaining −= elapsed
        remaining ≤ 0: Release(s)
        else Prison_UpdateMinutes(s, remaining)                                                @ FUN_004578a0
            m = ceil(remaining / 60000)
            m < CHARDATA.prisonmin: CHARDATA.prisonmin = m; m % 3 == 0 → Send CharDB 0x7C0D { charNo, m }
            # so the DB copy is refreshed every 3 minutes; a crash loses at most 3 minutes of served time
```

### 9.2 Client requests (CParserClient)

The GM forms send `{ Name5 sImprison @0, u16 nMinute @0x14, char sReason[16] @0x16, char sRemark[64] @0x26 }` (0x66,
`PROTO_NC_PRISON_ADD_GM_REQ` / `_ALTER_GM_REQ`, offsets confirmed). Both answers are raw
`{0x18, u16 op, Name5 sImprison, u16 err}` (`PROTO_NC_PRISON_ADD_GM_ACK` / `_ALTER_GM_ACK`, 0x16).

```pseudo
0x7C01 NC_PRISON_ADD_GM_REQ                                                                    @ FUN_0041de70
    CHARDATA.adminlevel (+0x64) == 0          → 0x7C02 err 0x0D85 "You do not have the authority to imprison."
    nMinute == 0 or nMinute > 32700 (0x7FBC)  → 0x0D83 "Invalid Imprisonment time."
    sImprison empty                           → 0x0D86 "Please enter the character ID."
    sReason empty                             → 0x0D84 "Enter the reason for imprisonment."
    # any non-zero admin level may imprison (0x2010 notices need 100). No check that the target is not a GM.
    t = Clients_FindByCharName(sImprison)
    t == null (offline / other world):
        Send CharDB 0x7C0B NC_DATA_PRISON_ADD_GM_REQ { u16 nGmHandler = s.+0x114, Name256Byte sGmUserID = s.userId (+0x128, Copy256 FUN_004097c0),
            u32 nImprisonRegNum 0 (= by name), sImprison, nMinute, sReason, sRemark }      (0x16C)   → §9.3
    t online and t.CHARDATA.prisonmin ≠ 0, or CPrisonServer_IsPrisoner(t, t.charNo):
        → 0x7C02 err 0x0D82 "The character is already in prison."
    else:
        Send t's zone (g_Zones[t.+0x117]) 0x7C13 NC_ZONE_PRISON_GO_REQ { u16 nGmHandler, u32 nGmRegNum = s.charNo,
            Name256Byte sGmUserID, Name5 sCharID = sImprison, u16 nCharSessHandle = t.+0x114,
            u16 nCharZoneHandle = t.+0x118, u32 nCharRegNum = t.charNo, u16 nMinute, sReason[16], sRemark[64] } (0x174)
        zone missing or send failed → 0x7C02 err 0x0D88 "Imprisonment request has failed. (linking or out of the zone)"
        # the zone links the player to "EldPri" and answers 0x7C14 (Z08 §12)

0x7C04 NC_PRISON_END_REQ {}                    # client: its prison timer ran out (inferred)   @ FUN_004155f0
    r = CPrisonServer_EndRequest(s)
    r == 0:  nothing more (Release already sent 0x7C05 0x0DA8 and freed the player)
    r == −1: Send raw 0x7C05 NC_PRISON_END_ACK { u16 err 0x0DAA, u32 nPrisonSecond 0xFFFFFFFF }   # not a prisoner
    else:    Send raw 0x7C05 { u16 err 0x0DA9, u32 nPrisonSecond = r }
    # (original bug) W04-B24: r is in milliseconds. The client (FUN_0049b1b0) passes the value to
    # PrisonTimeWin::ResetTime, which takes seconds (0x7C03 passes minutes·60; the zone sends minutes·60 in its own
    # 0x7C05 at map login, Z01). The window then shows 1000 × the remaining time. Client: 0x0DA8 / 0x0DAA → timer 0

0x7C06 NC_PRISON_GET_REQ {}          # the client sends it after NC_MAP_LOGIN_ACK (C01)          @ FUN_00415530
    no CHARDATA or CHARDATA.prisonmin == 0:
        Send raw 0x7C07 NC_PRISON_GET_ACK (short form) { u16 err 0x0DB1, u16 nMinute 0 }        (4)
    else: Send CharDB raw 0x7C0E NC_DATA_PRISON_GET_REQ { u16 nCharHandle = s.+0x114, u32 nCharRegNum = charNo }
        send failure: OutputDebugString "=SEND_TO_CHAR_DB(PROTO_NC_DATA_PRISON_GET_REQ) FAIL"

0x7C09 NC_PRISON_ALTER_GM_REQ                                                                  @ FUN_0041e290
    adminlevel == 0      → 0x7C0A err 0x0DA5 "You do not have the authority to make the change."
    nMinute > 32700      → 0x0DA3 "Incorrect imprisonment time."        # 0 is allowed: release
    sImprison empty      → 0x0DA6 "Please enter the character ID."
    sReason empty        → 0x0DA4 "Please enter the reason for changing the condition of imprisonment."
    t = Clients_FindByCharName(sImprison)
    t online and (no CHARDATA or prisonmin == 0) → 0x0DA2 "Not in prison."
    Send CharDB 0x7C10 NC_DATA_PRISON_ALTER_GM_REQ { nGmHandler, sGmUserID, nImprisonRegNum = t ? t.charNo : 0, sImprison,
        nMinute ?, sReason ?, sRemark ? }                                                          (0x16C)  → §9.3
    # (original bug) W04-B25: nMinute, sReason and sRemark are never copied into 0x7C10 (checked in the asm: the
    # stores end at sImprison, packet +0x11A… is stale stack). The DB stores a random minute count and history text,
    # and the echo in 0x7C11 applies that count to the online prisoner
```

### 9.3 Zone and CharDB answers

```pseudo
Zone 0x7C14 NC_ZONE_PRISON_GO_ACK { the 0x7C13 fields, u16 err @0x174 }   (0x176)   (CParserZone)  @ FUN_0042dea0
    # W01's scope lists this handler (W01 part 5) and hands it to W04. Zone err (Z08 code FUN_005a4470): 0x0DC0 ok,
    # 0x0DC1 charNo mismatch at the handle, 0x0DC2 so_Prison_Go failed; no answer if the handle is unknown
    err == 0x0DC0:
        t = Clients_GetByHandle(nCharSessHandle)
        t and t.charNo == nCharRegNum and not CPrisonServer_Add(t, nMinute) (already timed)
            and GM g = Clients_GetByHandle(nGmHandler) with g.charNo == nGmRegNum:
                Send g raw 0x7C02 { sCharID, err 0x0D82 }; return
        Send CharDB 0x7C0B { nGmHandler, sGmUserID, nImprisonRegNum = nCharRegNum, sCharID, nMinute, sReason, sRemark }
        # sent also when t is gone; the timer then starts at the next 0x7C06
    else: g (handle + charNo check) → Send g raw 0x7C02 { sCharID, err 0x0D88 }
        # the player may already be in EldPri (err 0x0DC1 / 0x0DC2 do not undo the zone side)

CharDB 0x7C0C NC_DATA_PRISON_ADD_GM_ACK { u16 err, u16 nGmHandler, u32 nImprisonRegNum, Name5 sImprison, u16 nMinute,
        sReason, sRemark }   (0x6E, D04 §7)                                                       @ FUN_00410a50
    err == 0x0D80 and nImprisonRegNum ≠ 0 and t = Clients_FindByCharNo(nImprisonRegNum):
        t.CHARDATA.prisonmin = nMinute
        kq = t.+0x258C; KQ_LeaveJoinList(t) → Send t raw 0x5808 NC_KQ_JOIN_CANCEL_ACK { u16 0x09A1, u32 kq } (§6.4)
    err ≠ 0x0D80 and nImprisonRegNum ≠ 0 and t online: CPrisonServer_Remove(t)   # zone 0x7C12 if timed; prisonmin = 0
    g = Clients_GetByHandle(nGmHandler) → Send g raw 0x7C02 NC_PRISON_ADD_GM_ACK { sImprison, err }
    # client: 0x0D80 silent, 0x0D81 "Character ID does not exist.", 0x0D82 "…already in prison.", 0x0D87
    # "Imprisonment request has failed." Neither 0x7C0C nor 0x7C14 tells the prisoner: the client learns it from
    # the zone's 0x7C05 at the EldPri map login (Z01) and its own 0x7C06
    # The handle is not checked against the GM's charNo (unlike 0x7C14): if the GM left, another session that got
    # the same handle receives the answer (inferred, harmless)

CharDB 0x7C0F NC_DATA_PRISON_GET_ACK { u16 nCharHandle, u16 err, char sReason[16], char sRemark[64] }  @ FUN_0040c350
    s = Clients_GetByHandle(nCharHandle); none: drop
    err == 0x0DB0: CPrisonServer_Add(s, CHARDATA.prisonmin)          # starts the release timer
    Send s raw 0x7C07 NC_PRISON_GET_ACK { u16 err, u16 nMinute = CHARDATA.prisonmin, char sReason[16], char sRemark[64] } (0x54)
    send failure: OutputDebugString "NC_PRISON_ADD_GM_ACK Send Fail"   # the C01 catalog name came from this string
    # (original bug) W04-B26: err 0x0DB2 (DB read failed) does not start the timer although prisonmin ≠ 0; the
    # prisoner is never released by the WM in this session (0x7C04 then answers 0x0DAA)

CharDB 0x7C11 NC_DATA_PRISON_ALTER_GM_ACK { same layout as 0x7C0C }                              @ FUN_00410b90
    g = Clients_GetByHandle(nGmHandler)
    err == 0x0DA0 and nImprisonRegNum ≠ 0 and t = Clients_FindByCharNo(nImprisonRegNum):
        t.CHARDATA.prisonmin = nMinute
        nMinute == 0: CPrisonServer_Release(t)          # 0x7C05 0x0DA8, zone 0x7C12, DB 0x7C0D 0
        else if not CPrisonServer_Update(t, nMinute) and g: # t online but not timed: Update released it
            Send g raw 0x7C0A { sImprison, err 0x0DA2 "Not in prison." }; return   # no 0x7C03
        Send t raw 0x7C03 NC_PRISON_OK_CMD { u16 nMinute, char sReason[16], char sRemark[64] }       (0x52)
    g: Send g raw 0x7C0A NC_PRISON_ALTER_GM_ACK { sImprison, err }
    # 0x7C03 client (FUN_004aec50): "Remaining Time: %d minutes The charge: %s Details: %s", timer = nMinute·60 s;
    # nMinute ≠ 0: in a party → sends 0x380A NC_PARTY_LEAVE_REQ *(pdb2017 name)* {} (2 bytes; 2016 WM handler CParserClient FUN_0041b990, W02), else system text "Not part of a Party."
    # 0x7C0A client (FUN_004aee00): 0x0DA1 "Character ID does not exist.", 0x0DA2 "Not in prison.", 0x0DA3–0x0DA6 above;
    # (original bug) W04-B27: the DB failure code is 0x0DA7, but the client's alter switch maps 0x0D87 (the add code)
    # to "Imprisonment request has failed." and shows nothing for 0x0DA7
```

**0x7C07 (C01 open item).** Official name `NC_PRISON_GET_ACK` *(pdb2017)*; the 2016 string `PROTO_NC_DATA_PRISON_GET_REQ`
at the 0x7C06 send site and the 0x7C06 → 0x7C0E → 0x7C0F → 0x7C07 chain support the GET name; `NC_PRISON_ADD_GM_ACK`
was a copy-pasted debug string. Layout `{ u16 err, u16 nMinute, char sReason[16], char sRemark[64] }` (0x54), or the
4-byte short form `{0x0DB1, 0}` when the player is not in prison. Meaning: the prison state at map login. The client
handles it only in the character-select scene (FUN_00475fb0: err 0x0DB0 → keeps nMinute and sets a flag; reason and
remark are ignored); the game scene has no handler.

---

## 10. Player reports (dept 32 REPORT)

The WM forwards to the AccountLog DB server (D01; codes from D01 knowledge). Raw headers throughout.

```pseudo
0x8001 NC_REPORT_ADD_REQ { Name5 sHarmer, u8 byReportType[16] @0x14, u8 byReason[256] @0x24, u16 nChatLogSize @0x124,
        u8 byChatLog[nChatLogSize] @0x126 }                                                     @ FUN_0041db50
    no CHARDATA: drop
    reply(err) = Send raw 0x8002 NC_REPORT_ADD_ACK { Name5 sHarmer, u32 nRegNumber 0, u16 err }   (0x1A)
    CHARDATA.prisonmin ≠ 0          → reply 0x0F48 (no client text)
    sHarmer empty                   → 0x0F44 "Please enter the character ID."
    Name5_Equal(sHarmer, own name)  → 0x0F43 "Cannot report oneself."
    byReportType empty (strlen)     → 0x0F47 (no client text)
    byReason empty                  → 0x0F45 "Please enter the reason for reporting."
    last = s.+0x1DFA8 (tick of the last successful report)
    last ≠ 0 and GetTickCount() − last > 3 600 000 → 0x0F42 "Reporting is restricted to once an hour."
    # (original bug) W04-B28: the test is inverted (asm: `jbe` to the send path): reports within the hour after a
    # success are forwarded, every report later than one hour is refused until the next login. The AccountLog server
    # does its own once-an-hour / once-a-day checks (0x0F42 / 0x0F41), which keep the intended limit
    Send AccountLog raw long frame { 0x00, u16 0x143 + n, u16 0x8007, PROTO_NC_DATA_REPORT_ADD_REQ {
        u32 dwReporter = charNo, u16 hReporter = s.+0x114, u8 nWorldNo = g_WorldNo, Name5 sReporterCharID = CHARDATA+4,
        Name5 sHarmer, byReportType[16], byReason[256], u16 nChatLogSize, byChatLog[n] } }
    # (original bug) W04-B29: nChatLogSize is not checked against 2048 or the packet length; up to 65 535 bytes are
    # copied into a ~2.3 KB stack buffer: any player can crash the WM

0x8003 NC_REPORT_CANCEL_REQ { u32 nRegNumber }                                                  @ FUN_004153e0
    reply(err) = Send raw 0x8004 NC_REPORT_CANCEL_ACK { u32 nRegNumber, u16 err }
    CHARDATA and prisonmin ≠ 0 → reply 0x0F53;  nRegNumber == 0 → reply 0x0F50 (unknown report)
    else Send AccountLog raw 0x8009 NC_DATA_REPORT_CANCEL_REQ { i32 nRegNumber, u16 hReporter = s.+0x114 }
0x8005 NC_REPORT_GET_REQ {}                                                                     @ FUN_004154c0
    CHARDATA set: Send AccountLog raw 0x800B NC_DATA_REPORT_GET_REQ { u16 hReporter, u32 dwReporter = charNo, u8 nWorldNo }

AccountLog 0x8008 NC_DATA_REPORT_ADD_ACK { u16 err, u16 hReporter, Name5 sHarmer, i32 nRegNumber }  @ FUN_004092e0
    s = Clients_GetByHandle(hReporter): Send s 0x8002 { sHarmer, nRegNumber, err }
        err == 0x0F40: s.+0x1DFA8 = GetTickCount()
AccountLog 0x800A NC_DATA_REPORT_CANCEL_ACK { i32 nRegNumber, u16 hReporter, u16 err }           @ FUN_004090c0
    s = Clients_GetByHandle(hReporter): Send s 0x8004 { nRegNumber, err }
AccountLog 0x800C NC_DATA_REPORT_GET_ACK { u16 hReporter, u16 err, i32 nRegNumber, u8 byReportResult, u8 byRemark[128] }
                                                                                                 @ FUN_00409130
    s = Clients_GetByHandle(hReporter): Send s 0x8006 NC_REPORT_GET_ACK { u16 err, u32 nRegNumber, u8 byReportResult,
        u8 byRemark[128] }   (0x87)
```

Client: 0x8002 (FUN_004ae700) 0x0F40 → report window gets nRegNumber; texts for 0x0F41 "Reporting same character is
resticted to once a day.", 0x0F42, 0x0F43, 0x0F44, 0x0F45, 0x0F46 "There is no chatting log." (never sent by the WM),
0x0F58 "Failed to report. (DB Error)"; 0x0F47 and 0x0F48 show nothing (original bug) W04-B30. 0x8004 (FUN_004aea60):
0x0F40 "Completed cancelling the report.", anything else "Failed to cancel the report.". 0x8006 (FUN_004ae800): 0x0F40 →
status window (byReportResult 0 "Registering the report…" with a Cancel button, 1 "Reporting completed.", 2 "Hold the
report."), 0x0F60 (none) → empty form ("Send", "Abuser:"), 0x0F58 "Failed to register the report.".

---

## 11. Charged (premium) buffs (dept 36, CParserZone)

The WM keeps the character's charged-buff list in session blob +0x650 = `{u16 n, PROTO_CHARGEDBUFF_INFO[n]}`
(14 bytes: u32 ChargedBuffKey, u16 ChargedBuffID, ShineDateTime UseTime, ShineDateTime EndTime), loaded from CharDB
0x101B and handed to every zone the character enters as 0x1032 NC_CHAR_ZONE_CHARGEDBUFF_CMD (W01 §6.3). The zone
(`ShinePlayer_so_ply_ChargedBuff` FUN_005970c0, `ciee_Free` FUN_00450a50) sends each change to both the Character
server (D03 §9: DB write + log) and the WM, so the copy stays current across zone changes.

```pseudo
Zone 0x9001 NC_CHARGED_SETBUFF_CMD { u32 CharRegistNumber, u64 ItemKey @4, u16 ItemId @0xC,
        PROTO_CHARGEDBUFF_INFO ChargedBuff @0xE, u32 nUserNo @0x1C }   (0x20)                      @ FUN_0042a5b0
    s = Clients_FindByCharNo(CharRegistNumber) with CHARDATA; none: return
    blob +0x650 set: new = malloc(size + 14); copy; append ChargedBuff; n += 1; free old; size += 14
    else: blob = { 1, ChargedBuff } (16 bytes)
    # no duplicate-key check (the zone refuses "This effect is already set" before sending)

Zone 0x9002 NC_CHARGED_RESETBUFF_CMD { u32 CharRegistNumber, u32 ChargedBuffKey, u16 ChargedBuffID, u32 nUserNo } (0xE)
                                                                                                 @ FUN_0042a6d0
    s = Clients_FindByCharNo(CharRegistNumber) with CHARDATA; none: return
    no blob: LogLevel(4, "FAILED - fc_NC_CHARGED_RESETBUFF_CMD1, 유료버퍼없는데 지우기요청옴, nCharNo=%d, nKey=%d")
        # Korean: "no paid buff, but a delete request came"
    i = first entry with ChargedBuffKey (ChargedBuffID is not compared)
    not found: LogLevel(4, "FAILED - fc_NC_CHARGED_RESETBUFF_CMD2, …")
    n == 1: free the blob (ptr = size = 0)
    else: new blob of size − 14 without entry i, n − 1
```

---

## 12. Holy promise (master / apprentice, dept 37)

The WM keeps each online character's relation in its session and relays everything else to the Character server
(`docs/pseudocode/db/D04-character-social.md` §8 has the procedures, tables and the DB codes). The client calls the
relation "Monarch" / master and apprentice; the zone side is Z08 §9 (cen reward, 0x9432 / 0x9435). Codes: 0x1740 ok,
0x1751 ok (re-join of an existing row, D04), the rest are client error-table texts (quoted below).

### 12.1 The relation object in the session (`HP` = session +0x1DFB0, all offsets *ours*)

| HP offset (session) | Field | Notes |
|---|---|---|
| +0x000 (+0x1DFB0) | `PROTO_HOLY_PROMISE_INFO` master (0x1A): Name5 PromiseCharID, DATE LogonInfo (+0x14, bit 0 = online), u8 Level (+0x18), u8 Flags (+0x19) | name "" = no master |
| +0x01C (+0x1DFCC) | i32 memberCount (≤ 20) | |
| +0x020 (+0x1DFD0) | `PROTO_HOLY_PROMISE_INFO` member[20] (0x1A each) | the apprentices |
| +0x228 (+0x1E1D8) | u32 listLoaded: 1 after 0x9429; the next map login sends the list and clears it | |
| +0x22C (+0x1E1DC) | u32 masterCharNo (−1 none, as loaded from the DB) | **not reset** by `HP_ClearMaster` (W04-B34) |
| +0x230 (+0x1E1E0) | u16 masterWmHandle (0xFFFF = offline) | |
| +0x232 / +0x236 / +0x23A (+0x1E1E2 / +0x1E1E6 / +0x1E1EA) | DATE RegDate / **RejoinableDate** / **MemberAcceptableDate** of this character's own row | both locks are local-time hours |
| +0x240 (+0x1E1F0) | u32 remainMoneyPending (set by 0x9444) | |
| +0x248 (+0x1E1F8) | u64 remainMoney (cen the master can still collect, D04 §8) | |
| +0x250 (+0x1E200) | u32 memberCharNo[20] | |
| +0x2A0 (+0x1E250) | u16 memberWmHandle[20] (0xFFFF offline) | |

A DATE is `PROTO_HOLY_PROMISE_DATE` `{login:1, year:11, month:4, day:5, hour:5}` *(pdb2017; bit use confirmed)*;
the WM converts it with `mktime` (year − 1900, month − 1, minutes/seconds 0) and builds new ones from `localtime`.

```pseudo
HP_HasMaster(hp) = master.PromiseCharID != ""                                       @ FUN_0045d0b0 (asm: returns 1 when non-empty)
HP_FindByCharNo(hp, charNo, &idx): masterCharNo == charNo → hp (idx −1); member i → &member[i] (idx i); else null   @ FUN_00451170
HP_FindByName(hp, name, &idx): same, by Name5 (master first)                      @ FUN_0045d150
HP_CheckCanAddMember(hp, charNo): 2 if charNo is hp's master or already a member; 1 if memberCount > 19; else 0   @ FUN_004511d0
HP_SetMaster(hp, INFO_DB info, charNo, handle): master = info (INFO part, HPInfo_Copy FUN_0045d2a0); masterCharNo,
    masterWmHandle; RegDate / RejoinableDate / MemberAcceptableDate = info's three dates          @ FUN_00451040
HP_ClearMaster(hp): master name = "", LogonInfo = now (login bit 0) (HPInfo_Clear FUN_0045d010); masterWmHandle = 0xFFFF
    # masterCharNo and the dates are kept (original bug) W04-B34                                  @ FUN_00451090
HP_AddOrUpdateMember(hp, INFO info, charNo, handle): count > 20 → 0; same name → overwrite entry, charNo, handle → 2;
    count > 19 → 0; else append → 1                                                              @ FUN_00451370
HP_RemoveMember(hp, name): remove by name, close the gap in all three arrays                       @ FUN_004510b0
HP_SetOffline(hp, name): the master or member with that name: LogonInfo = local time now, login bit 0
    (FUN_0045d1f0)                                                                                 @ FUN_0045d2e0
HP_SetLevel(hp, name, level): the master or member with that name gets Level = level              @ FUN_0045d380
HP_SendToMembers(hp, pkt): SendRaw to every member whose handle is an in-game session            @ FUN_00451220
Clients_GetInGameByHandle(h): slot with that handle, in use and session +0x704 inGame ≠ 0       @ FUN_00438180
```

The relation object is built and torn down with the session (W01): constructor FUN_0045d430 (20 member-name strings
of 0x1A bytes at +0x20, then `HPInfo_Clear`), destructor FUN_0045d470 / its thunk FUN_00450ff0, plain clear
FUN_0045d280, and FUN_0045d140 (an `HPInfo_Clear` thunk: name = "", LogonInfo = local time now).

### 12.2 Loading, presence, level change (not handlers)

The Character server pushes 0x9427, 0x9429 and 0x9444 while it loads the character (D02 §4 step 11); W01's map
login 0x180C and logout and level change call the functions below.

```pseudo
CharDB 0x9427 NC_HOLY_PROMISE_DB_GET_UP_ACK { u32 nCharNo, u16 DBError, INFO_DB UpMemberInfo @6 }  (0x30)   @ FUN_0040c8d0
    s = Clients_FindByCharNo(nCharNo) (any session; the character is still loading); none → return
    DBError != 0x1740: HP_ClearMaster(s.HP); return            # nothing logged
    m = Clients_FindInGameByCharNo(UpMemberInfo.PromiseCharNo); handle = 0xFFFF
    if m:  UpMemberInfo.LogonInfo |= 1 (online); handle = m.wmHandle
           e = HP_FindByCharNo(m.HP, s.charNo); if e: e.LogonInfo |= 1; HP_AddOrUpdateMember(m.HP, e, s.charNo, s.wmHandle)
    HP_SetMaster(s.HP, UpMemberInfo, UpMemberInfo.PromiseCharNo, handle)
    # no master: the DB wrapper sends PromiseCharNo −1 and an empty name (D04), so HasMaster is false

CharDB 0x9429 NC_HOLY_PROMISE_DB_GET_MEMBER_ACK { u32 nCharNo, u16 DBError, u8 nPart, u8 nMemberCount,
        INFO_DB MemberInfo[n] @8 }                                                                       @ FUN_0040c9c0
    s = Clients_FindByCharNo(nCharNo); none → return
    DBError != 0x1740: Log "ERROR - NC_HOLY_PROMISE_DB_GET_MEMBER_ACK, DB ERROR =%d, nCharNo=%d"; return
    HP_LoadMembers(s.HP, pkt)                                                                             @ FUN_00451490
        nPart bit 0 (first part): memberCount = 0 (FUN_0045d0a0)
        per entry: add or update by name (charNo = entry.PromiseCharNo, handle 0xFFFF); more than 20 → return 0
    ok → s.HP.listLoaded = 1; 0 → Log "ERROR - NC_HOLY_PROMISE_DB_GET_MEMBER_ACK, nCharNo=%d's MEMBER OVER MAX"

CharDB 0x9444 NC_HOLY_PROMISE_DB_GET_REMAIN_MONEY_CMD { u32 nCharNo, u64 nMoney }  (0xC)              @ FUN_0040cc30
    s = Clients_FindByCharNo(nCharNo): s.HP.remainMoney = nMoney; s.HP.remainMoneyPending = 1

Client_SendHolyPromiseOnMapLogin(s)          from 0x180C map login (W01 §5.4)                         @ FUN_00434c20
    if remainMoneyPending == 1: pending = 0
        if remainMoney != 0: s ← 0x9445 NC_HOLY_PROMISE_CLIENT_GET_REMAIN_MONEY_CMD { u64 nMoney }  (8)
             send failed → return (the list below is skipped)
             # client FUN_004b0920: "%s, You've done a great job to help your trainee as a master." + the amount
             # and "You can receive your reward at Elderine whenever you want it."
    if listLoaded == 0: return
    listLoaded = 0
    HP_RefreshOnline(s.HP, s)                                                                             @ FUN_00451610
        masterCharNo ∉ {−1, 0} and m = FindInGameByCharNo(masterCharNo):
            master.LogonInfo |= 1; masterWmHandle = m.wmHandle
            e = HP_FindByCharNo(m.HP, s.charNo); e: e.LogonInfo |= 1; HP_AddOrUpdateMember(m.HP, e, s.charNo, s.wmHandle)
        each member i online (FindInGameByCharNo(memberCharNo[i])) = a:
            member[i].LogonInfo |= 1; memberWmHandle[i] = a.wmHandle; a.HP.master.LogonInfo |= 1; a.HP.masterWmHandle = s.wmHandle
    s ← 0x9414 NC_HOLY_PROMISE_LIST_CMD { INFO UpInfo = HP.master, u8 nPart, u16 MemberCount, INFO MemberInfo[n] }  (0x1D + 0x1A·n)
        nPart bit 0 first, bit 1 last; a part is closed when 0x1D + n·0x1A > 0x1F96 (never with ≤ 20 members)
    HP_SendLogin(s.HP, s.name)                                                                            @ FUN_00451700
        0x9416 NC_HOLY_PROMISE_LOGIN_CMD { Name5 CharID = s.name }  (0x14) → the master (if masterWmHandle valid) and every member
    # client: 0x9414 FUN_0050fb40 fills the window; 0x9416 / 0x9417 FUN_0050fba0 / FUN_0050fbd0 mark the name on/offline

HP_OnLogout(s.HP, s)                         from CharacterLogout (W01 §5.4)                          @ FUN_00451790
    masterWmHandle valid: m = Clients_GetInGameByHandle; none (or s has no CHARDATA) → masterWmHandle = 0xFFFF
        else HP_SetOffline(m.HP, s.name); e = HP_FindByCharNo(m.HP, s.charNo) as a member → m.memberWmHandle[idx] = 0xFFFF
    each member handle valid: a = GetInGameByHandle; none → handle = 0xFFFF; else HP_SetOffline(a.HP, s.name),
        a.HP.masterWmHandle = 0xFFFF
    0x9417 NC_HOLY_PROMISE_LOGOUT_CMD { Name5 CharID = s.name } → master (if handle still valid) and every member

0x1074 level change (W01 §7):  if HP_HasMaster(s.HP): HP_OnLevelChange(s.HP, s, level); HP_RequestReward(s)   @ FUN_0042e160
    # a character without a master skips both: its apprentices never learn its new level (original bug) W04-B37
HP_OnLevelChange(hp, s, level)                                                                           @ FUN_00451930
    if masterWmHandle valid:
        m = GetInGameByHandle: HP_SetLevel(m.HP, s.name, level)
        if hp.master.Level < level + 10:          # cached master level, see W04-B37
            → CharDB 0x9420 NC_HOLY_PROMISE_DB_DEL_UP_REQ { u32 nCharNo = s.charNo, u32 nUpCharNo = masterCharNo,
                                                             u8 nDelCmdType 1 (level gap) }   (answer 0x9421, §12.3)
        # an offline master: no check at all, the gap can grow until both are online
    each member online: HP_SetLevel(a.HP, s.name, level)
    0x9419 NC_HOLY_PROMISE_LEVEL_CMD { Name5 CharID = s.name, u8 Level }  (0x15) → master and members
    # client FUN_0049b9d0: HolyPromiseWin::SetLevelChange
HP_RequestReward(s)                                                                                       @ FUN_00451290
    → CharDB 0x942A NC_HOLY_PROMISE_DB_REWARD_REQ { u32 nCharNo, u8 nClass = (shape byte 0 >> 2) & 0x1F, u8 nLevel = CHARDATA.level }  (6)
```

### 12.3 Client requests and their CharDB answers

```pseudo
0x9401 NC_HOLY_PROMISE_SET_UP_REQ { Name5 CharID, Name5 UpCharID @0x14 }  (0x28; CharID not read)   @ FUN_00421990
    # s asks UpCharID to become its master; every refusal is s ← 0x9402 { Error, … } (below)
    HP_HasMaster(s.HP)                       → 0x1749 "You've already registered a master."
    now < s.RejoinableDate                   → 0x174A + ResetableDateTime / tm_ResetableDateTime = that date
                                               (client: "Master registration will be available after %s.", strftime "%m-%d. %H:%M")
    t = Clients_FindInGameByCharName(UpCharID); t or t.CHARDATA or s.CHARDATA missing → 0x174B "Master cannot be found."
    t.charNo == s.charNo                     → 0x176E "You can not specify yourself as a supporter."
    t.level < s.level + 10                   → 0x174C "Your character needs to be 10 levels lower than the requested master."
    r = HP_CheckCanAddMember(t.HP, s.charNo): 1 → 0x174D "The master is unable to accept additional apprentices."
                                              2 → 0x174E "You're already registered as an apprentice."
    now < t.MemberAcceptableDate             → 0x1750 "24 hours must pass before a master can receive a new apprentice."
                                               (ResetableDateTime filled; the client shows only the table text)
    else:
        s ← 0x9403 NC_HOLY_PROMISE_SET_UP_CONFIRM_ING { Name5 UpCharID = t.name }  (0x14)   # "You've asked %s to be your master."
        t ← 0x9404 NC_HOLY_PROMISE_SET_UP_CONFIRM_REQ { Name5 CharID = s.name, Name5 UpCharID = t.name }  (0x28)
            # client `On_NC_HOLY_PROMISE_SET_UP_CONFIRM_REQ` FUN_004afc30: while a dice game is running
            # (MHDiceGameTask::IsDicegamePlaying) the packet is dropped and no 0x9405 is sent; otherwise
            # HolyPromiseWin::SetID(CharID, UpCharID) and a yes/no box with TextData 0x37490f2e "%s is requesting you
            # as a master. Do you wish to accept?" (CharID) → 0x9405
    refusal: s ← 0x9402 NC_HOLY_PROMISE_SET_UP_ACK { u16 Error, INFO UpInfo (name zeroed, LogonInfo/Level/Flags not written),
             i32 ResetableDateTime, tm tm_ResetableDateTime }  (0x44)
             # the date fields are written only for 0x174A / 0x1750 (original bug) W04-B32
    # no pending-request state is kept anywhere

0x9405 NC_HOLY_PROMISE_SET_UP_CONFIRM_ACK { Name5 CharID, Name5 UpCharID @0x14, u8 bAccept @0x28 }  (0x29)   @ FUN_00421d10
    # sent by the would-be master m = this session; CharID names the apprentice
    a = Clients_FindInGameByCharName(CharID); a, a.CHARDATA and m.CHARDATA required, else return
    # UpCharID is not read, no pending request is checked, and none of 0x9401's checks (level gap, locks, own name)
    # are repeated: any player can make any master-less online player its apprentice (original bug) W04-B31
    HP_HasMaster(a.HP) → a ← 0x9402 { 0x174E, name zeroed, rest not written }; return
    bAccept == 0       → a ← 0x9402 { 0x1748 "Apprenticeship request has been denied." }; return
    → CharDB 0x941E NC_HOLY_PROMISE_DB_SET_UP_REQ (0x54) {
        (packet names zeroed first, FUN_0041e540)
        ReqInfo = { PromiseCharID = a.name, LogonInfo |= 1 (the other bits are stale stack; the DB ignores them), Level = a.level, Flags 0, PromiseCharNo = a.charNo,
                    RegDate / RejoinableDate / MemberAcceptableDate = a's three dates }
        UpInfo  = { PromiseCharID = m.name, LogonInfo |= 1 (same), Level = m.level, Flags 0, PromiseCharNo = m.charNo, RegDate 0,
                    RejoinableDate / MemberAcceptableDate = **a's** dates (the DB reads only the charNos and Flags) } }

CharDB 0x941F NC_HOLY_PROMISE_DB_SET_UP_ACK { INFO_DB ReqInfo, INFO_DB UpInfo @0x2A, u16 DBError @0x54 }  (0x56)   @ FUN_00411ba0
    a = FindInGameByCharNo(ReqInfo.PromiseCharNo); m = FindInGameByCharNo(UpInfo.PromiseCharNo)
    if DBError ∈ {0x1740, 0x1751}:
        a: HP_SetMaster(a.HP, UpInfo, UpInfo.PromiseCharNo, m ? m.wmHandle : 0xFFFF)
           DBError 0x1740 and a.level < 10 → CharDB 0x942A REWARD_REQ { a.charNo, a.class, nLevel 1 }   # level-1 reward row
        m: HP_AddOrUpdateMember(m.HP, ReqInfo, ReqInfo.PromiseCharNo, a ? a.wmHandle : 0xFFFF)
        all zones ← 0x9432 NC_HOLY_PROMISE_MY_UP_ZONE { u32 nCharNo = a, u32 nUpCharNo = m }   (zone: empty handler, Z08 §9)
    a ← 0x9402 { Error = DBError, UpInfo = UpInfo's INFO part, ResetableDateTime / tm not written (W04-B32) }
        # client FUN_004af970: 0x1740/0x1751 → HolyPromiseWin::SetHignHolyPromise, "You've been added as %s's apprentice.";
        # else the error text (0x1741 "User is already logged on." for the DB's ring check, 0x1742, 0x1743, 0x1749)
    m ← 0x9415 NC_HOLY_PROMISE_ADD_CMD { u16 Error = DBError, INFO MemberInfo = ReqInfo's INFO part }  (0x1C)
        # client FUN_004afe90: ok → AddPromise, "%s has been registered as your apprentice."; else the error text

0x9406 NC_HOLY_PROMISE_DEL_UP_REQ {}   (apprentice leaves)                                               @ FUN_00415c00
    s.CHARDATA required
    !HP_HasMaster → s ← 0x9407 { u8 nDelCmdType (not written, original bug W04-B33), u16 Error 0x1758 "Master's User ID cannot be found." }
    masterCharNo ∉ {0, −1} → CharDB 0x9420 NC_HOLY_PROMISE_DB_DEL_UP_REQ { s.charNo, masterCharNo, nDelCmdType 0 }  (9)
    # masterCharNo 0/−1 with a master name: no answer at all

CharDB 0x9421 NC_HOLY_PROMISE_DB_DEL_UP_ACK { u32 nCharNo, u32 nUpCharNo, u8 nDelCmdType, u16 DBError @9 }  (0xB)   @ FUN_00410d30
    a = FindInGameByCharNo(nCharNo)
    if DBError == 0x1740:
        m = FindInGameByCharNo(nUpCharNo); e = HP_FindByCharNo(m.HP, nCharNo):
            m ← 0x9418 NC_HOLY_PROMISE_DEL_CMD { Name5 CharID = e.name, u8 nDelCmdType }  (0x15); HP_RemoveMember(m.HP, e)
        if a:
            # rejoin lock: only for a voluntary leave (type 0) and only when the master is online or was online in the last
            # 5 days (master.LogonInfo + 120 h > now)
            if nDelCmdType == 0 and (master online or now < master.LogonInfo + 5 days):
                → CharDB 0x942C NC_HOLY_PROMISE_DB_SET_DATE_REQ { nCharNo, RejoinableDate = local now + 24 h,
                                                                  MemberAcceptableDate = a's current one }  (0xC)
            HP_ClearMaster(a.HP)
        all zones ← 0x9432 { nCharNo, nUpCharNo −1 }
    a ← 0x9407 NC_HOLY_PROMISE_DEL_UP_ACK { u8 nDelCmdType, u16 Error = DBError }  (3)
        # client FUN_004afb60: ≠ 0x1740 → error text (0x1744); type 0 "Apprenticeship has been terminated.", 1 "Your relationship
        # with %s has been terminated due to your level increase.", 2 "…because your masters character has been deleted."; then DelUpHolyPromise
    # client 0x9418 FUN_004afda0: type 1 "…terminated due to discrepancy in character levels.", 2 "%s has deleted their
    # character…", 0: own master's name → "Apprenticeship has been terminated." else "%s has been removed from apprenticeship."

0x940A NC_HOLY_PROMISE_DEL_DOWN_REQ { Name5 DownCharID }  (0x14; master releases an apprentice)       @ FUN_0041e570
    s.CHARDATA required
    e = HP_FindByName(s.HP, DownCharID, &idx); none or idx −1 (the name is s's own master)
        → s ← 0x940B { Name5 DownCharID = zeroed, u16 Error 0x1760 "Apprentice's User ID cannot be found." }
    → CharDB 0x9422 NC_HOLY_PROMISE_DB_DEL_DOWN_REQ { u32 nCharNo = s.charNo, u32 nDownCharNo = memberCharNo[idx], Name5 DownCharID }  (0x1C)

CharDB 0x9423 NC_HOLY_PROMISE_DB_DEL_DOWN_ACK { u32 nCharNo, u32 nDownCharNo, Name5 DownCharID, u16 DBError @0x1C }  (0x1E)   @ FUN_00410fe0
    m = FindInGameByCharNo(nCharNo)
    if DBError == 0x1740:
        a = FindInGameByCharNo(nDownCharNo); a and HP_FindByCharNo(a.HP, nCharNo) is a's master (idx −1):
            a ← 0x9418 { CharID = a's master name, nDelCmdType 0 }; HP_ClearMaster(a.HP)
        if m:
            # acceptance lock, same 5-day rule on the apprentice's LogonInfo when the apprentice is offline
            if a online or (e = HP_FindByCharNo(m.HP, nDownCharNo) and now < e.LogonInfo + 5 days):
                → CharDB 0x942C { nCharNo, RejoinableDate = m's current one, MemberAcceptableDate = local now + 24 h }
            HP_RemoveMember(m.HP, DownCharID)
        all zones ← 0x9432 { nDownCharNo, −1 }
    m ← 0x940B NC_HOLY_PROMISE_DEL_DOWN_ACK { Name5 DownCharID, u16 Error = DBError }  (0x16)
        # client FUN_004afaa0: ok → "%s has been removed from apprenticeship." + DelHolyPromise; else error text (0x1744)

CharDB 0x942D NC_HOLY_PROMISE_DB_SET_DATE_ACK { u32 nCharNo, DATE RejoinableDate, DATE MemberAcceptableDate, u16 DBError }  (0xE)   @ FUN_0040cbe0
    s = FindInGameByCharNo: s.RejoinableDate / s.MemberAcceptableDate = the packet's dates
    # DBError (0x1752 on failure) is not checked (original bug) W04-B38: the lock holds in memory until the next login

CharDB 0x942B NC_HOLY_PROMISE_DB_REWARD_ACK { u32 nCharNo, u8 nClass, u8 nLevel, u16 DBError, u8 nNumOfItems @8,
        {u16 id, u16 lot}[n] @9 }                                                                         @ FUN_0040cac0
    s = FindInGameByCharNo(nCharNo) (the apprentice, owner of the reward box items, D04); nNumOfItems == 0 → nothing
    s ← 0x941A NC_HOLY_PROMISE_REWARD_ITEM_CMD { u8 nNumOfItems, {u16 id, u16 lot}[n] }  (1 + 4n)   # DBError not forwarded
        # client FUN_004aff60: "You've received %s(%d) to your Monarch." per item
```

### 12.4 Character deletion and the zone query

```pseudo
CharDB 0x9425 NC_HOLY_PROMISE_DB_DEL_CHAR_ACK { u32 nCharNo, u16 DBError }  (6)   (asked by OPTool 0x281F, §4.3)   @ FUN_0040f390
    # DBError (0x1745 on failure) is not checked
    for every session s with CHARDATA:
        s.HP.masterCharNo == nCharNo (s was the deleted character's apprentice):
            all zones ← 0x9432 { s.charNo, −1 }; s ← 0x9418 { CharID = master name, nDelCmdType 2 }; HP_ClearMaster(s.HP)
        e = HP_FindByCharNo(s.HP, nCharNo) (any index):
            s ← 0x9418 { CharID = e.name, nDelCmdType 2 }; HP_RemoveMember(s.HP, e)
        # masterCharNo survives HP_ClearMaster, so the second test matches the cleared master again: a second 0x9418 with an
        # empty name ("…has deleted their character" twice) (original bug) W04-B35

OPTool 0x9425 (same body, OPTool parser)                                                                  @ FUN_00427cb0
    same as above, but the second test requires idx == −1: the deleted character is never removed from its master's member
    list, and the apprentice gets the duplicate message (original bug) W04-B36
    # reachable only if an operator tool itself sends 0x9425 to the WM (inferred; the CharDB answer arrives on the CharDB parser)

Zone 0x9434 NC_HOLY_PROMISE_MYUPPER_REQ { ref {u16 zoneHandle, u32 charNo} }  (6)                       @ FUN_0042b8c0
    s = Clients_FindByCharNo(ref.charNo)
    reply 0x9435 NC_HOLY_PROMISE_MYUPPER_ACK { ref (echo), u32 nUpCharNo = s ? s.HP.masterCharNo : −1 }  (0xA)
    # stale after a release in the same session (W04-B34); the 2016 zone ignores the value (Z08 §9)
```

## 13. Instance dungeons (dept 41)

The zone side (gates, level-select menus, the cluster manager) is Z08 §5. The WM only relays between zones, tells group
members about the empty-dungeon countdown, and holds an in-memory instance ranking that the 2016 Character server never
feeds (§13.3).

### 13.1 Empty-dungeon countdown and reset (CParserZone)

The zone's `MapClusterManager::MapCluster::mc_Routine` (zone FUN_004868d0) sends 0xA401 when an instance has had no
players for 20 s and arms a 300-s timer; it sends 0xA403 when players are back or when it deletes the instance
(`mc_DeleteInstanceDungeon` FUN_00486710, `mc_AllDropFilm` FUN_00485290). Read only as far as these sends; the
cluster timers are Z08's.

```pseudo
0xA401 NC_INSTANCE_DUNGEON_EMPTY_DUNGEON_CMD { u8 Category, u32 RegisterNumber }  (5)                    @ FUN_0042ba20
    leader = −1        # W02 helpers: Party_GetMemberCount FUN_00464dc0 (−1 for partyNo > 3999), Raids_Get FUN_00462f90
    Category 0 (party): party = RegisterNumber (u16); each member slot: s = Clients_GetByHandle(member.wmHandle) with CHARDATA,
        same charNo and not pending (Party_IsPending) → s ← 0x0810 NC_MISC_RESTMINUTE_CMD { u8 1, u16 300 }  (3)
        leader = member[0].charNo (the party master, W02 §1) if the party exists
    Category 3 (raid): raid = Raids_Get(RegisterNumber); each member (Clients_FindByCharNo, CHARDATA) ← 0x0810 { 1, 300 };
        leader = raid.leaderCharNo (+0x10)
    other categories: nobody is told; leader stays −1
    all zones ← 0xA402 NC_INSTANCE_DUNGEON_DELETE_DUNGEON_CMD { u8 Category, u32 RegisterNumber, u32 ReaderRegisterNumber = leader }  (9)
        # the zone holding the leader opens the "ID_DeleteNow" menu (Z08 §5.3); leader −1 → no menu
    # client 0x0810 FUN_004997a0: type 1 → KQuestTimeWin::ResetTime(300) (seconds: Z01 sends limit/10)

0xA403 NC_INSTANCE_DUNGEON_RESET_COUNTDOWN_CMD { u8 Category, u32 RegisterNumber }  (5)                  @ FUN_0042bc40
    same member loops (party only if Party_GetMemberCount ≠ −1) → 0x0810 { 1, 0 } (clears the timer window); nothing to the zones
```

### 13.2 Level-select relay (ModeIDGate, Z08 §5.3)

```pseudo
0xA408 NC_INSTANCE_DUNGEON_LEVEL_SELECT_CHECK_REQ { u8 nStartZoneNum, u8 nDestZoneNum, u32 nCharRegNum @2, u32 nInDunRegNum @6,
        i32 IndunCategory @0xA, u16 nNPCHandle @0xE, ORToken Argument @0x10 }  (0x24)                     @ FUN_0042c630
    Clients_FindByCharNo(nCharRegNum) required (else nothing)
    dest = Zones_Get(nDestZoneNum)
    none → sender ← 0xA409 NC_INSTANCE_DUNGEON_LEVEL_SELECT_CHECK_ACK { nCharRegNum, nNPCHandle, u16 nError 2, i32 eLevelType 3 }  (0xC)
        # zone A reads nError 2 as "no instance yet" and offers every level; the join then fails (original bug) W04-B45
    else dest ← 0xA40A …_CHECK_ECHO_REQ { nStartZoneNum (from the packet), nCharRegNum, nInDunRegNum, IndunCategory,
        nNPCHandle, Argument }  (0x23)

0xA40B …_CHECK_ECHO_ACK { u8 nStartZoneNum, u32 nCharRegNum @1, u16 nNPCHandle @5, u16 nError @7, i32 eLevelType @9 }  (0xD)   @ FUN_0042c7d0
    FindByCharNo(nCharRegNum) and z = Zones_Get(nStartZoneNum) required
    z ← 0xA409 { nCharRegNum, nNPCHandle, nError, eLevelType }  (0xC)

0xA40E …_JOIN_REQ { as 0xA408, i32 eLevelType @0x24 }  (0x28)                                            @ FUN_0042c8e0
    FindByCharNo(nCharRegNum) required
    no dest zone → sender ← 0xA40F …_JOIN_ACK { nCharRegNum, nNPCHandle, nError 2, eLevelType 3, Name3 sMapName "" }  (0x18)
        # zone A: 2 → system text "RecallDisableField"
    else dest ← 0xA410 …_JOIN_ECHO_REQ { nStartZoneNum, nCharRegNum, nInDunRegNum, IndunCategory, nNPCHandle, Argument, eLevelType }  (0x27)

0xA411 …_JOIN_ECHO_ACK { u8 nStartZoneNum, u32 nCharRegNum @1, u16 nNPCHandle @5, u16 nError @7, i32 eLevelType @9, Name3 sMapName @0xD }  (0x19)   @ FUN_0042cac0
    FindByCharNo and Zones_Get(nStartZoneNum) required → that zone ← 0xA40F { nCharRegNum, nNPCHandle, nError, eLevelType, sMapName }  (0x18)
```

The WM adds no state and no checks of its own: a character that logs out mid-flow drops the answer (zone A then keeps
its request flag, Z08-B9).

### 13.3 Instance ranking (`g_IndunRank`, DAT_006c5568, all names *ours*)

Three ranks per dungeon *(pdb2017 `E_INDUN_RANK_TYPE`)*: 0 damage dealt, 1 damage taken, 2 healing done.

| Offset | Field |
|---|---|
| +0x000 | u8 mapCount (≤ 32) |
| +0x001 | `SHINE_INDUN_INFO` map[32] (0xD: Name3 MapIDClient, u8 ModeIDLv) |
| +0x1A8 | board[32], 0x7A8 each: `PROTO_AVATAR_SHAPE_INFO` top-3 shapes ×3 ranks (+0x00 dealt 1st…3rd, +0x0C taken, +0x18 healing), u8 count dealt / taken / healing (+0x24/+0x25/+0x26), `SHINE_INDUN_RANK_CLIENT_VALUE` (0x20: Name5, u8 class @0x14, u64 value @0x18) dealt[20] @+0x28, taken[20] @+0x2A8, healing[20] @+0x528 |

Per character, session +0x1EDA8 holds 32 `my rank` records of 0x50, indexed like the boards (`Client_GetMyRank`
FUN_00433da0, by index FUN_00433de0; cleared at character login by FUN_00433e80): +0x00/+0x04/+0x08 u32 rank dealt /
taken / healing, +0x10/+0x18/+0x20 u64 previous day's values, +0x28 u8 h, m, s and +0x2B u8 year−1900, month−1, day of
the previous best time, +0x30/+0x38/+0x40 u64 current values, +0x48 h, m, s, +0x4B y, m, d. Session +0x1F7A8 / +0x1F7AC
/ +0x1F7B0 / +0x1F7B4: earliest next tab request (dealt / taken / healing / my rank; getters FUN_00433e00…FUN_00433e30,
setters FUN_00433e40…FUN_00433e70, reset to 0 at login).

```pseudo
IndunRank_FindOrAddMap(info) → index                                                                    @ FUN_00402460 (asm read)
    0xFF if info is null, mapCount ≥ 32 or the name is empty; the index of the equal {name, level}; else appends the map
    and returns the new index         # every lookup below goes through this, also with client-supplied names
IndunRank_GetBoard(info) = &board[FindOrAddMap(info)] (null for 0xFF)                                   @ FUN_00402560
IndunRank_InsertDealt / Taken / Healing(info, VALUE v, shape) → rank 1…20 or 0      @ FUN_004025a0 / FUN_00402890 / FUN_00402bb0
    zero value → 0. Keeps the list sorted by value (descending), one entry per name: an equal name with a higher value
    stops (0); otherwise the new entry goes before the first entry ≤ its value, the player's old entry (if lower) is
    removed, and the list is cut at 20. A new rank 1…3 updates the three shapes (shifting the lower ones down).
Board accessors (each looks the map up with FindOrAddMap; null / 0 for 0xFF):
    shape setters (0xA41F) dealt 1st/2nd/3rd FUN_00402f70 / FUN_00402fb0 / FUN_00402ff0, taken FUN_00403030 / FUN_00403070 /
    FUN_004030b0, healing FUN_004030f0 / FUN_00403130 / FUN_00403170; list setters FUN_004031b0 / FUN_00403220 / FUN_00403290
    (count capped at 20); shape getters dealt FUN_00403300 / FUN_00403340 / FUN_00403380, taken FUN_004033c0 / FUN_00403400 /
    FUN_00403440, healing FUN_00403480 / FUN_004034c0 / FUN_00403500; entry i FUN_00403540 / FUN_00403590 / FUN_004035e0;
    count FUN_00403630 / FUN_00403670 / FUN_004036b0. Entry copy (VALUE, 0x20) FUN_00402180. Construction
    FUN_00402ed0 (+ per-board ctor / dtor FUN_004022c0 / FUN_00402360, table dtor FUN_004023f0).
Session tab cooldowns: getters FUN_00433e00 / FUN_00433e10 / FUN_00433e20 / FUN_00433e30, setters FUN_00433e40 /
    FUN_00433e50 / FUN_00433e60 / FUN_00433e70 (dealt / taken / healing / my rank).

IndunRank_DailyReset()                       from the WM main loop FUN_00406760                         @ FUN_004021c0
    now < g_IndunRankNextReset (DAT_0049a024, 0 at start) → return
    tm = tomorrow 00:00 local; g_IndunRankNextReset = mktime(tm)
    for every client session in use:
        clear all mapCount boards (memset 0x7A8 each)   # repeated per session, and never done without a session (W04-B44)
        Client_RotateMyRank(s, tm)                                                                    @ FUN_00433fe0
            each of the 32 records: previous = current (values, time, date); current values / time = 0;
            current date = tm's (tomorrow's) date        # the day after the one that starts (W04-B44)
```

```pseudo
Client 0xA41B NC_INSTANCE_DUNGEON_RANK_TAB_DAMAGEDEALT_REQ { SHINE_INDUN_INFO sIndunInfo }  (0xD)      @ FUN_0041a420
Client 0xA41C …_DAMAGETAKEN_REQ (same)                                                                   @ FUN_00418fb0
Client 0xA41D …_HEALINGDONE_REQ (same)                                                                   @ FUN_004191d0
    now < s.tabNext[type] → s ← 0xA421 / 0xA422 / 0xA423 { …, u16 nErr 0x3A01 @0xC }  (0x13; nothing else written, W04-B40)
        # client FUN_004b47c0 (and siblings): 0x3A01 → system text TextData3 0x938F63DA (empty in the 2016 client table)
    s.tabNext[type] = now + 3 s
    reply 0xA421 NC_INSTANCE_DUNGEON_RANK_TAB_DAMAGEDEALT_ACK (resp. 0xA422 TAKEN, 0xA423 HEALINGDONE) {
        PROTO_AVATAR_SHAPE_INFO shapeInfo1st / 2nd / 3th = the board's three shapes for that rank,
        u16 nErr 0x3A00, u32 nRank = s.myRank[map].rank of that type, u8 nCount, SHINE_INDUN_RANK_CLIENT_VALUE[nCount] }  (0x13 + 0x20·n)
    # board and my-rank lookups dereference the result unchecked: once 32 distinct names are in g_IndunRank (any client can
    # add names with these requests), a request for a 33rd name reads through a null pointer and crashes the WM
    # (original bug) W04-B39
    # client: 0x3A00 → IDRankingWin::SetRankInfo(rank, count, entries, shapes)

Client 0xA41E …_TAB_MYRANK_REQ { SHINE_INDUN_INFO }  (0xD)                                               @ FUN_004193f0
    cooldown as above (s.tabNext[3]) → 0xA424 { nErr 0x3A01 } (0x3E, rest not written)
    e = Client_GetMyRank(s, info) (unchecked, W04-B39)
    reply 0xA424 NC_INSTANCE_DUNGEON_RANK_TAB_MYRANK_ACK { u16 nErr 0x3A00, u64 nPrevDamageDealt / Taken / HealingDone = e+0x10…,
        u8 nPrevPlayTimeHour / Minute / Second / Year / Month / Day = e+0x28…, u64 nCurr… = e+0x30…, u8 nCurrPlayTime… = e+0x48… }  (0x3E)

Zone 0xA419 NC_INSTANCE_DUNGEON_MAP_REGIST_CMD { u16 nMapCount, SHINE_INDUN_INFO sIndunInfos[n] }  (2 + 0xD·n)   @ FUN_00428870
    # sent by every zone at connect (Z01 §5 fc_IndunMapRegist); taken only if nMapCount ≤ 32 and none was taken before
    g_IndunMapCount (DAT_00557d10) = n; g_IndunMaps (DAT_00557d14) = the entries   # written here only, read nowhere else
    → CharDB 0xA41A NC_INSTANCE_DUNGEON_RANK_REQ { u16 nMapCount, SHINE_INDUN_INFO[n] }  (same bytes)
    # the 2016 Character server registers no 0xA41A handler, so 0xA41F never comes back (original bug) W04-B43
```

CharDB answers. The 2016 Character server registers none of 0xA413 / 0xA415 / 0xA41A and sends none of these packets
(no send sites in its export). The zone's `cIndunRankResult` (zone FUN_005ee4d0) result packet 0xA413 goes to the Character
server too and is dropped there (C01). So the four handlers below are dead in 2016, the boards and my-rank records stay
empty, and the tab replies above always show empty lists (W04-B43).

```pseudo
CharDB 0xA41F NC_INSTANCE_DUNGEON_RANK_ACK { SHINE_INDUN_INFO, 9 shapes @0xD, u8 counts @0x31…0x33, 3 × VALUE[20] @0x34 / 0x2B4 / 0x534 }  (0x7B4)   @ FUN_0040e8e0
    board(sIndunInfo) = the packet (shapes, lists with count ≤ 20)

CharDB 0xA414 NC_INSTANCE_DUNGEON_RANK_SAVE_WORLD_CMD { SHINE_INDUN_INFO sIndunInfo, u32 nPlayTime @0xD (s), u16 nRankCount @0x11,
        SHINE_INDUN_RANK ranks[n] @0x13 (0x20: u32 nCharRegNum, u64 nDamageDealt @8, nDamageTaken @0x10, nHealingDone @0x18) }   @ FUN_0040f9f0
    per rank: s = Clients_FindByCharNo(nCharRegNum) with CHARDATA and shape (+0x568), else skip
        for type 0, 1, 2: r = IndunRank_Insert<type>(info, {s.name, class = (shape byte 0 >> 2) & 0x1F, value}, s.shape)
            1 ≤ r ≤ 20 → every in-game player ← 0xA425 NC_INSTANCE_DUNGEON_RANK_NEW_RANK_MSG { Name5 nCharID = s.name,
                SHINE_INDUN_INFO, u8 rankType, u32 nRank = r }  (0x26)  (Clients_BroadcastInGame(pkt, 0))
                # client FUN_004b74f0: system message with the name (" (Hero)" suffix) and the rank
        Client_UpdateMyRank(s, info, rank, nPlayTime)                                                   @ FUN_00433ea0
            current values = max(current, new) each; best time (h = t/3600, m = t%3600/60, s = t%60) kept if faster or unset
    → CharDB 0xA415 NC_INSTANCE_DUNGEON_RANK_UPDATE_DB_REQ { SHINE_INDUN_INFO, u16 CharListCount, {u16 wmHandle, u32 charNo}[n] }
        # n = every in-game character of the world, not the ranked ones (original bug) W04-B41
        # C01 listed 0xA415 as sent to a client: it goes to the Character server

CharDB 0xA416 NC_INSTANCE_DUNGEON_RANK_UPDATE_DB_ACK { SHINE_INDUN_INFO, u16 CharListCount @0xD,
        SHINE_INDUN_RANK_RANKING[n] @0xF (0x10: u16 clienthandle, u32 dealt / taken / healing rank @4/@8/@0xC) }   @ FUN_0040ecd0
    per entry: s = Clients_GetByHandle(clienthandle); e = Client_GetMyRank(s, info): e's three ranks = the entry's

CharDB 0xA420 NC_INSTANCE_DUNGEON_RANK_MYRANK_CMD { u32 nCharRegNum, u16 nMyRankCount, SHINE_INDUN_RANK_MYRANK[n] @6 (0x60) }   @ FUN_0040e9f0
    s = Clients_FindByCharNo; all 32 records: current date = today, previous date = yesterday, both times 0
    per entry: e = Client_GetMyRank(s, entry.sIndunInfo): ranks = nCurr…Rank, current / previous values,
        times from nCurrPlayTime / nPrevPlayTime (−1 = 0:00:00; minutes = t / 60 without % 60, original bug W04-B42),
        dates from nCurrPlayDate / nPrevPlayDate (localtime; −1 keeps the previous entry's date)
```

## 14. Chat block list (dept 42 CHAT_RESTRICT)

An account-wide list of blocked characters (DB table `tChatBlock {nUserNo, nCharNo}`, D04 §10). The WM keeps a copy in
the session, answers duplicate / self / prisoner checks itself, relays add / delete to the Character server and pushes
the list to the client once per character login. **Nothing in the WM filters chat with it**: whispers (§2.1), notices
and party chat are delivered regardless. The 2016 client filters on its side: `ChatBlockListWin::IsRestrictID`
(client FUN_0047e030) and `CChatRestrict::Get` (FUN_0072bf70) are checked in `On_NC_ACT_SOMEONECHAT_CMD`
(FUN_004a0bb0) and `On_NC_ACT_SOMEONESHOUT_CMD` (FUN_004a0ec0); which other chat kinds it filters is C01's.

### 14.1 The list in the session (`CR` = session +0x1E290, all names ours)

| Offset (from session) | Field | Notes |
|---|---|---|
| +0x1E290 | i32 count | ≤ 100 |
| +0x1E294 | `PROTO_CHAT_RESTRICT_INFO`[100] (0x16 each: Name5 sCharID, u8 bIsGM, u8 bIsDeleted) *(pdb2017; layout read)* | the part sent to the client |
| +0x1EB2C | u32 listFresh | 1 after CharDB 0xA801; cleared when 0xA802 has been pushed |
| +0x1EB30 | u32 charNo[100] | parallel to the info array |

- Built by `ChatRestrict_Construct` FUN_0045cd10 (count = 0, listFresh = 0) in the session constructor (W01), freed by
  `ChatRestrict_Destroy` FUN_0045cd40 in the session destructor FUN_004352e0. At character login (`Client_CharLogin_1001`
  FUN_00422be0, and the tutorial login FUN_004371a0) only count is set to 0 (`FriendList_Clear` FUN_0045c320, the same
  one-line function serves both lists); listFresh is left as it was.
- Lookups (all compare the 20 name bytes exactly, case-sensitive): `ChatRestrict_HasName` FUN_0045cc30,
  `ChatRestrict_IndexOfName` FUN_0045cc90 (−1 if absent), `ChatRestrict_IndexOfCharNo` FUN_0045cce0 (−1),
  `ChatRestrict_IsListedOrFull` FUN_0045cbd0 (true if the name is listed **or** count > 99).
- `ChatRestrict_AddOrUpdate(info, charNo)` FUN_0045ca20: count > 100 → 0; name already listed → overwrite that entry and its
  charNo, 2; count > 99 → 0; else append, count++, 1. `ChatRestrict_RemoveCharNo(charNo)` FUN_0045cb10: remove the entry
  and close the gap in both arrays.

```pseudo
CharDB 0xA801 NC_CHAT_RESTRICT_DB_LIST_CMD { u16 nSessionHandle, u16 nChatRestrictListCnt,
        PROTO_CHAT_RESTRICT_DB_INFO[n] @4 (0x1A: u32 nCharNo, Name5 sCharID, u8 bIsGM, u8 bIsDeleted) }      @ FUN_0040d4b0
    # (pdb2017 has no nSessionHandle in this struct; the 2016 WM reads it at +0)
    # sent by the Character server during the 0x1004 character load, only if the list is not empty (D02 §4 step 18)
    s = Clients_GetByHandle(nSessionHandle); none → return (no CHARDATA check)
    n > 100: log "ERROR - OVER MAX CHAT RESTRICT, nCharNo=%d, Chat Restrict count=%d"; n = 100
    CR.count = n; CR.listFresh = 1; copy each entry: info ← {sCharID, bIsGM, bIsDeleted}, charNo[i] ← nCharNo
    # no reply; the client gets the list at the first map login:

Session_PushChatRestrictListOnce(s)                                                                    @ FUN_00435170
    # called from zone 0x180C map login done (`Zone_MapLoginDone_180C` FUN_0042d8d0, W01) on every map login
    if CR.count ≠ 0 and CR.listFresh:
        s ← 0xA802 NC_CHAT_RESTRICT_LIST_CMD { u16 nChatRestrictListCnt = count,
                PROTO_CHAT_RESTRICT_INFO[count] }   (2 + count·22)                                     @ FUN_00430fe0
        CR.listFresh = 0
    # client On_NC_CHAT_RESTRICT_LIST_CMD FUN_004a3f60: replaces its CChatRestrict list and refreshes the block window
```

### 14.2 Client requests and the CharDB answers

nUserNo below is session +0x124 (the account number, W01); nSessionHandle the session's wmHandle (+0x114). The client
(`GameFrameWork::NcChatRestrictAddReq` FUN_004b0640) sends 0xA803 only for a name not already in its own list.

```pseudo
0xA803 NC_CHAT_RESTRICT_ADD_REQ { Name5 sChatRestrictCharID }  (0x14, length not checked)              @ FUN_00422240
    no session / no CHARDATA → return
    reply on refusal: s ← 0xA806 NC_CHAT_RESTRICT_ADD_ACK { u16 nError, Name5 = the requested name, u8 bIsGM, u8 bIsDeleted }  (0x18)
        # bIsGM / bIsDeleted are never written: stale stack bytes, (original bug) W04-B48
    CHARDATA.prisonmin (+0x62) ≠ 0 (in prison, §9)            → 0x1C01   (client: silent)
    name == own CHARDATA.charid (Name5_Equal FUN_004020c0)     → 0x1C02   (client: silent)
    ChatRestrict_IsListedOrFull(name)                          → 0x1C03   client text "You can only block a maximum of 100
        players. Please remove a user from your block list." — also for a name already listed, (original bug) W04-B46
    (dead: the helper returns a bool, so its "== 2" branch that would send 0x1C04 "You already blocked this user." never runs)
    else CharDB ← 0xA804 NC_CHAT_RESTRICT_DB_ADD_REQ { u16 nSessionHandle, u32 nUserNo, Name5 sChatRestrictCharID }  (0x1A)

CharDB 0xA805 NC_CHAT_RESTRICT_DB_ADD_ACK { u16 nError, u16 nSessionHandle, PROTO_CHAT_RESTRICT_INFO @4,
        u32 nChatRestrictCharNo @0x1A }  (0x1E)                                                         @ FUN_00411db0
    s = Clients_GetByHandle(nSessionHandle); none → return
    nError == 0x1C00: ChatRestrict_AddOrUpdate(info, nChatRestrictCharNo) (result ignored: with a full list the entry is
            dropped but the client is still told 0x1C00, (original bug) W04-B47)
        s ← 0xA806 { 0x1C00, info (name, bIsGM, bIsDeleted) }
    else: s ← 0xA806 { nError, info.sCharID, stale bIsGM / bIsDeleted (W04-B48) }
        # DB codes (D04 §10): 0x1C05 bad user, 0x1C06 bad name, 0x1C07 "You already blocked this user.",
        # 0x1C08 "You can only block a maximum of 100 players. …", 0x1C09 no such character, 0x1C0A DB error
    # client On_NC_CHAT_RESTRICT_ADD_ACK FUN_004b06f0: 0x1C00 → "You have blocked %s." (text 0x3e738588), adds the entry,
    # refreshes the window; 0x1C03 / 0x1C04 / 0x1C07 / 0x1C08 → their error text; every other code silent

0xA807 NC_CHAT_RESTRICT_DEL_REQ { Name5 sChatRestrictCharID }  (0x14, length not checked)              @ FUN_0041ec00
    no session / no CHARDATA → return
    name not in CR, or its charNo[i] == −1 → s ← 0xA80A NC_CHAT_RESTRICT_DEL_ACK { 0x1C11, Name5 = requested name }  (0x16)
    else CharDB ← 0xA808 NC_CHAT_RESTRICT_DB_DEL_REQ { u16 nSessionHandle, u32 nUserNo, u32 nChatRestrictCharNo = charNo[i] }  (0x0A)

CharDB 0xA809 NC_CHAT_RESTRICT_DB_DEL_ACK { u16 nError, u16 nSessionHandle, u32 nChatRestrictCharNo }  (8)   @ FUN_004112b0
    s = Clients_GetByHandle(nSessionHandle); none → return
    i = ChatRestrict_IndexOfCharNo(nChatRestrictCharNo)
    found: name = entry i's sCharID; nError == 0x1C10 → ChatRestrict_RemoveCharNo
    not found: nError = 0x1C12, name = 20 zero bytes
    s ← 0xA80A { nError, name }
    # DB codes (D04 §10): 0x1C10 ok, 0x1C13 DB error, 0x1C14 bad user, 0x1C15 bad name, 0x1C16 no such character
    # client On_NC_CHAT_RESTRICT_DEL_ACK FUN_0049bac0: only 0x1C10 → remove by name, refresh; every other code silent

0xA80B NC_CHAT_RESTRICT_DEL_ALL_REQ {}                                                                  @ FUN_004170a0
    no session / no CHARDATA → return
    CharDB ← 0xA80C NC_CHAT_RESTRICT_DB_DEL_ALL_REQ { u16 nSessionHandle, u32 nUserNo }  (6)

CharDB 0xA80D NC_CHAT_RESTRICT_DB_DEL_ALL_ACK { u16 nError, u16 nSessionHandle }  (4)                   @ FUN_0040d5e0
    s = Clients_GetByHandle(nSessionHandle); none → return
    nError == 0x1C20 → CR.count = 0 (FUN_0045c320)
    s ← 0xA80E NC_CHAT_RESTRICT_DEL_ALL_ACK { u16 nError }  (2)
    # DB: 0x1C20 ok (also "nothing to delete"), 0x1C21 DB error, 0x1C22 bad user. Client On_NC_CHAT_RESTRICT_DEL_ALL_ACK
    # FUN_004a4030: 0x1C20 → clears its list and window; others silent
```

## 15. Gamble house: daily coin reset and the return map (dept 47)

The zone side (coins, exchange limit, the house) is Z06 §4. The WM has two parts: the daily reset of the
"exchanged coins" counters, and a per-session copy of the map a player returns to when leaving the gamble house.

### 15.1 `CGambleSystemServer` (daily reset of the exchanged-coin counter; names from its log strings)

The object is a single i32 `nextReset` (time_t, local time) at WM +0x22B538 = `g_GambleSystemServer` DAT_006c5560,
set to 0 by `CGambleSystemServer_Construct` FUN_0043c180 in the WM constructor. The reset time of day comes from
`GBHouse.shn` (loaded by W01's data loader FUN_00404100 into the data object DAT_006c5220, fatal "GAMBLE HOUSE DATA READ
FAILED" if missing): row 0 (`Data_GBHouseRow` FUN_0043a340), columns `GB_ResetTimeHour` (+8), `GB_ResetTimeMin` (+9),
`GB_ResetTimeSec` (+10). The 2016 table holds one row `{GB_GameMoney 10, GB_ExchangeTax 20, 6, 0, 0}`: reset at
06:00:00 server local time.

```pseudo
CGambleSystemServer_SendExchangeCoinInit(this)                                                          @ FUN_0043c2d0
    # called from W01's main loop FUN_00406760 on every pass (next to CPrisonServer_Tick, §9.1)
    if this.nextReset == 0: CGambleSystemServer_InitSendExchangeCoinInitTime(this)                       @ FUN_0043c1a0
        row = GBHouse row 0; none → log "DEBUG - CGambleSystemServer::InitSendExchangeCoinInitTime : Gamble house
            data error", nextReset stays 0
        t = today at GB_ResetTimeHour:Min:Sec (localtime + mktime)
        nextReset = t if t ≥ now, else the same time tomorrow (tm_mday + 1, mktime)
    if nextReset ≤ now:
        all zones ← 0xBC09 NC_GAMBLE_EXCHANGEDCOIN_INIT_CMD { i32 dChackDate = nextReset }  (4)   (Zones_Broadcast)
            broadcast failure → log "… SendExchangeCoinInit : Zone broadcast fail" (nothing retried)
        nextReset = localtime(nextReset) with tm_mday + 1 → mktime    # one day later, DST-safe
    # with GBHouse row 0 missing, nextReset stays 0 and the second step broadcasts { 0 } and then one day after
    # 1970-01-01 on every pass until it reaches today, (original bug) W04-B49 (needs an empty GBHouse.shn)
```

- Started after 06:00 the WM broadcasts nothing until the next day's 06:00; no reset is sent at start-up. A zone
  that is down at 06:00 misses the broadcast (no catch-up).
- The zone (Z06 §4.1) sets every online player's exchanged count to 0 (or asks GameDB with `dChackDate` if the
  inventory is busy).
- Character load: `Client_CharLogin_1001` FUN_00422be0 (and the tutorial login FUN_004371a0) put `nextReset − 1 day`
  (`CGambleSystemServer_GetNextResetTime` FUN_0043c2c0, localtime, tm_mday − 1, mktime) = the last reset into CharDB
  0x1004 NC_CHAR_CHARDATA_REQ's last field (`tExchangedCoinSumDate`, D02 §4; W01 §4.2 describes it as "stored day-start
  time − 1 day"). The Character server sums only exchanges after that time *(inferred from the name)*. Before the
  first main-loop pass nextReset is 0, so a login in that window sends 1969-12-31.

### 15.2 Return map (CParserZone)

```pseudo
Zone 0xBC1D NC_GAMBLE_WORLD_PREVMAPNAME_CMD { u16 nWldHandle, Name3 sPrevMapName @2, u32 nCharNo @0xE }  (0x12, not checked)
                                                                                                         @ FUN_0042c570
    # zone: sp_Gamble_PrevMapNameSave2World (Z06 §4.1), part of the save to the WM before a map change
    s = Clients_GetByHandle(nWldHandle); s has CHARDATA and CHARDATA.charNo == nCharNo:
        session +0x1ED04 (12 bytes) = sPrevMapName (raw copy, no terminator check)
    else ignored
```

The stored name goes back to the next zone in W01's `Zone_CharDataReq_101C` FUN_00428ba0 as 0xBC01
NC_GAMBLE_ZONE_PREVMAPNAME_CMD (only if not empty, then cleared; W01 §6.3 table); FUN_00434530 (session reset, W01)
clears it.

## 16. GM events (dept 52 EVENT, CParserOPTool)

The operator tool defines timed events (reward abstates for players matching level / class / map / field-type masks);
the WM holds them in memory and pushes the active ones to the zones, which store them (Z08 §13); their effects are Z09's. Nothing is stored in
a database: a WM restart loses every event. No handler checks the packet length (OPTool_CheckAlive only).

### 16.1 `GMEventManager` (`g_GMEventManager` DAT_006c5488 = WM +0x22B460; names from its log strings)

| Offset | Field |
|---|---|
| +0 / +4 / +8 | `std::vector` of records: begin / end / capacity end |
| +0x10 | i16 nextEventNo, 1 at start (`GMEventManager_Construct` FUN_00401dd0); −1 = no more numbers |

Record (0x554 bytes) = `GM_EVENT_DATA` (0x553, *(pdb2017)*, size confirmed by the 2016 copies) + u8 bIsFlagAllReady
@0x553. `GM_EVENT_DATA`: u16 nEventNo, i32 dStartTime @2, i32 dEndTime @6, u16 nRewardAbstateIndex[3] @0xA,
u8 bIsPlayerLevel[255] @0x10, u8 bIsPlayerClass[64] @0x10F, u8 bIsMapID[1024] @0x14F, u8 bIsField_KQ @0x54F,
bIsField_Battle @0x550, bIsField_ID @0x551, bIsField_Normal @0x552. The WM never reads any field but nEventNo.
`GMEventVec_PushBack` FUN_00401e50 / `GMEventVec_Reserve` FUN_00401d50 (grows by half, "vector<T> too long"),
`GMEventManager_Destroy` FUN_00401df0.

"Active" means bIsFlagAllReady == 1: only those are sent to the zones, at zone connect (`GMEventManager_GMEM_SendAllEventInfo`
FUN_004010c0 from W01's `Zone_S2SConnectionReq_0802` FUN_004283e0: zone ← 0xD00B per active event) and when they change.

### 16.2 Handlers

```pseudo
0xD001 NC_EVENT_GET_ALL_EVENT_INFO_REQ {}                                   @ FUN_004270f0 → GMEM_GetAllEventInfo FUN_00401250
    per record, in vector order: op ← 0xD002 NC_EVENT_GET_ALL_EVENT_INFO_ACK { u16 nError 0x3200, u16 nAllEventCnt = n,
        u16 nPacketOrder = 1…n, GM_EVENT_DATA, u8 bIsFlagAllReady }  (0x55A)
    n == 0: one 0xD002 { 0x3200, 0, 0, … } whose GM_EVENT_DATA / flag are stale stack bytes, (original bug) W04-B52
    send failure → log "ERROR - GMEventManager::GMEM_GetAllEventInfo : …"

0xD003 NC_EVENT_ADD_EVENT_REQ { GM_EVENT_DATA }  (0x553)                    @ FUN_00427130 → GMEM_AddEvent FUN_00401ec0
    reply 0xD004 NC_EVENT_ADD_EVENT_ACK { u16 nError, GM_EVENT_DATA }  (0x555)
    nextEventNo == −1 → { 0x3209 ERR_EVENT_ADD_EVENT_TOOMANY, request echoed }
    else: record = request with nEventNo = nextEventNo (the request's number is ignored), flag 0; nextEventNo++;
        push_back; reply { 0x3208 ERR_EVENT_ADD_EVENT_NOERR, request with the assigned nEventNo }
    # not active yet: zones are told only by 0xD009. nextEventNo is an i16: after 0x7FFF it goes negative and reaches
    # −1 after 65 534 additions per WM run (`GMEventManager_Construct` FUN_00401dd0 starts it at 1); then every add is refused (inferred limit, never reached in practice)

0xD005 NC_EVENT_UPDATE_EVENT_REQ { GM_EVENT_DATA }  (0x553)                 @ FUN_00427170 → GMEM_UpdateEvent FUN_00401430
    reply 0xD006 NC_EVENT_UPDATE_EVENT_ACK { u16 nError, request echoed }  (0x555)
    no record with that nEventNo → 0x3212
    else: wasActive = record.flag == 1; record's 0x553 bytes = request (flag kept)
        wasActive: all zones ← 0xD00B NC_EVENT_ADD_UPDATE_EVENT_CMD { record }  (0x553)
            broadcast failed → log, reply 0x3211 (the record is already changed)
        reply 0x3210
    # if that reply cannot be sent, the log prints nEventNo read through the vector's end pointer, (original bug) W04-B53

0xD007 NC_EVENT_DEL_EVENT_REQ { u16 nEventNo }                              @ FUN_004271b0 → GMEM_DelEvent FUN_00401b80
    reply 0xD008 NC_EVENT_DEL_EVENT_ACK { u16 nError, u16 nEventNo }  (4)
    not found → 0x3219 (send-failure log reads past the end as above, W04-B53)
    else erase (later records move down), reply 0x3218
    # an active record is erased without 0xD00C to the zones: they keep running it, (original bug) W04-B50

0xD009 NC_EVENT_SET_ALL_READY_REQ { u16 nEventNo, u8 bIsFlagAllReady }      @ FUN_004271f0 → GMEM_SetAllReady FUN_004016f0
    reply 0xD00A NC_EVENT_SET_ALL_READY_ACK { u16 nError, u16 nEventNo }  (4)
    not found → 0x3222 (send-failure log past the end, W04-B53)
    flag == new value → (nothing sent to zones)
    flag == 1 (new ≠ 1): all zones ← 0xD00C NC_EVENT_DEL_EVENT_CMD { u16 nEventNo }  (2)
    flag ≠ 1 (any new value ≠ flag, also e.g. 2): all zones ← 0xD00B { record }
        # a value other than 0/1 is pushed to the zones but counts as inactive for later updates and zone connects
    broadcast failed → log "DEBUG - GMEventManager::GMEM_SetAllReady : … Zone broadcast fail", reply 0x3221 and continue
    record.flag = new value; reply 0x3220
    # after a failed broadcast the tool gets two replies, 0x3221 then 0x3220, (original bug) W04-B51
```

- The zone handlers of 0xD00B / 0xD00C (zone FUN_0046ddf0 / FUN_0046dae0) are Z08 §13.
- dStartTime / dEndTime are not checked by the WM: a record is sent as soon as it is active; time windows are the
  zone's (Z08 §13 / Z09).

---

## 17. Dept-2 MISC relays, attendance event, NPC schedule (W01 hand-offs)

W01 (W01-core §6.3 end, §7.1, §7.6, §11) handed these handlers and subsystems to W04; they are not in W04's scope table.
Packet names are *(pdb2017)* unless a 2016 log string gives them (`fc_NC_MISC_SPAMMER_*`, `cEvent_Attendance::…`).

### 17.1 Account-server event relay 0x083A (C01 open item)

C01 §5 left open which send of `FUN_00408050` carries 0x083A. The handler is W01's (§7.6: AccountDB 0x0839
NC_MISC_EVENT_DONE_MUNSANG_ACC2WM); the packet names below are *(pdb2017)*: no 2016 string names them, except the
Account server's handler `fc_NC_MISC_EVENT_DONE_MUNSANG_WM2ACC` (account FUN_00402cb0).

```pseudo
AccountDB 0x0839 { u32 nUserNo, u32 nCharNo, u8 nWorldNo, u16 nError @+9, u16 hZone @+0xB, u16 nQuestID @+0xD }   @ FUN_00408050
    needs AccDB_CheckAlive and an in-game session with nCharNo, else nothing
    if nError == 0x1541:
        Clients_BroadcastInGame(0x6402 NC_ANNOUNCE_W2C_CMD { u8 type = 2, char text[] = sprintf(
            "'%s'님이 문화상품권을 획득하였습니다. 축하합니다.", charid) }, skipArena = 0)
            # CP949 text: "'%s' has obtained a culture gift certificate. Congratulations." (our translation)
    zone = g_Zones session hZone; if found:
        SendRaw(zone, 0x083A NC_MISC_EVENT_DONE_MUNSANG_WM2Z { u32 nUserNo, u32 nCharNo, u8 nWorldNo,
                                                               u16 nError, u16 nQuestID })    # 13 bytes, raw header 0x0F
```

- **0x083A goes to the zone only**; clients get 0x6402. That is why the 2016 client has no 0x083A handler.
- The chain is dead in 2016 (original bug) W04-B56: the 2016 zone registers no handler for 0x083A (its dept-2
  table has no cmd 58) and never sends 0x0837 NC_MISC_EVENT_DONE_MUNSANG_Z2WM, which starts it (the WM relays 0x0837 to
  the Account server as 0x0838 in W01's `FUN_0042b7d0`). The Account server's 0x0838 handler answers with a fixed
  nError = 0x1545 and touches no database, so the WM's 0x1541 announcement branch cannot run either.

### 17.2 Chat spam filter settings (0x0844 / 0x0845 / 0x0846)

The player's chat spam-filter options live in the client session (offsets ours):
+0x1ECE0 u8 bIsSpamSpread, +0x1ECE1 u8 bIsSpamBlock, +0x1ECE2 u8 nSpamFilterRate, +0x1ECE3 u8 loaded.
`loaded` is cleared in `Client_CharLogin_1001` FUN_00422be0 and `CWMClientSession_TutorialLoginProcess` FUN_004371a0 (W01).
This is not the chat-block (spam block time) blob at +0x1ECE4 of W01-core §6.3 (0x10CA), and not the block list of §14.

```pseudo
CharDB 0x0844 NC_MISC_GET_CHAT_BLOCK_SPAM_FILTER_DB_CMD { u16 wmHandle, u32 nUserNo @+2, u32 nCharNo @+6,
        u8 bIsSpamSpread @+0xA, u8 bIsSpamBlock @+0xB, u8 nSpamFilterRate @+0xC }      # pushed in the character stream (D02 §4, step 21)   @ FUN_0040d660
    s = Clients_GetByHandle(wmHandle); needs CHARDATA, s.userNo (+0x124) == nUserNo and CHARDATA.charNo == nCharNo
    s.spamFilter = { spread, block, rate }; s.spamFilterLoaded = 1                     # no reply

CWMClientSession::ChatBlockSpamFilterRefresh(s)    (name from its log string)          @ FUN_00431cd0
    # called from W01's 0x180C map-login-done handler on every map login (W01-core §7.3)
    if s.spamFilterLoaded == 1:
        Send s 0x0845 NC_MISC_GET_CHAT_BLOCK_SPAM_FILTER_CMD { u8 bIsSpamSpread, u8 bIsSpamBlock, u8 nSpamFilterRate }
        on send failure log "ERROR - CWMClientSession::ChatBlockSpamFilterRefresh, nCharNo=%d"

0x0846 NC_MISC_SET_CHAT_BLOCK_SPAM_FILTER_CMD { u8 bIsSpamSpread, u8 bIsSpamBlock, u8 nSpamFilterRate }   @ FUN_00417b90
    needs Client_CheckAlive and CHARDATA (no inGame check, no value check)
    Send CharDB 0x0847 NC_MISC_SET_CHAT_BLOCK_SPAM_FILTER_DB_CMD { u32 nUserNo = s.userNo, u32 nCharNo,
                                                                   u8 spread, u8 block, u8 rate }   # 11 bytes; D02: usp_SpamFilter_set, no reply
    # s.spamFilter is NOT updated (original bug) W04-B60: the next map login pushes the old values back in 0x0845
```

Client 0x0845 (`GameFrameWork::On_NC_MISC_GET_CHAT_BLOCK_SPAM_FILTER_CMD` FUN_004a5820): byte 0 → `SetSpamFilteredTextShow`,
byte 1 → two chat-window check boxes, byte 2 → `SetSpamBlockRate`. The client sends 0x0846 from
`NcMistSetChatBlockSpamFilterCmd` *(pdb2017 name)*. D02 stores the filter per user (`usp_SpamFilter_get(nUserNo)`), so it
is shared by all characters of the account (D02 §4).

### 17.3 Client loading-failure report (0x0840 → CharDB 0x0841)

```pseudo
0x0840 NC_MISC_CLIENT_LOADING_BUG_DETECT_CMD { char sLoadingMapName[12], u16 nFailType @+0xC, u16 nLoadingFailCnt @+0xE,
        char sFromMapName[12] @+0x10, char sFromZoneIP[16] @+0x1C, char sToZoneIP[16] @+0x2C, u16 nToZonePort @+0x3C,
        u16 nErrorDataCnt @+0x3E, CLBD_ErrorData ErrorData[nErrorDataCnt] @+0x40 { u16 nErrorNo, u32 nErrorData } }   @ FUN_00417140
    needs Client_CheckAlive and CHARDATA (no length check)
    Send CharDB 0x0841 NC_MISC_DB_CLIENT_LOADING_BUG_DETECT_CMD {
        u32 nCharNo = CHARDATA.charNo, i32 nWorldTime = time(NULL),
        the 0x40 request bytes copied field by field, then nErrorDataCnt × 6 bytes }   # size 0x48 + 6·n
    # nErrorDataCnt is not checked against the request length or the 0x1FFB-byte packet buffer (original bug) W04-B59:
    # n > 1351 writes past the stack buffer (stack cookie → WM crash); the copy also reads past the request
```

Fire-and-forget: the Character server logs the report (`usp_CharacterLoading`, D02 §5). D02 §16 lists the sender of
0x0841 as unknown; it is this handler.

### 17.4 Gold-spammer report and GM chat ban (0x085F … 0x0869)

The report path (0x085F) ends in the GM alert of §2.5. The chat ban is a CHARDATA single-option field: `nChatBan` u32 at
single-option blob +10 (session +0x658, §1.1; W01-core §6.3 0x10D2). The zone keeps its own copy (`chatBlockUntil`,
player +0x2aa54, set by 0x0865, Z01 §9) and refuses chat while it is non-zero (Z02 §3.1). Only a GM with CHARDATA.adminlevel
(+0x64) in 50…100 can ban or release; the ban is set from the client (0x0861), the release from the zone's
`&releasechatban` GM command (zone FUN_00421a60, level 0x32; Z11), which sends 0x0866.

```pseudo
0x085F NC_MISC_SPAMMER_REPORT_REQ { Name5 sSpammerName }                                @ FUN_00417ef0
    needs Client_CheckAlive and CHARDATA (any player may report; reporter == target is not refused)
    t = Clients_FindByCharName(sSpammerName)
    nError = 0x2160 (ok)
    if t is null / has no CHARDATA / t.CHARDATA.charNo == −1 / t.userNo == −1:   nError = 0x2161
    elif Client_GetPrison(t) ≠ 0 (FUN_00409a10: CHARDATA.prisonmin):  nError = 0x2162
    elif Spam_AlreadyReported(t, reporterCharNo) == 1 (§2.5):                       nError = 0x2163
    elif Spam_AddReport(t, reporterCharNo) == 0 (§2.5; may alert the GMs with 0x200D): nError = 0x2163
    Send s 0x0860 NC_MISC_SPAMMER_REPORT_ACK { u16 nError }
    # Spam_AddReport fails only when the target has no report ring buffers; that is answered "already reported"
    #   (original bug) W04-B62

0x0861 NC_MISC_SPAMMER_CHAT_BAN_REQ { Name5 sSpammerName }                              @ FUN_004180f0
    needs Client_CheckAlive, CHARDATA and adminlevel 50…100, else nothing
    t = Clients_FindByCharName(sSpammerName)
    if t online with CHARDATA and t.singleOption.nChatBan ≠ 0:
        Send s 0x0862 NC_MISC_SPAMMER_CHAT_BAN_ACK { Name5 sSpammerName, u16 nError = 0x216B }   # already banned
    else (offline, unknown or not banned):
        Send CharDB 0x0863 NC_MISC_SPAMMER_SET_DB_CHAT_BAN_REQ { u32 nGMCharNo = GM CHARDATA.charNo,
                                                                Name5 sSpammerName, u32 nChatBan = 0x0FFFFFFF }   # 0x1C bytes

0x0866 NC_MISC_SPAMMER_RELEASE_CHAT_BAN_REQ { u32 nGMCharNo, Name5 sSpammerName }   (CParserZone)   @ FUN_0042c3b0
    needs Zone_CheckAlive; GM = Clients_FindByCharNo(nGMCharNo) with CHARDATA and adminlevel 50…100, else nothing
    Send CharDB 0x0868 NC_MISC_SPAMMER_RELEASE_CHAT_BAN_DB_REQ { u32 nGMCharNo, Name5 sSpammerName, u32 nChatBan = 0 }

CharDB 0x0864 NC_MISC_SPAMMER_SET_DB_CHAT_BAN_ACK { u32 nGMCharNo, Name5 sSpammerName @+4, u32 nChatBan @+0x18,
        u16 nError @+0x1C }                                                             @ FUN_0040d980
CharDB 0x0869 NC_MISC_SPAMMER_RELEASE_CHAT_BAN_DB_ACK (same layout)                     @ FUN_0040dbf0
    needs CharDB_CheckAlive
    if nError == success (0x2168 for 0x0864, 0x2170 for 0x0869):
        t = Clients_FindByCharName(sSpammerName)
        if t online with CHARDATA:
            zone = Zones_Get(t.zoneNo (+0x117))
            if zone is null: stop (no GM reply)                                         # (original bug) W04-B61
            if SendPacket(zone, 0x0865 NC_MISC_SPAMMER_ZONE_CHAT_BAN_CMD { Name5 sSpammerName, u32 nChatBan }) fails:
                log "ERROR - CParserCharDB::fc_NC_MISC_SPAMMER_SET_DB_CHAT_BAN_ACK SpammerNo[%d] Zone[%d]"
                    (…RELEASE_CHAT_BAN_DB_ACK… for 0x0869); stop (no GM reply)          # W04-B61
            t.singleOption.nChatBan = nChatBan                                          # only after the zone got it
        # offline target: only the database changes; the next character login loads it (0x10D2, W01)
    GM = Clients_FindByCharNo(nGMCharNo) with CHARDATA and adminlevel 50…100, else stop
    0x0864: Send GM 0x0862 NC_MISC_SPAMMER_CHAT_BAN_ACK { Name5 sSpammerName, u16 nError }
    0x0869: Send GM 0x0867 NC_MISC_SPAMMER_RELEASE_CHAT_BAN_ACK { u16 nError }
    send failure → log "ERROR - CParserCharDB::fc_NC_MISC_SPAMMER_SET_DB_CHAT_BAN_ACK GM[%d]" (… RELEASE … for 0x0869)
```

nError values (D02 §9, 0x0863 / 0x0868): 0x2168 ban ok, 0x2169 DB error, 0x216A name not found; 0x2170 release ok,
0x2172 name not found (a failed release sends no 0x0869 at all, D02-B12). `nChatBan` 0x0FFFFFFF works as a flag: the zone
only tests it for ≠ 0 (Z02 §3.1), so the ban is permanent until released.

Client cross-check (GameFrameWork, senders `NcMiscSpammerReportReq` / `NcMiscSpammerChatBanReq` *(pdb2017 names)*):
- 0x0860 (FUN_0049cb10): 0x2160 shows nothing; other codes show their error text: 0x2161 "Can't find the character",
  0x2162 "Gold spammer has reported" (sent when the target is already in prison), 0x2163 "This gold spammer has already reported".
- 0x0862 (FUN_004b3520): 0x2168 → "[%s] is not allowed to chat now" with the name; else the error text (0x216A "Can't find
  the character", 0x216B "This character is already blocked to chat"; 0x2169 has no entry in `client-error-codes.json`).
- 0x0867 (FUN_004b35b0): 0x2170 → "Backing out chatting block"; else the error text (0x2172 "Can't find the character").

### 17.5 Attendance event (`cEvent_Attendance`, `g_Attendance` DAT_006c53b4 = WM +0x22B38C)

Class and method names come from the log strings (`cEvent_Attendance::Recv_NC_CHAR_EVENT_ATTENDANCE_LIST_DB_ACK`,
`EA_Schedule_Process`, `EA_Event_Check_GetReward`, `EA_Event_Set_RewardData`); field names are ours. An event lasts
28 "days" of `AS_CheckTerm` minutes; a player who stays online `AS_JoinKeepTime` minutes in a day gets that day marked
(Character server `usp_Attendance_setCall`); week and day-count rewards are claimed from the client window.

Tables (loaded by W01's FUN_00404100 into the data object DAT_006c5220 = WM +0x22B1F8, then the object is built):

| Table | Row layout (offsets in the row) | 2016 data |
|---|---|---|
| `AttendSchedule.shn` (data +0xCC, rows at *(+0x100)+0x28) | AS_StartYear u16 @0, AS_StartMonth u8 @2, AS_StartDay u8 @3, AS_StartHour u8 @4, AS_StartMinute u8 @5, AS_JoinKeepTime u16 @6 (minutes), AS_CheckTerm u16 @8 (minutes per day) | 1 row: 2015-11-09 00:00, 60, 1440 |
| `AttendReward.shn` (data +0x10C, rows at *(+0x140)+0x28; `Shn_LoadChecked(…, 0x98, 0x26)` FUN_0043a620) | AR_ID u8 @0, AR_Type u32 @1 (0 = week, 1 = day count), AR_Count u8 @5 (week number / days), AR_ItemInx char[32] @6 | 7 rows: 0…3 week 1…4 (`Attend_Week_n`), 4…6 day counts 20 / 24 / 28 |

Getters: schedule count / row FUN_0043a600 / FUN_0043a5f0, reward count / row FUN_0043a6c0 / FUN_0043a660, reward by AR_ID
FUN_0043a670 (all over the generic SHN row getter FUN_00458ae0).

Object (constructor FUN_0043b3e0, destructor FUN_0043b4e0, both from the WM object's ctor / dtor):

| Offset | Field | Notes |
|---|---|---|
| +0 | u32 scheduleRow | current AttendSchedule row |
| +4 | u8 curDay | 0…27 running; 28 (0x1C) = no running event (ctor value) |
| +8 | time32 eventStart | 0 = no event ever started |
| +0xC | time32 dayEnd[28] | dayEnd[i] = eventStart + (i+1)·CheckTerm·60, DST-corrected; `DayStart(i)` FUN_0043a7c0 = eventStart for i = 0, dayEnd[i−1] else, 0 for i > 27 |
| +0x78 | (= dayEnd[27]) eventEnd | |
| +0x7C | time32 nextTick | once-per-second throttle |
| +0x80 | time32 nextEventStart | start of the next (future) schedule row, 0 = none |
| +0x84 | i32 joinKeepSec | AS_JoinKeepTime·60 |
| +0x88 / +0x8C | `std::list<{time32 due, session*}>` waitList, count | sorted by `due` |
| +0x94…+0x9C | `std::vector<row*>` weekRewards (AR_Type 0) | filled by `EA_Event_Set_RewardData` FUN_0043b9c0 |
| +0xA4…+0xAC | `std::vector<row*>` dayRewards (AR_Type 1) | ″ |

Session fields (ours): +0x1ED10 firstMapLogin flag (`Session_GetFirstMapLogin` / `Set` FUN_00432f50 / FUN_00432f60; set to 1
by `Client_CharLogin_1001`), +0x1ED14 rewardPending, +0x1E28C playingCharNo (W01; −1 = not playing).

```pseudo
Attend_LoadSchedule(this, row r)    (startup with r = 0, and from the tick)            @ FUN_0043b090
    n = schedule row count; if r >= n: nextEventStart = 0; return 0     # at startup 0 = "*FATAL ERROR* - Attend Schedule"
    for r … n−1:
        t = Tm_MakeTimeLocal({AS_Start…}) (mktime with DST normalisation, FUN_0043a6e0)
        if now < t: nextEventStart = t; clear waitList; return 1            # first future row
        scheduleRow = r; eventStart = t; nextEventStart = 0
        dayEnd[i] = t + CheckTerm·60·(i+1) for i < 28
        if CheckTerm % 1440 == 0: from the first boundary whose isdst differs from the start, shift the rest by ∓3600
        curDay = Attend_DayIndex(now) (FUN_0043a790: first i with now < dayEnd[i]; 28 if before start or after the end)
        joinKeepSec = AS_JoinKeepTime·60
    clear waitList; return 1                                              # the last started row wins

EA_Event_Set_RewardData(this)                                                          @ FUN_0043b9c0
    clear both vectors; for each AttendReward row: AR_Type 0 → weekRewards, 1 → dayRewards, other → return 0 (fatal)
    a null row → log "…EA_Event_Set_RewardData : Data NULL", return 0

Attend_InsertPlayer(this, s, time32 from)    ("Player Insert")                         @ FUN_0043b880
    needs s with CHARDATA, s.playingCharNo ≠ −1 and curDay ≤ 27, else 0
    due = from + joinKeepSec; if dayEnd[curDay] <= due: due = dayEnd[curDay] + joinKeepSec   # too late today → next day
    walk waitList: erase nodes whose session is null or has no CHARDATA, erase s's old node (same charNo),
                   insert {due, s} before the first node with node.due >= due
    none found: push_back; return 1

Attend_RemovePlayer(this, charNo)   (W01 CharacterLogout, when playingCharNo ≠ −1)      @ FUN_0043b620 → FUN_0043b580
    erase every node whose session is null, has no CHARDATA, or whose CHARDATA.charNo == charNo

EA_Schedule_Process(this)    (W01 main loop FUN_00406760, every pass)                  @ FUN_0043bde0
    if now < nextTick: return; nextTick = now + 1
    if curDay < 28:
        for at most the current node count, front node first:
            dead session / no CHARDATA / playingCharNo == −1: erase
            elif now < node.due: break
            else:
                Send CharDB 0x10EE NC_CHAR_EVENT_ATTENDANCE_CHECK_DB_REQ { u32 nCharNo, tm tCheckTime = localtime(DayStart(curDay)) }
                if curDay + 1 < 28: node.due = dayEnd[curDay] + joinKeepSec; move the node to the back
                else: erase
        if dayEnd[curDay] <= now:
            curDay += 1
            Attend_SendChangeDay(curDay)                                               @ FUN_0043b630
                # 0x10F5 NC_CHAR_EVENT_ATTENDANCE_CHANGE_DAY_CMD { u8 nChangeIndex = curDay } to every waitList session
                # (dead nodes and playingCharNo == −1 erased); the final step sends nChangeIndex = 28
        if eventEnd <= now: Attend_EndEvent (FUN_0043b2f0): curDay = 28; clear waitList
    elif nextEventStart ≠ 0 and nextEventStart <= now:
        Attend_LoadSchedule(this, scheduleRow)
        pkt 0x10F6 NC_CHER_EVENT_ATTENDANCE_CHANGE_START_CMD { tm tEventStart = localtime(eventStart) }   # 0x24 bytes
        for every client with CHARDATA and playingCharNo ≠ −1:
            if Attend_InsertPlayer(s, eventStart): Send s pkt
            else log "…EA_Schedule_Process : Player Insert Fail nCharNo( %d )"

First map login (W01 0x180C map-login-done, FUN_0042d8d0), when s.firstMapLogin == 1:
    Session_SendSupportReward(s)                                                       @ FUN_00433ab0
        if s.userKindUntil (+0x1ED58) < now: s.userKind (+0x1ED54) = 1 (normal); s.userKindUntil = 0   # W01-core §3.3
        Send zone[s.zoneNo] 0x1120 NC_CHAR_SUPPORT_REWARD_CMD { u32 nCharNo, u32 eUserType = s.userKind }   # zone: Z07 §1.2
    Attend_RequestList(charNo)                                                         @ FUN_0043a7f0
        if eventStart ≠ 0:   # also after the event has ended
            Send CharDB 0x10EB NC_CHAR_EVENT_ATTENDANCE_LIST_DB_REQ { u32 nCharNo, tm tmEventStartDate = localtime(eventStart),
                     tm tmEventEndDate = localtime(eventEnd), i32 tConnect = time(NULL) }   # 0x50 bytes
    s.firstMapLogin = 0

CharDB 0x10EC NC_CHAR_EVENT_ATTENDANCE_LIST_DB_ACK { u32 nCharNo, u16 nError @+4, i32 tConnect @+6, u8 AttendanceNum @+0xA,
        tm AttendanceArray[28] @+0xB, u8 RewardNum @+0x3FB, u8 RewardList[RewardNum] @+0x3FC }      @ FUN_0040dfd0 → FUN_0043bab0
    nError ≠ 0x2C00: log "…Recv_NC_CHAR_EVENT_ATTENDANCE_LIST_DB_ACK : Error( %d )"; stop
    s = Clients_FindByCharNo(nCharNo) with CHARDATA and playingCharNo ≠ −1, else stop
    pkt 0x10ED NC_CHAR_EVENT_ATTENDANCE_LIST_CLIENT_CMD {
        tm tEventStart @0 = localtime(eventStart); u8 nCurIndex @0x24 = curDay
        u8 AttendanceArray[28] @0x25 = 0; for each of the AttendanceNum DB times t (Tm_MakeTimeLocal):
            if t >= eventStart: the day i < 28 with t < dayEnd[i] gets 1
        u8 RewardNum @0x41; u8 RewardList[RewardNum] @0x42 = copied }               # size 0x42 + RewardNum
    if curDay < 28:
        if AttendanceArray[curDay] == 1 (already marked today):
            if curDay == 27: send the list, no insert
            else from = dayEnd[curDay]                                                # wait for tomorrow
        else from = tConnect                                                         # time of the 0x10EB request
        if Attend_InsertPlayer(s, from) == 0: log "… Player Insert Fail nCharNo( %d )"; stop (no list)
        Send s pkt
    else (no running event):
        if EA_Event_Check_GetReward(pkt payload) == 1: Send s pkt                    @ FUN_0043ade0
        # otherwise the client gets nothing (event over, nothing left to claim)

EA_Event_Check_GetReward(this, p) → 1 if a reward can still be claimed                @ FUN_0043ade0
    for each week row i (weekRewards[i], AR_Count = week w):
        if all 7 days (w−1)·7 … w·7−1 of p.AttendanceArray are 1:
            if p.RewardNum == 0: return 1
            if p.RewardList[i] ≠ row.AR_ID … checked RewardNum times against the same element i   (original bug) W04-B65
                → return 1
    total = number of marked days
    best = the dayRewards row with the largest AR_Count ≤ total (none → return 0)
    return best.AR_ID not in p.RewardList ? 1 : 0                                     # lower day tiers are not checked
    a null row pointer → log "…EA_Event_Check_GetReward : Data NULL", return 0

CharDB 0x10EF NC_CHAR_EVENT_ATTENDANCE_CHECK_DB_ACK { u32 nCharNo, u16 nError }         @ FUN_0040e010 → FUN_0043a9b0
    nError == 0x2C08: s = Clients_FindByCharNo with CHARDATA and playingCharNo ≠ −1 →
        Send s 0x10F0 NC_CHAR_EVENT_ATTENDANCE_CHECK_CMD { u8 = never written (stale) }   (original bug) W04-B63
    else log "ERROR - cEvent_Attendance::Rece_NC_CHAR_EVENT_ATTENDANCE_CHECK_DB_ACK : Error( %d )"
        # 0x2C09 DB error, 0x2C0A already marked (D02 §12)

0x10F1 NC_CHAR_EVENT_ATTENDANCE_REWARD_REQ { u8 nIndex, u8 nRewardID }                  @ FUN_00418410 → FUN_0043aac0
    needs Client_CheckAlive only (no CHARDATA check: nCharNo = 0 without one)
    reply(code) = Send s 0x10F2 NC_CHAR_EVENT_ATTENDANCE_REWARD_ACK { u8 nIndex, u8 nRewardID, u16 nError = code }   @ FUN_0043a8f0
    if eventStart == 0: reply(0x2C12)
    row = reward with AR_ID == nRewardID, none → reply(0x2C12)
    AR_Type 0 (week w = AR_Count): nIndex must be w·7 − 1, else reply(0x2C13)
        checkStart = DayStart((w−1)·7); checkEnd = DayStart(w·7 − 1)
    AR_Type 1 (day count): nIndex must be 27, else reply(0x2C13); checkStart = eventStart; checkEnd = eventEnd
    other AR_Type → reply(0x2C12)
    checkStart < eventStart or checkEnd > eventEnd → reply(0x2C12)
    s.rewardPending == 1 → reply(0x2C12)                                              # one request at a time
    s.rewardPending = 1
    Send CharDB 0x10F3 NC_CHAR_EVENT_ATTENDANCE_REWARD_DB_REQ { u32 nCharNo, u8 nIndex, tm tmEventDay = localtime(DayStart(nIndex)),
             u8 nRewardID, tm tmCheckStartDay, tm tmCheckEndDay }                    # 0x72 bytes; the DB counts and gives the item (D02 §12)

CharDB 0x10F4 NC_CHAR_EVENT_ATTENDANCE_REWARD_DB_ACK { u32 nCharNo, u8 nIndex, u8 nRewardID, u16 nError }   @ FUN_0040e050 → FUN_0043ad90
    s = Clients_FindByCharNo(nCharNo) (no CHARDATA check); s.rewardPending = 0
    Send s 0x10F2 { nIndex, nRewardID, nError }                                       # D02 §12: 0x2C10 ok, 0x2C11 / 0x2C16 / … errors
```

With the 2016 data the only event ran 2015-11-09 … 2015-12-07, so in 2016 `curDay` is always 28: every first map login
still sends 0x10EB, and the client gets 0x10ED only while a week or day reward is unclaimed.

Client cross-check (GameFrameWork, `AttendCheckWin`; codes 0x2C00…0x2C16 have no entries in `client-error-codes.json`):
- 0x10ED (FUN_0049d030): `AttendCheckWin::SetEvtState(tEventStart, nCurIndex, AttendanceArray, RewardList, RewardNum)` and
  enables the attendance icon.
- 0x10F0 (FUN_004b39f0): announces "Attendance Checked!" and "Attendance has been confirmed", marks today; when the window
  reports all days done it requests the month reward itself (`NcCharEventAttendRewardReq` FUN_004a5d10 → 0x10F1
  { nIndex = 27, nRewardID = month reward id }); otherwise it activates the icon. The payload byte is not read.
- 0x10F2 (FUN_004bbc70): **nError is never read**: for any reply whose nRewardID is a known AttendReward row it marks the
  reward as taken and shows "%d week's attendance check reward has been received." (type 0) or "%d day's attendance check
  reward has been received." (type 1), also for 0x2C12 / 0x2C13 / DB errors (original bug) W04-B64.
- 0x10F5 (FUN_0049d080): `AttendCheckWin::ChangeDay(nChangeIndex)`. 0x10F6 (FUN_0049d0a0): resets the window to the new
  start date with no marks and deactivates the icon.

### 17.6 NPC schedule (`CNpcScheduleServer`, DAT_006c536c = WM +0x22B344)

Class and method names come from the log strings (`CNpcScheduleServer::enss_NPCStandStart` / `enss_NPCStandEnd` /
`enss_NPCStandState`). Event NPCs appear and disappear on a fixed cycle; the WM only keeps time and tells the zones
(and, for flagged rows, the players).

`NpcSchedule.shn` (the object starts with its SHN table; `NpcSched_Load` FUN_00457510 = `Shn_LoadChecked(…, 0x83, 0x2A)`,
fatal "*FATAL ERROR* - DATA FILE - NPC SCHEDULE DATA READ FAILED" in W01's FUN_00404100). Row: Mob_Inx char[32] @0,
NS_Year u16 @0x20, NS_Month u8 @0x22, NS_Day u8 @0x23, NS_Hour u8 @0x24, NS_Minute u8 @0x25, NS_CycleHour u16 @0x26,
NS_LifeHour u8 @0x28, NS_IsMsg u8 @0x29. **The 2016 table has no rows**, so none of this runs with the 2016 data.

Entries (+0x40 count, +0x44 array of 0x30 bytes, built by `NpcSched_BuildEntries` FUN_00457290 after loading):
+0 char mobIndex[32], +0x20 u8 standing, +0x24 time32 start, +0x28 time32 end, +0x2C u8 isMsg.

```pseudo
NpcSched_BuildEntries(this)                                                            @ FUN_00457290
    for each row: mobIndex = Mob_Inx; standing = 0; isMsg = NS_IsMsg
        start = mktime(NS_Year, NS_Month, NS_Day, NS_Hour, NS_Minute); end = start + NS_LifeHour hours
        while end <= now: start += NS_CycleHour hours; end = start + NS_LifeHour hours
        # NS_CycleHour = 0 with a past end never terminates: the WM hangs at startup (original bug) W04-B66

NpcSched_Tick(this)    (W01 main loop FUN_00406760, every pass)                         @ FUN_004574d0
    for each entry e: enss_NPCStandStart(e); enss_NPCStandEnd(e)

enss_NPCStandStart(e)                                                                  @ FUN_00456c50
    if e.standing or now < e.start: return
    Zones_Broadcast(0x086A NC_MISC_EVENTNPC_STANDSTART_ZONE_CMD { Name8 sMobIndex = e.mobIndex })   # fail → log "…Zone broadcast fail"
    if e.isMsg == 1: Clients_BroadcastInGame(0x086C NC_MISC_EVENTNPC_STANDSTART_CLIENT_CMD { Name8 sMobIndex }, skipArena = 0)
    e.standing = 1

enss_NPCStandEnd(this, e)                                                              @ FUN_00456e20
    if not e.standing or now < e.end: return
    Zones_Broadcast(0x086B NC_MISC_EVENTNPC_STANDEND_ZONE_CMD { Name8 sMobIndex })
    if e.isMsg == 1: Clients_BroadcastInGame(0x086D NC_MISC_EVENTNPC_STANDEND_CLIENT_CMD { Name8 sMobIndex }, 0)
    row = first table row whose Mob_Inx equals e.mobIndex (32-byte compare FUN_00456bb0)   # duplicates: the first row's
                                                                                       #   cycle / life is used (original bug) W04-B67
    (no row found → return with standing still 1)
    e.standing = 0
    while e.start <= now: e.start += NS_CycleHour hours                              # same endless loop for 0 (W04-B66)
    e.end = e.start + NS_LifeHour hours

enss_NPCStandState(this, zoneNo)   (W01 zone registration handler FUN_004283e0, new zone)   @ FUN_00457110
    for each entry with standing ≠ 0: SendPacket(zone, 0x086A { sMobIndex })        # zone missing → stop
    # clients that log in later get no 0x086C (it is a one-time announcement)
```

Zone side: 0x086A / 0x086B → `NPCManager.nm_StandNPC` start / end (Z01 §9, FUN_005a57e0 / FUN_005a5950). Client 0x086C
(FUN_004b6cc0) / 0x086D (FUN_004b6e10): looks the index up in MobInfo and announces "%s has appeared" / "%s has disappeared"
with the mob's name.

## 18. Original-server bugs

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
| W04-B22 | 0x703B | `nGameOptionDataCnt` unchecked; `n·3` bytes copied into the 8 KB stack packet before the size check | any player can crash the WM (n above ≈ 2730) | reject n above the option count / packet length |
| W04-B23 | 0x705F | forwarded as 0x7060 NC_CHAR_OPTION_LOGIN_BLOCKDATA_ERR_REQ, which the 2016 Character server does not register | the client's "option data broken" report has no effect | Character server resets the option blocks |
| W04-B24 | 0x7C04 | 0x7C05 code 0x0DA9 carries the remaining time in milliseconds; the client and the zone use seconds | the prison window shows 1000 × the remaining time | send remaining / 1000 |
| W04-B25 | 0x7C09 | 0x7C10 nMinute, sReason, sRemark never written (stale stack; asm checked) | GM alters store random minutes / text in the DB; 0x7C11 applies the random minutes to the online prisoner and shows them in 0x7C03 | copy the fields like 0x7C01 does |
| W04-B26 | 0x7C0F | err 0x0DB2 (DB read failed) does not register the prisoner in `CPrisonServer` though prisonmin ≠ 0 | no release timer this session; 0x7C04 answers 0x0DAA | start the timer from prisonmin regardless |
| W04-B27 | 0x7C11 → 0x7C0A | DB failure code 0x0DA7; the client's alter handler maps 0x0D87 instead | GM sees no message when the alter fails in the DB | send 0x0D87 or map 0x0DA7 in the client |
| W04-B28 | 0x8001 | one-hour limit inverted (`now − last ≤ 1 h` → forward; later → 0x0F42) | after the first report a player may report freely for an hour, then never again until relog (the DB's own limits still apply) | refuse when `now − last < 1 h` |
| W04-B29 | 0x8001 | `nChatLogSize` unchecked (≤ 65 535) copied into a ≈ 2.3 KB stack buffer | any player can crash the WM | cap at 2048 and at the packet length |
| W04-B30 | 0x8001 | refusals 0x0F47 (empty report type) and 0x0F48 (reporter in prison) have no client text | the report silently fails | use a code the client shows |
| W04-B31 | 0x9405 | the would-be master's confirm is taken without a pending request, without checking `UpCharID` against the sender, and without 0x9401's checks (level gap, rejoin / acceptance locks, own name) | any player can make any online player without a master its apprentice; only the DB's ring / capacity / has-master checks remain | keep the pending request (from 0x9401) and require the sender to be its `UpCharID` |
| W04-B32 | 0x9401, 0x9405, 0x941F → 0x9402 | refusals write only the code (and a zeroed name); UpInfo LogonInfo / Level / Flags, `ResetableDateTime` and the 36-byte `tm` are stale stack, except for 0x174A / 0x1750 | stack bytes on the wire; the client reads the date only for 0x174A | zero the packet |
| W04-B33 | 0x9406 | 0x9407 for "no master" (0x1758) leaves `nDelCmdType` unwritten | one stale byte; the client reads only the code on errors | write 0 |
| W04-B34 | `HP_ClearMaster` (0x9421, 0x9423, 0x9425, 0x9427) | the master name and handle are cleared but `masterCharNo` (session +0x1E1DC) and the dates stay | 0x9434 still reports the old master; 0x9401 refuses the old master as an apprentice (0x174E) until relog; enables W04-B35 | set masterCharNo to −1 |
| W04-B35 | CharDB 0x9425 | after clearing the apprentice's master, the member search matches the stale `masterCharNo` (index −1) and sends a second 0x9418 type 2 with the now empty name; DBError is not checked | the apprentice reads "…has deleted their character" twice, once without a name; a failed DB delete still ends the relations in memory | search members only (index ≥ 0) and check DBError |
| W04-B36 | OPTool 0x9425 | the member branch requires index == −1 (inverted) | masters keep a deleted apprentice in their list until relog; the apprentice gets the duplicate message | `idx != −1` |
| W04-B37 | 0x1074 level change → `HP_OnLevelChange` | called only when the levelling character has a master; the level-gap test uses the apprentice's cached copy of the master's level and runs only while the master is online | a master's apprentices never see its new level (no 0x9419); the gap test compares against the master's login-time level and can cut a relation that is still valid, or never test while the master is offline | notify apprentices regardless of having a master; test against the master's current level |
| W04-B38 | CharDB 0x942D | DBError (0x1752) not checked | the session's lock dates change although the DB kept the old ones; they revert at the next login | apply only on 0x1740 |
| W04-B39 | client 0xA41B…0xA41E | map names from the client are added to `g_IndunRank` (≤ 32); for a 33rd name the board / my-rank pointer is null and dereferenced | any client can crash the WM with 33 requests (3-s cooldown per tab) | look up without adding; refuse unknown maps |
| W04-B40 | client 0xA41B…0xA41E | the cooldown reply (0x3A01) writes only nErr into a 0x13 / 0x3E-byte packet | stale bytes on the wire (the client reads only nErr) | zero the packet |
| W04-B41 | CharDB 0xA414 | 0xA415 lists every in-game character of the world instead of the ranked ones; no size check (6 bytes each) | wrong ranking update request; a large world overruns the 0x2000-byte packet buffer *(inferred)* (dead in 2016, W04-B43) | list the ranked characters |
| W04-B42 | CharDB 0xA420 | minutes = seconds / 60 without % 60 | stored best times show minutes above 59 (dead in 2016) | `% 3600 / 60` as in `Client_UpdateMyRank` |
| W04-B43 | 0xA419 → 0xA41A, 0xA414…0xA420 | the WM asks the Character server for rankings (0xA41A) and expects 0xA414 / 0xA41F / 0xA420 / 0xA416 from it; the 2016 Character server handles and sends none of them (the zone's 0xA413 result is dropped there as well) | the instance-ranking window is always empty, no new-rank messages | implement the Character-server side or drop the feature |
| W04-B44 | `IndunRank_DailyReset` | the boards are cleared inside the loop over sessions (once per session, never with no session online); the new "current" date is the day after the one that starts | (dead data in 2016) wrong dates in the my-rank tab | clear once; use today's date |
| W04-B45 | 0xA408 | a missing destination zone is answered with nError 2, which zone A reads as "no instance yet" | the player gets the level menu, then the join fails with "RecallDisableField" | a distinct error code |
| W04-B46 | 0xA803 | `ChatRestrict_IsListedOrFull` returns one bool for "already listed" and "list full"; both answer 0x1C03, the 0x1C04 branch is dead | blocking an already blocked name shows "You can only block a maximum of 100 players…" | 0x1C04 "You already blocked this user." for a listed name, 0x1C03 only when full |
| W04-B47 | CharDB 0xA805 | success is relayed as 0x1C00 even when `ChatRestrict_AddOrUpdate` could not store the entry (list full, e.g. two adds in flight at 99) | client and DB list the name, the WM list does not; a later 0xA807 for it fails with 0x1C11 (silent) | check the result, or reserve the slot on 0xA803 |
| W04-B48 | 0xA803, CharDB 0xA805 | the refusal replies 0xA806 never write bIsGM / bIsDeleted | two stale stack bytes on the wire (the client ignores the entry on errors) | zero the packet |
| W04-B49 | `CGambleSystemServer_SendExchangeCoinInit` | if GBHouse row 0 is missing, nextReset stays 0 and is then advanced one day per main-loop pass from 1970 | thousands of 0xBC09 broadcasts with past dates, each resetting all exchanged counts (needs an empty GBHouse.shn) | do nothing while the init fails |
| W04-B50 | OPTool 0xD007 | deleting an active event (flag 1) does not send 0xD00C to the zones | the zones keep applying a deleted event until they restart | send 0xD00C as 0xD009 does |
| W04-B51 | OPTool 0xD009 | after a failed zone broadcast it replies 0x3221 and then 0x3220, and sets the flag anyway; 0xD005 also keeps the change after 0x3211 | the tool sees failure and success for one request; WM and zones disagree about the event | one reply; leave the record unchanged on failure |
| W04-B52 | OPTool 0xD001 | with no event, the single 0xD002 carries 0x554 stale stack bytes as event data | stack contents sent to the tool (nAllEventCnt 0 tells it to ignore them) | zero the packet |
| W04-B53 | OPTool 0xD005 / 0xD007 / 0xD009 | when the "not found" reply cannot be sent, the log line reads nEventNo through the vector's end pointer | reads past the last record; with an empty vector (null pointer) the WM faults, but only after a failed send to the tool | log the requested number |
| W04-B54 | client 0x085F (W01) → GM alert 0x200D | `Spam_AlertGMs` never writes itemLinkDataCount (payload byte 0); flag bits 1–7 stale | GM clients read `count × 0x67` bytes of item links past the end of the packet; garbage links or a client fault | write count = 0 |
| W04-B55 | `KQ_TickPurge` (OPTool 0x2811, late 0x580E) | the removal pass runs only when this pass marked a KQ; entries set to Status 0x0B elsewhere are not removed | deleted KQs stay in the array (300 cap) until another KQ is purged; after 0x2811 they also keep their map slots and joiners' joinedKQ, and the zones get no 0x5811 | remove every Status-0x0B entry each tick; 0x2811 should free slots and tell the zones like `SetDoneSkip` |
| W04-B56 | AccountDB 0x0839 (W01) / 0x083A | the munsang event chain is dead: the zone neither sends 0x0837 nor handles 0x083A; the Account server always answers nError 0x1545, so the 0x1541 announcement never runs | no effect in 2016 (feature switched off or half removed) | rebuild: drop it, or implement both ends |
| W04-B57 | `KQ_TickSchedule` | `KQ_NextOccurrences` loops adding NextStartDeleyMin until ≥ now; 0 never ends | a KingdomQuest.shn row with NextStartDeleyMin = 0 hangs the WM main loop (2016 data has none) | reject 0 at load |
| W04-B58 | `CKQServer::SetDoneSkip` reason 3 | uses WM texts #3 and #4, which MsgWorldManager.shn (3 rows) does not have | the team-imbalance cancellation notices are empty (and the in-game client ignores 0x580B anyway) | add the rows |
| W04-B59 | client 0x0840 | `nErrorDataCnt` unchecked; `6·n` bytes copied into the 8 KB stack packet (and read past the request) before the size check | any in-game client can crash the WM with n > 1351 | reject n above what the request length holds |
| W04-B60 | client 0x0846 | the new spam-filter values go to the DB only; the session copy (+0x1ECE0) keeps the old ones | every map change pushes the old settings back to the client (0x0845) until the next character login | update the session copy too |
| W04-B61 | CharDB 0x0864 / 0x0869 | on success with the target online, a missing zone link or a failed 0x0865 send returns before the GM reply | the ban/release is in the DB but the GM gets no answer and the online target is not muted / unmuted until relog | still answer the GM (with an error) |
| W04-B62 | client 0x085F | reporter == target is not refused; a failed `Spam_AddReport` is answered 0x2163 "already reported" | a player can report their own character; misleading text | refuse self-reports; distinct code |
| W04-B63 | CharDB 0x10EF → client 0x10F0 | the 1-byte payload of NC_CHAR_EVENT_ATTENDANCE_CHECK_CMD (an empty struct) is never written | one stale stack byte on the wire (the client ignores it) | write 0 |
| W04-B64 | 0x10F1 / 0x10F4 → client 0x10F2 | the client handler never reads nError: error replies (0x2C12, 0x2C13, DB errors) are shown as "reward has been received" and the reward is marked as taken | the player thinks a reward was given; the window state is wrong until the next 0x10ED | client: test nError; or the WM: send no 0x10F2 on errors |
| W04-B65 | `EA_Event_Check_GetReward` (after the event) | the claimed-week test compares `RewardList[weekRowIndex]` RewardNum times instead of scanning the list; only the highest reached day tier is checked | the list is resent for an already claimed week, or suppressed while a lower day tier is unclaimed | scan the whole RewardList for every row |
| W04-B66 | `NpcSched_BuildEntries` / `enss_NPCStandEnd` | the next-occurrence loops add NS_CycleHour until the time passes now; 0 never ends | a NpcSchedule.shn row with NS_CycleHour 0 and a past end hangs the WM (2016 table is empty) | reject 0 at load |
| W04-B67 | `enss_NPCStandEnd` | the cycle / life hours are taken from the first row with the same Mob_Inx | two schedules for the same NPC both use the first row's timing | use the entry's own row index |
| W04-B68 | `KQ_TickVote` → client 0x582D | one failure packet for every failed vote; the client's only text for it is "Voting has been cancelled because not enough players participated" | an outvoted ban request is reported as lacking participants | a separate code or packet for "majority against" |

(W04-B6 is reserved; not used.)

## 19. Not reconstructed / uncertain

- Prison: the zone answer 0x7C14 with err 0x0DC1 / 0x0DC2 tells the GM 0x0D88 but nothing undoes a partly done
  `so_Prison_Go`; 0x7C0C failure → `CPrisonServer_Remove` sends 0x7C12, whose effect on a player already in EldPri
  is Z08's (`so_Prison_End`). Z08 §12 describes 0x0DC0 as the default / not-found code; its code (FUN_005a4470)
  sets 0x0DC0 = ok, 0x0DC1 = charNo mismatch, 0x0DC2 = `so_Prison_Go` failed (for the sweep's knowledge file).
- 0x7C07 arrives while the client may already have left the character-select scene (it sends 0x7C06 together with
  scene state 0xF); the game scene has no 0x7C07 handler, so whether the minutes are ever used is open (C01).
- The client's 0x7C04 trigger (timer at 0 *(inferred)*) is not traced in the client.
- Old character options: why `m_pCharOptionDataBinary_*` (+0x670…+0x6A4) exist but are never filled (the type-1
  branch of `SendToClient_CharOptionData` is dead); probably left from before the Character server pushed the old
  blobs itself *(inferred)*.
- `KQ_AllocMaps` FUN_00453eb0 and its slot finder FUN_00451fd0 are read only as far as §6.2 (first free slot of each
  map row; `Clear` flags of KingdomQuestMap.shn not followed).
- KingdomQuest.shn NextStartMode / RepeatMode / RepeatCount / PlayerRepeat* / PlayerRevival* / DemandQuest / DemandItem /
  DemandMobKill / RewardIndex / ScriptLanguage are copied into PROTO_KQ_INFO for the zones; the WM itself does not
  enforce them (Z08 §4 for the zone side).
- 0x582A voter index: Ghidra shows the voter's joiner index as `extraout_EDX` after `KQ_IsVoteRunning`. The disassembly
  settles it: `mov %eax,%edx` at 0x452fee keeps `KQ_FindJoinerByName`'s result, `KQ_IsVoteRunning` (0x452d40–0x452d6b)
  never writes EDX, and `add %edx,%eax` at 0x45301e indexes the joiner array with it (no longer uncertain; kept here
  for the Ghidra artefact).
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
- Holy promise: the client text for 0x1741 (the DB's ring check, "User is already logged on.") does not fit; D04 noted the
  same mismatch. 0x9405 builds UpInfo's two lock dates from the apprentice's session; the DB ignores them (D04 §8), so
  the effect is nil, but the intent is unclear.
- Holy promise: `HP_LoadMembers` stops at 20 entries and then leaves `listLoaded` 0, so no 0x9414 list and no 0x9416
  login notice are sent that session; the DB caps members at 20 (`nMAXPROMISEMEMBER`), so this should not happen.
- 0xA401 for guild (1) and individual (2) instances: no member is told and the delete prompt goes nowhere (leader −1);
  whether the 2016 zones create such instances at all is Z08's.
- 0xA419 is accepted from the first zone only and never cleared on zone disconnect; harmless because `g_IndunMaps` is
  not read anywhere in the WM.
- `IndunRank_Insert*`: the very first entry of an empty list returns a rank from a local that Ghidra shows as unset
  when the loop does not run; not checked in the asm (dead in 2016, W04-B43).
- 0x3A01 cooldown text: TextData3 0x938F63DA is an empty string in the 2016 client table; whether a newer client fills it
  is open.
- Chat block (§14): the 0xA801 list is assumed to arrive before the first map login of the character (it is part of the
  0x1004 load stream, D02 §4 step 18) *(inferred)*; if it came later the client would get it only at the next map
  change. listFresh is not cleared at character login, so a stale flag from a previous character can only matter if
  the new count is non-zero, in which case the push is wanted anyway.
- `tExchangedCoinSumDate` (0x1004, §15.1): that the Character server counts only exchanges after this time is read
  from its name and D02, not from the GameDB / Character procedure bodies.
- GM events (§16): the OPTool side (what it shows for 0x3211 / 0x3221, whether it ever sends a flag other than 0/1)
  is not available; the zone's use of the records is Z08 §13 / Z09.

- Attendance (§17.5): an empty `AttendSchedule.shn` makes `Attend_LoadSchedule` return 0, which W01's loader treats as
  fatal ("*FATAL ERROR* - Attend Schedule"), so the WM needs at least one row; whether that was intended is unknown. How the
  Character server stores and counts the call dates (`usp_Attendance_*`, w00 backup only) is D02 §12's.
- Attendance: the client's choice of `nIndex` for week rewards (it must be the week's last day, w·7−1) and its "all days done"
  test (`AttendCheckWin` vtable +0x104) were not traced further than the handlers in §17.5.
- NPC schedule (§17.6): with no rows in the 2016 table, nothing about it can be checked against data or captures.
- Chat ban: `nChatBan` = 0x0FFFFFFF is a constant, not a time; that the zone and client treat any non-zero value as
  "banned" is read in Z02 §3.1, not in the client.

## 20. Coverage boundary

Found while reconstructing this item but documented elsewhere. The work W01 handed to W04 (dept-2 spam filter /
spammer handlers, attendance, NPC schedule) is done in §17.2–§17.6.

| Found (function / packet / table / behaviour) | Covered by | Argument |
|---|---|---|
| AccountDB 0x0839 handler FUN_00408050, zone 0x0837 relay FUN_0042b7d0 | W01 (plan scope row `0x0839` … `FUN_00408050`; W01 §7.6) | handler bodies are W01's; §17 here only settles C01's 0x083A question |
| Account server 0x0838 `fc_NC_MISC_EVENT_DONE_MUNSANG_WM2ACC` (account FUN_00402cb0) | D01 (scope row `0x0838` … `FUN_00402cb0`; D01-account.md) | Account-server binary |
| ServerParam `std::map` internals FUN_00459d00, FUN_00459220, FUN_004590b0, FUN_004599a0, FUN_00459a80; `LogLevel` FUN_00407ae0 | W01 (plan: "startup/config"; `ServerParam_GetInt` and `LogLevel` are W01 names) | library code behind W01 helpers; behaviour summarised in §1.2 |
| `Party_IsConfirmed` FUN_00464d50 (party chat) | W02 (`W02.json` names it; plan title "party and raid") | party state is W02's |
| WM data loader FUN_00404100 (all SHN tables), `WM_GetMsg` table object | W01 goal "startup/config" — **not covered by W01-core** (W01 is done and never cites it): W05 (`docs/plan/items/W05.md`, added by W04) | only the KQ, SpamerReport, GBHouse and MsgWorldManager rows are used here and are documented in §2.5, §6.1, §6.2, §15.1 |
| client-SHN name list FUN_0045d8c0 (49 file names: Abstate.shn … ChargedDeletableBuff.shn) | W01 goal "startup/config" — **not covered by W01-core** (W01 is done and never cites it): W05 (`docs/plan/items/W05.md`, added by W04) | no caller in the export (constructor of a global); not reached from any W04 handler |
| 0x0849 date/time broadcast FUN_00437e30 (main loop, once a minute) | W01 goal "Reconstruct the WM process" — **not covered by W01-core** (W01 is done and never cites it): W05 (`docs/plan/items/W05.md`, added by W04) | main-loop service, not part of a W04 subsystem |
| session teardown callers FUN_00437660, FUN_00437fd0, FUN_00438630 (→ session destructor FUN_004352e0), FUN_00438a60 (→ reset FUN_00434530) | W01 goal "session lifecycle" — **not covered by W01-core** (W01 is done and never cites it): W05 (`docs/plan/items/W05.md`, added by W04) | they reach W04 code only through the session destructor (`ChatRestrict_Destroy`, §14.1) |
| zone handlers of 0x580D / 0x580F / 0x5811 (zone FUN_00497790 / FUN_00499240 / FUN_004972c0) and the KQ maps | Z08 (scope rows `0x580d`, `0x580f`, `0x5811`) | zone side of the KQ |
| zone senders of 0xA401 / 0xA403 (`mc_Routine` FUN_004868d0 / FUN_00486710, `mc_AllDropFilm` FUN_00485290) | Z14 (plan goal: "`mc_Routine` (empty-instance timeout …), films (`mc_PlayAllFilm`, `mc_AllDropFilm`)") | zone instance logic; Z08 (done) does not cite them (noted in `docs/knowledge/W04.md`) |
| zone handlers of 0xD00B / 0xD00C GM events (zone FUN_0046ddf0 / FUN_0046dae0) | Z08 §13 | zone side of §16 |
| Character-server procedures behind 0x5410, 0x7C0B, 0x9420…0x9443, 0xA800…0xA80C, char options | D04 (plan title: "social, guild, quests, skills") and D02 | DB side; this doc cites D04 where it relies on it |
| client handlers of every client-facing packet here | C01 (inventory) | cited per packet; texts from `client-error-codes.json` |
| zone `&releasechatban` command (in the zone's GM-command parser FUN_00425b70, string 006a8d3c) and its 0x0866 send helper FUN_00421a60, zone 0x0865 handler FUN_005a5710 | Z11 (plan: "GM ampersand (&) commands"); Z01 §9 | zone GM command and zone message handler |
| zone 0x086A / 0x086B handlers FUN_005a57e0 / FUN_005a5950 (`nm_StandNPC`) | Z01 §9 | zone side of §17.6 |
| zone 0x1120 NC_CHAR_SUPPORT_REWARD_CMD handler FUN_005a5c70 | Z07 §1.2 | zone side of `Session_SendSupportReward` (§17.5) |
| Character-server handlers / procedures for 0x0841, 0x0844, 0x0847, 0x0863, 0x0868, 0x10EB, 0x10EE, 0x10F3 | D02 §4, §5, §9, §12 | DB side of §17.2–§17.5 |
| W01 callers of §17: 0x180C map-login-done FUN_0042d8d0, zone registration FUN_004283e0, CharacterLogout FUN_00436d50, main loop FUN_00406760, loader FUN_00404100 | W01 (W01-core §5.4, §7.1, §7.3) for the first three; main loop and loader: W01 goal "startup/config" — **not covered by W01-core** (W01 is done and never cites it): W05 (`docs/plan/items/W05.md`, added by W04) | they only call the W04 functions named in §17 |
