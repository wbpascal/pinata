# Zone server: movement, chat, emotes, sight, NPC menus, actions, scenario (Z02)

Source: `Files/Server/2016/w00_Zone00/5ZoneServer2.exe`, export `re-data/exports/zone`. Each block cites the
function it was reconstructed from (`@ FUN_xxxxxxxx`); view one with
`python3 -I tools/protocol-re/clean.py re-data/exports/zone tools/protocol-re/names/zone <addr>`.
Function names are the original profiler strings (Z01 names file) unless marked *(ours)*; Z02's additions are in
`tools/protocol-re/names/zone/Z02.json`. Opcode names are the official ones (`docs/protocol/opcodes.json`,
mostly *(pdb2017)*). Packet layouts: [`../../protocol/packets-zone.md`](../../protocol/packets-zone.md) and
[`../../protocol/annotations/Z02.json`](../../protocol/annotations/Z02.json). Core facts (objects, handles, broadcast,
send primitives, player modes) are in [`Z01-core.md`](Z01-core.md) and `docs/knowledge/Z01.md`; this file does not
repeat them. Facts for other items: `docs/knowledge/Z02.md`.

---

## 1. Conventions used in this file

```pseudo
handler(p = ShinePlayer, pkt, len, hnd)          # ClientSession_zbs_Parsing @ FUN_004fb9f0 calls
                                                 #   table[cmd][dept](ecx = player, pkt, len, session arg)
    pkt points at the opcode; payload offset N = pkt + 2 + N
    len = packet length; hnd = the player's own object handle (the third stack argument; every handler that
          broadcasts "me" writes it as the handle field, e.g. 0x2004/0x2009/0x2025)
```

- **Mode masks** (Z01-core §4.3): `0x46` = modes {1, 2, 6}, `0x7E` = {1…6}, `0x06` = {1, 2}, `0x4E` = {1, 2, 3, 6}.
  A handler whose mask does not match the player's mode returns silently (no reply) unless noted.
  Client view of the mode (`Char::SetMode`, client @ FUN_0042f440): 2 sets `StandMode = STAND_MODE_COMBAT`,
  3 calls `Char::OnDead`. So mode 1 = normal stand, 2 = combat stand, 3 = dead *(pdb2017 enum `Char::StandMode`,
  confirmed by the 2016 client code)*.
- **Time.** `g_Now` (DAT_14d41a70) counts **tenths of a second** (`elapsed_ms * 10 / 1000`, set every loop in
  `ZoneServer::zs_mainthreadfunction` @ FUN_005aca30). Every "×10" below converts seconds into g_Now units. (Z01 calls it a millisecond
  clock; that is wrong, see knowledge Z02 §1.)
- **Character brief block.** `player+0x7f32` points at the payload of the player's own `NC_BRIEFINFO_LOGINCHARACTER_CMD`
  (0x1C06, 0xEB bytes in 2016): +0 handle, +0x52 polymorph, +0x54 `emoticon` (STOPEMOTICON_DESCRIPT: u8 id,
  u16 frame), +0xc6 `sAnimation[32]`. The packet object itself is at `player+0x7e34` and is what other clients get
  when they first see the player (§5). Changing these bytes changes what newcomers see.
- **Broadcast "to sight"** = `AxialListPacketBroadcast(&g_buf, n)` + `so_AllOfRange_Class1(p, stamp, p.pos, …)`
  (@ FUN_0054bc80), receivers filtered as in Z01-core §3.2. Shout uses `so_AllInMap1` (whole map, §3.2).
- **Common player calls** (ShinePlayer vtable byte offsets; names *(ours)* unless a string gives one):

| Slot | Function | Meaning |
|---|---|---|
| 0x304 | `so_SendProtocol(dept, cmd)` FUN_0054ef70 | send an empty packet to the player |
| 0x308 | `so_SendErrorCode(dept, cmd, code)` FUN_0054f050 | send `{u16 code}` |
| 0x8d0 | `CancelOnAction` FUN_0055a310 *(ours)* | cancel item cast (+0x2a760), pet/tame cast (+0x5cf8), guild-tournament flag capture (+0x5e06 → broadcast 0x74CC `{u16 0x1B51, u16 handle}`), animation (+0x2aacc → broadcast 0x2075 ANIMATION_STOP `{u16 handle, char[32] ""}`); each sends 0x2048 NC_ACT_CANCELCASTBAR |
| 0x514 / 0x518 | GetWalkSpeed / GetRunSpeed | |
| 0x660 | `MoveStart(to, speed, kind, reverse)` FUN_00555970 *(ours)* | direction byte from (to − pos), `MoveManager_mm_MoveStart(p+0x18c, …)` |
| 0xa48 | `so_mobile_StopHere` FUN_0045a0c0 | stop the mover, broadcast 0x2013 SOMEONESTOP `{u16 handle, u32 x, u32 y}` (server position) |
| 0xa4c | `so_ply_SendMoveFail` FUN_00458340 | send 0x201B MOVEFAIL `{u32 back.x, u32 back.y}` = server position |
| 0xa50 | `smo_ply_ReinforceStopHere` FUN_00456ef0 | |
| 0xb24 | `IsInGambleGame` FUN_00615ea0 *(ours)* | +0x2aa78 ≠ 0 (1 = tai-sai dice seat, 2 = slot machine; set by the gamble handlers) |
| 0xc74 | `GetRiddenMover` FUN_0055a7a0 *(ours)* | if +0x2a77c == 2: +0x2ab14 (the ShineMover the player rides), else null |
| 0xf20 | FUN_0055d5a0 | flag byte +0x1e78 bit 5 *(meaning not identified; blocks walk/run like bit 2)* |
| 0xf44 | `smo_StopBlockCheck` FUN_004bee40 | if the current cell is blocked, snap back to the last good position (+0x2a918/+0x2a91c) and stop |

`+0x1e78` is a status-flag byte of the object: bit 2 is set by the Fear abnormal state
(`SubAbnormalStateFear::sasa_Routine` @ FUN_00406e30); moves are refused while it is set.

---

## 2. Movement

The client moves itself and reports; the server checks distance and map cells, keeps its own mover
(`MoveManager` at p+0x18c) running at the server-side speed, and broadcasts to everyone in sight.

```pseudo
CellFree(p, xy):                                         @ FUN_00456780
    return MapBlockInformation.mbi_OccupCellCheck(p.field.block (+0x14), xy.x, xy.y, 1)
Near(p, xy):                                             @ FUN_004567a0
    return dist²(p.pos, xy) < 40001                      # 200 units
LineBlocked(p, a, b, need=2):                            @ FUN_00456a70
    walk the straight line a→b one unit at a time along the longer axis; a step counts as blocked when its cell
    is occupied and the cells 10 units to both sides are blocked too (FUN_0049df00 / FUN_0049df70);
    return true once `need` consecutive blocked steps are found
SetPosition(p, x, y):                                    @ FUN_00452a70
    if (x, y) inside the field (FUN_00461d80: 0 ≤ x < field.w, 0 ≤ y < field.h):
        p.pos = (x, y); re-sort p in the field's two coordinate lists (SlantedCoordList cn_Rearrange)
    p.vt[0xa38](7, 0, 0)                                 # script/quest hook "moved" (inferred)
ClearEmoticon(p):  p.brief.emoticon = {0, 0}             # after every movement broadcast (globals DAT_132728f4/f6 are never written = 0)
RememberMove(p, cmd, payload22):                         @ FUN_00434ae0
    p+0x168 = cmd; p+0x16a = the 22 payload bytes        # replayed to newcomers, §5 (FUN_005555e0)
```

### 2.1 0x2003 NC_ACT_WALK_REQ / 0x2005 NC_ACT_RUN_REQ `{ u32 from.x, from.y, to.x, to.y }`

```pseudo
@ FUN_004571a0 (walk) / FUN_00457380 (run) — identical except the reply opcode
    if mode ∉ {1,2,6} or flag +0x1e78 bit 2 (feared) or vt 0xf20: return
    if no field: log "…_WALK_REQ : Invalid map"; return
    old = p.pos
    SetPosition(p, to.x, to.y)                           # no distance or cell check at all (original bug) Z02-B1
    broadcast to sight 0x2004 NC_ACT_SOMEONEWALK_CMD / 0x2006 NC_ACT_SOMEONERUN_CMD
        { u16 hnd, u32 old.x, old.y, u32 p.pos.x, p.pos.y }        (18 bytes)
    ClearEmoticon(p)
```

The 2016 client accepts 0x2004/0x2006 and does nothing with them (C01: `break;` in GameFrameWork). No client
code was checked for who still sends 0x2003/0x2005; the normal path is 0x2017/0x2019 *(inferred)*.

### 2.2 0x2017 NC_ACT_MOVEWALK_CMD / 0x2019 NC_ACT_MOVERUN_CMD `{ u32 from.x, from.y, to.x, to.y }`

```pseudo
@ FUN_00457c60 (walk) / FUN_00457fd0 (run)
    if mode ∉ {1,2,6}: return
    mover = p.GetRiddenMover()                           # passenger/driver of a ShineMover
    if mover:
        ok = mover.vt[0xccc (walk) | 0xcd0 (run)](&from, p)   # ShineMover @ FUN_00459b00 / FUN_00459d80: the mover moves
        if !ok: SendMoveFail(p)
        return
    if p.petSystemState (+0x2ab60) == 1: sp_PetSystem_CancelCasting(p)    @ FUN_004d23a0 (sends 0x2048)
    if feared (+0x1e78 bit 2) or vt 0xf20 or (p.mover.active (+0x1ac) and p.mover.state (+0x18c) == 3): return
    if no field: log "…_STOP_REQ : Invalid map" (sic) (original bug) Z02-B13; return
    run only: if mode == 6 and +0x2a778 ≠ 0: return       # mode 6 with that flag ignores run requests
    p.CancelOnAction()                                    # vt 0x8d0, see §1
    remove the "walk" abstate element (AbstateElementInObject.aeo_Walk / aeo_Run) from p's abstate list (p+0x1cc+0xcb0)
    if the normal-attack state (+0x2a784 .state ∈ {2,3}) and +0x2a7dc == 0: smo_BashStop(p); clear the attack tick (+0x173d0)
    sp_SkillShiftCancel(p)
    speed = walk ? GetWalkSpeed() : GetRunSpeed()
    if from == to: StopBlockCheck; SendMoveFail; return
    if !Near(p, from) or !CellFree(p, to) or !CellFree(p, p.pos): StopBlockCheck; SendMoveFail; return
    if LineBlocked(p, p.pos, to, 2):                     StopBlockCheck; SendMoveFail; return
    p.MoveStart(to, speed, walk ? 1 : 2, 0)              # vt 0x660; server mover runs to `to`
    p.vt[0xd4c](1) = SendSpeedIfChanged(p, force=1)      @ FUN_00459540: if speeds changed or forced:
                                                         #   send 0x203E NC_ACT_MOVESPEED_CMD { u16 walkSpeed, u16 runSpeed } to p
    payload = { u16 p.handle, u32 p.pos.x, p.pos.y, u32 to.x, to.y, u16 speed, u16 moveattr (bit 0 cleared) }   # 22 bytes
    RememberMove(p, walk ? 0x18 : 0x1a, payload)
    broadcast to sight 0x2018 NC_ACT_SOMEONEMOVEWALK_CMD / 0x201A NC_ACT_SOMEONEMOVERUN_CMD (payload)
    ClearEmoticon(p)
```

Note: `from` is only used for the 200-unit sanity check; the broadcast `from` is the server's position. The
`moveattr` word is left as it was in `g_buf` except bit 0 *(the other bits are stale buffer content)* (original bug) Z02-B2.

Client: `On_NC_ACT_SOMEONEMOVEWALK_CMD` (client @ FUN_004a12a0) ignores packets about the main character, asks for
brief info of unknown handles (§5), and plays the walk at `speed` (scaled against the distance); `On_NC_ACT_MOVEFAIL_ACK`
(@ FUN_00499b00) puts the main character back at `back` unless it is sinking (`MainChar::PositionSinkTest`).

### 2.3 0x2012 NC_ACT_STOP_REQ `{ u32 loc.x, loc.y }`

```pseudo
@ FUN_00456ff0
    if mode ∉ {1,2,6}: return
    if no field: log "…_STOP_REQ : Invalid map"; return
    if p.mover.active and p.mover.state == 3: return
    mover = p.GetRiddenMover(); if mover: mover.vt[0xcd4](&loc, p) (@ FUN_00456e30); return
    MoveManager.mm_Step(p+0x18c, 1)                      # advance the server mover to "now"
    if dist²(p.pos, loc) < 40001 and CellFree(p, loc):
        so_mobile_StopHere(p)                            # vt 0xa48: broadcast 0x2013 { hnd, server pos }
    else:
        StopBlockCheck(p); SendMoveFail(p)               # 0x201B back = server pos
```

The client's `loc` is never written into the position: the server keeps the position its own mover reached.

### 2.4 0x2024 NC_ACT_JUMP_CMD (no payload)

```pseudo
@ FUN_0045a250
    if mode ∉ {1,2,6}: return
    p.CancelOnAction()
    broadcast to sight 0x2025 NC_ACT_SOMEEONEJUMP_CMD { u16 hnd }
    for every Lua jump trigger registered for p (FUN_00541470(&DAT_0d5745b8, p)): LuaFuncTrigger_TriggerJump.tj_PullTheTrigger(trigger, p)
    ClearEmoticon(p)
```

### 2.5 0x2008 NC_ACT_CHANGEMODE_REQ `{ u8 mode }`

```pseudo
@ FUN_00457560
    if p.mode ∉ {1,2}: return
    if no field: log "…Invalid map"; return
    p.CancelOnAction()
    if mode ∉ {1, 2}: log "…Try to set invalid mode" (mode); return
    p.mode = mode                                        # 1 = normal, 2 = combat stance
    if p+0x292d7: copy the saved 0x2b shape bytes (+0x292ac) back into p.brief.shapedata (+0x25); clear +0x292d7
                                                         # undo a temporary look (tent/camp shape, §7) (inferred)
    broadcast to sight 0x2009 NC_ACT_SOMEONECHANGEMODE_CMD { u16 hnd, u8 mode }
    ClearEmoticon(p)
```

Client `On_NC_ACT_SOMEONECHANGEMODE_CMD` (@ FUN_004a1500): `Char::SetMode(mode)` if it differs.

---

## 3. Chat

### 3.1 0x2001 NC_ACT_CHAT_REQ `{ u8 itemLinkDataCount, u8 len, u8 content[len], item links[itemLinkDataCount × 0x67] }`

```pseudo
@ FUN_0045a400
    if mode ∉ {1..6}: return
    if no field: log; return
    if sp_AmpersandCommand(p, hnd, payload): return      # "&…" admin command, §3.3
    if field.FieldList.Chat (+0xc → +0xa0) == 0: return  # map forbids chat (World/Field.txt column "Chat")
    if SpamCheck(p): return                              # §3.4
    gmBlocked = p.chatBlockUntil (+0x2aa54) ≠ 0          # FUN_00560a30; set by WM 0x0865 (Z01)
    target = gmBlocked ? hnd : 0xFFFF
    so_Chat(p, target, content, len, chatwin = 1, itemLinkDataCount)     # vt 0x530, below
    pet keyword: if !gmBlocked and p.petSystemState ∈ {5,6} and p.petHandle (+0x2ab84) ≠ -1
                 and the pet name (+0x2ab88, 16 chars) has > 3 characters and occurs in content:
        p.petCalled (+0x2ab68) = 1                       # the pet reacts on its next routine ("cPet_IsMasterCalling" @ FUN_005e9320)
    FUN_005cc2a0(p+0x29638)                              # reset a counter pair and raise event 0x29 in the class/shape block (inferred: achievement/stat hook)
    for every Lua chat trigger registered for p (FUN_00541470(&DAT_0d5745c8)):
        LuaFuncTrigger_TriggerChat.tc_PullTheTrigger(trigger, p, content (≤ 255 chars, NUL-terminated))

so_Chat(obj, target, content, len, chatwin, nLinks):     @ FUN_00458c90 (ShineMobileObject::so_Chat)
    0x2002 NC_ACT_SOMEONECHAT_CMD {
        u8 itemLinkDataCount = nLinks, u16 handle = obj.handle, u8 len,
        u8 flag = GMColor (bit 0, obj+0x7fb8) | chatwin << 1,
        u8 nChatFontColorID   = (+0x2a5c9 or +0x2a5cb owned) ? +0x2ab5d : 0,     # vt 0xe2c
        u8 nChatBalloonColorID = (+0x2a5ca or +0x2a5cb owned) ? +0x2ab5e : 0,    # vt 0xe34
        u8 content[len], item links[nLinks × 0x67] }
    if target == 0xFFFF: broadcast to sight
    else: send only to GetObject(target)                 # a GM-muted player sees his own line, nobody else does
```

### 3.2 0x201E NC_ACT_SHOUT_CMD `{ u8 itemLinkDataCount, u8 len, u8 content[len], links }`

```pseudo
@ FUN_00458e80
    if mode ∉ {1..6}: return
    if no field: log "…SHOUT_CMD: Invalid map"; return
    require field.FieldList.Shout (+0xa1) ≠ 0
        and p.level > g_ShoutLevel (DAT_0da5047c)        # 0x0830 NC_MISC_SERVERPARAMETER_ACK.shoutlevel (Z01)
        and p.nextShout (+0x2a7d8) < g_Now
        else return (silently)
    p.nextShout = g_Now + g_ShoutDelay (DAT_0da50480) × 10        # shoutdelay is in seconds
    if SpamCheck(p): return
    target = p.chatBlockUntil ≠ 0 ? hnd : 0xFFFF
    smo_Shout(p, target, "", content, len, nLinks)       # vt 0x534
    FUN_005cc2d0(p+0x29638)                              # count shouts (+0x738, 64-bit), event 0x2a (inferred: statistic)

smo_Shout(obj, target, speaker, content, len, nLinks):   @ FUN_00459080
    if speaker == "": speaker = obj.name (vt 0x56c = +0x7f41)
    0x201F NC_ACT_SOMEONESHOUT_CMD { u8 itemLinkDataCount, char speaker[20], u8 flag = GMColor (bit 0), isMob (bit 1) = 0,
                                     u8 len, u8 content[len], links }
    target == 0xFFFF ? so_AllInMap1(obj, broadcast, 1)   # the whole map instance, not just sight
                     : send to GetObject(target)
```

### 3.3 Admin ("&") commands

```pseudo
sp_AmpersandCommand(p, hnd, chatPayload):                @ FUN_0041a060
    if content[0] != '&': return false
    if len > 100: len = 100; cut the text
    so_ply_AdminCommand(p, content, len)                 @ FUN_00427a40 (vt 0x964)
    return true                                          # the line is never shown as chat

so_ply_AdminCommand(p, text, len):
    parse text into AmpCmdArgument (command word + arguments)
    run it through the command list DAT_0087c770 (FUN_00487c50): each AmpersandCommandElement checks the word and
        its own admin level and executes
    if no element took it and p.adminLevel (vt 0x4d4 = +0x7fa1) ≠ 0:
        reply "Invalid command : %s" with AmpersandCommand.ac_wall (system line to p)
```

The commands are the 119 `AmpersandCommand_ac_*` functions in the names file (wall, Hide, Show, Dimension,
AdminLevel, LinkTo, MakeItem, ClearInventory, summonplayer, KickOutPlayer, NoticeZone, GMChat, KeepFromChat, BonusExp,
LevelUp, GetMoney, KingdomQuest, Wedding*, TaiSai_*, …). Each command's behaviour is not reconstructed here.

### 3.4 Spam filter

Tables: `SpamerPenaltyRule.shn` `{ u16 SecondRule = 3000, u8 RepeatRule = 3 }` and `SpamerPenalty.shn`
`{ u8 PenaltyLv, u16 ChatBlockTime, u16 ProbateTime }` (levels 1–10: 10/15 s … 3600/5400 s), loaded by
FUN_005897f0 into `BinaryDataBox<SpamerPenaltyRule>` DAT_13287320.

```pseudo
SpamCheck(p):                                            @ FUN_005649d0  → true = drop the line
    if g_Now < p.spamBlockUntil (+0x2aa34):
        SendSpamBlockTime(p); return true
    ring = p+0x2aa2c (RepeatRule entries), idx = p+0x2aa30
    ring[idx] = g_Now; idx = (idx + 1) % RepeatRule
    if ring[oldest] ≠ 0 and g_Now ≤ ring[oldest] + SecondRule/100:   # RepeatRule lines within 3.0 s
        Penalize(p, g_Now); return true
    return false

Penalize(p, now):                                        @ FUN_00562ab0
    level = 1
    if now < p.probationUntil (+0x2aa38):                # repeat offender: climb the levels
        level = the first level L (from 1) for which the summed ProbateTime of levels < L covers
                (probationUntil − spamBlockUntil); capped at the row count
    p.spamBlockUntil = now + ChatBlockTime[level] × 10
    p.probationUntil = p.spamBlockUntil + (ProbateTime[level] + sum) × 10
    clear the ring
    SendSpamBlockTime(p)

SendSpamBlockTime(p):                                    @ FUN_005607a0 ("ShinePlayer::sp_SpamSendBlockTimeToClient")
    left = spamBlockUntil − g_Now (tenths); seconds = left < 10 ? 1 : left / 10   (0 if already over)
    send 0x0848 NC_MISC_CHAT_BLOCK_SPAMER_BLOCKTIME_CMD { u32 seconds }
```

Client 0x0848 (@ FUN_004b2b50) shows "Repeating same message on chatting window will not allow to chat for %d m…".
The spammer report paths (`sp_SendSpamerDataToCharDB`, `sp_SendSpamerToWM`) are not reached from these handlers.

Whispers (0x200C) and party chat (0x2014) go to the WM (W04), not to the zone.

---

## 4. Emotes

`ActionViewInfo.shn` (`g_ActionViewInfo` DAT_133880c0; PDB row struct `ActionViewInfo`: `nIndex` u8 @0,
`eActionType` @0x65 (`ActionType`: 0 DEFAULT, 1 EMOTION, 2 CHARGED), `IsDance` @0x71). Rows 6–26 are free
emotions (sit, stand, greeting, … dance), 31–105 are charged (bought) dances with `IsDance = 1`.

```pseudo
0x2020 NC_ACT_EMOTICON_CMD { u8 emoticonid }:            @ FUN_00458740
    if p.IsInGambleGame(): SendMoveFail(p); return       # vt 0xb24; the client snaps back
    row = first ActionViewInfo row with nIndex == emoticonid
    if row and row.eActionType == 2 (CHARGED): return    # charged emotes only through items (0x2067, §9.3)
    if row: sp_DoEmotion(p, hnd, emoticonid)             # vt 0xa40
    (unknown id: ignored)

sp_DoEmotion(p, hnd, id):                                @ FUN_00458860
    if mode ∉ {1,2,6}: return; if no field: log; return
    p.CancelOnAction()
    broadcast to sight 0x2021 NC_ACT_SOMEONEEMOTICON_CMD { u16 hnd, u8 emoticonid }
    p.brief.emoticon = { id, frame 0 }
    p.vt[0xa38](4, id, 0)                                # script/quest hook "emotion" (inferred)
    if p.petSystemState ∈ {5,6} and the row has IsDance == 1:
        p.petDanceUntil (+0x2abdc) = g_Now + 600; +0x2abe0 = 600; +0x2abe4 = row index
        # so_Routine (@ FUN_0056c790) makes the pet dance (FUN_004d2470(p, 1)) while the player still shows that emote

0x2022 NC_ACT_EMOTICONSTOP_CMD { u8 emoticonid, u16 emoticonframe }:   @ FUN_00458a70
    if mode ∉ {1,2,6}: return; if no field: log; return
    if no ActionViewInfo row has nIndex == emoticonid: return
    broadcast to sight 0x2023 NC_ACT_SOMEONEEMOTICONSTOP_CMD { u16 hnd, u8 emoticonid, u16 emoticonframe }
    p.brief.emoticon = { emoticonid, emoticonframe }     # newcomers see the player frozen in that frame
```

---

## 5. Sight and brief info (what other players see)

Every object keeps a ready-made "appear" packet: player `+0x7e34` (0x1C06 LOGINCHARACTER, payload = the brief
block at +0x7f32), mob/NPC/servant `+0x1ecc`, drop item / magic field `+0x167`, door `+0x1ea8`, mini-house `+0xc0a8`.
`obj.vt[0x4c8](receiver)` = `so_SendMyBriefInfo` sends it:

```pseudo
ShinePlayer.so_SendMyBriefInfo(me, rcv):                 @ FUN_005597c0
    (logs "…so_SendMyBriefInfo" if rcv == me)
    if me.mode ≠ 0 and !rcv.HideExceptMe (vt 0x79c = +0x5cb8 bit 3): rcv ← me.briefPacket (0x1C06)
    if !rcv.HideExceptMe: me.vt[0xa10](rcv) = ResendLastMove   @ FUN_005555e0
        if me.lastMoveCmd (+0x168) ≠ 0: rcv ← (8<<10 | lastMoveCmd) { 22 remembered bytes, from = me's current pos }
        # a newcomer sees a moving object continue its move
ShineMob/NPC/Servant.so_SendMyBriefInfo(me, rcv):        @ FUN_00556590
    if rcv hides others and me is not an NPC (type 4): only if me has a link to a pet/owner row with +0x52 == 1
    rcv ← me.briefPacket (+0x1ecc); ResendLastMove; if me+0x22ec: rcv ← 0x748D { u16 handle, u32 guildNo }  # mb_SendMyGuildInfo
others (item, door, mini-house, magic field):            rcv ← their packet (FUN_00555280 / FUN_00555b60 / FUN_00555e10)
```

### 5.1 0x1C01 NC_BRIEFINFO_INFORM_CMD `{ u16 nMyHnd, u16 ReceiveNetCommand, u16 hnd }`

This is the client asking for an object it does not know. The 2016 client calls it from
`GameFrameWork::GetCharByHandle` (client @ FUN_004c8e60): whenever a packet names a handle the client has no object
for, `GameFrameWork::NcBriefInfoCmd` (@ FUN_0049e710) sends 0x1C01 `{ own handle, opcode of the packet that named
it, unknown handle }` (rate-limited by `AddAskServerInform`). Together with the move broadcasts this is how objects
that walk into sight appear.

```pseudo
@ FUN_0043e460
    if mode ∉ {1..6}: return
    obj = GetObject(hnd)
    if !obj: log "…sp_NC_BRIEFINFO_INFORM_CMD - client hnd[nMyHnd] server hnd[p.handle] command[cmd] department[dept] get handle[hnd]"; return
    obj.so_SendMyBriefInfo(p)                            # obj's appear packet (+ last move) to p
    AbstateList(buf DAT_0074e030, p)                     @ FUN_0043cc00:
        0x1C19 NC_BRIEFINFO_ABSTATE_CHANGE_LIST_CMD { u16 handle = p.handle, u8 count, ABSTATE_INFORMATION[count] (12 bytes) }
    if count ≠ 0: obj ← that packet                      # as read: the *requester's* abstates go to obj (a player) (original bug) Z02-B3
```

### 5.2 Brief-info exchange (login, regen, teleport)

```pseudo
so_ExchageBriefInfo(other, me, limit) — map iterator callback   @ FUN_00441460
    skip objects of kind 0; kind 2: skip if other's own sight limit (FUN_0043c330) < limit; kind 3: skip if g_SightLimit < limit
    if other.mode ≠ 0:
        if other has an aggro/target list (vt 0xa18 / 0x7b4): remember it (DAT_0da29340)
        by other's type:
          1 drop item        → BriefInfoExchangeItem.bixi_Exchange
          2 player, 8 bandit → BriefInfoExchangeCharacter.bixc_Exchange + BriefInfoExchangeAbstate
          3 mini-house       → bixmh_Exchange
          4 NPC, 5 mob, 10 servant → bixm_Exchange + abstates
          6 magic field      → FUN_004402d0
          7 door → bixd;  9 effect → bixe;  11 mover → bixmv + abstates;  12 pet → bixp
          else log "…so_ExchageBriefInfo : INVALID TYPE"

bixc_Exchange(batch, me, other):                         @ FUN_0043fd00
    if me and other are on the same layer (or either is -1):
        if so_SubLayer_CanSee(me, other): me.so_SendMyBriefInfo(other)      # other learns about me
        if so_SubLayer_CanSee(other, me) and me is a player:
            if batch.count > 27: bixc_Send(batch, me); batch.count = 0
            other.vt[0x4c4](&batch.chars[count]); count++                   # copy other's 0xEB-byte brief into the batch
bixc_Send(batch, me):                                    @ FUN_0043d570
    if count and me is a player in a mode ≠ 0: me ← 0x1C07 NC_BRIEFINFO_CHARACTER_CMD { u8 charnum, LOGINCHARACTER[charnum] (0xEB each) }
# Mob (0x1C09 NC_BRIEFINFO_MOB_CMD), mini-house, mover, pet, abstate batches work the same way.

so_SubLayer_CanSee(a, b):                                @ FUN_0049ac70
    return table DAT_0d67a118[a.layer.sub (+0x76 → +4)][b.layer.sub] (6 × 6 bytes)

sight distance² (DAT_008b7834) = CalculateBroadcastDistance.cbd_DistanceSquar(p)      @ FUN_0043e740
    n = number of objects within 500 units of p
    if n < threshold (calc+2000): MapInfo.Sight² of the field (field+0x10 → +0x48), or −1 (unlimited) for
        special fields (FUN_0054b000 == 1 or field+0x124 == 1)
    else: table[min(n − threshold, 499)]                 # crowded places shrink the sight radius
```

Callers: `sp_NC_MAP_LOGINCOMPLETE_CMD` (Z01 §6), `so_mob_RegenComplete`, `spt_RegenComplete` (pet),
`so_door_BuildComplete`, `so_effect_BlastComplete`, magic-field spread, FUN_00441b10 (after a same-zone teleport,
followed by `asl_SendAfterLogin`), FUN_00441940 (hide-except-me off: `so_HideExceptMeOff_BriefInfo` over the map, then
all batches flushed) and the scenario camera move (FUN_00441e00, `AxialListCameraMove`, §12).

No zone code sends 0x1C0E NC_BRIEFINFO_BRIEFINFODELETE_CMD. Objects leave the client through 0x1805 (logout
broadcast, Z01 §3.2) and the client's own sight handling *(inferred)*.

---

## 6. NPC click, NPC roles and server menus

### 6.1 Data

`World/NPC.txt` table `ShineNPC` (loader `NPCManager::nm_Load` @ FUN_004c58c0; per-world override
`World/<world>/NPC.txt`): `MobName[33] @0, Map[20] @0x21, Coord-X @0x35, Coord-Y @0x39, Direct @0x3d,
NPCMenu u8 @0x3f, Role, RoleArg0`; plus table `LinkTable { argument, MapServer, MapClient, Coord-X, Coord-Y, Direct,
Party }` for gate destinations. Each spawned NPC gets an entry `{ row, NPCRole* }` in the role table DAT_0da29a60
(`FUN_00418f10(table, npcHandle)`, binary search). Role names → classes (RTTI; vtable `[0] nrb_Role(p, entry, hnd)`,
`[1] nrb_EndOfTrade(p)`):

| Role (NPC.txt) | Class | nrb_Role | Count in 2016 NPC.txt |
|---|---|---|---|
| Merchant (Weapon / Skill / Item / SoulStone / WeaponTitle / Guild) | NPCRole_Merchant | FUN_004c3c00 | 98 |
| StoreManager | NPCRole_StoreManager | FUN_004c4050 | 9 |
| NPCMenu (Guild / ExchangeCoin / RandomOption / Ranking) | NPCRole_MenuOpen | FUN_004c4140 | 20 |
| Gate | NPCRole_Portal | FUN_004c2ef0 | 233 |
| IDGate | NPCRole_ID_Portal | FUN_004c33f0 | 10 |
| ModeIDGate | NPCRole_Mode_ID_Portal | FUN_004c35d0 | 4 |
| RandomGate | NPCRole_RandomMulti_Portal | FUN_004c3850 | 5 |
| JobManager | NPCRole_JobManager | no-op (FUN_004c2450) | 2 |
| ClientMenu, Guard, QuestNpc | NPCRole_ClientMenu / _Guard / base | NPCRoleBase.nrb_Role only logs "NPCRoleBase::nrb_Role" (FUN_004c2430) | 1 / 52 / 217 |

Player state: `+0x17d7c` u16 last clicked NPC handle, `+0x17d7e` u16 its mob id, `+0x17d80` → role entry,
`+0x17d84` range-check object `{ vtable PTR_vftable_0084d82c, u32 x, u32 y }` (FUN_004c4610: if the player moved
more than 1000 units from x,y → `sp_EndOfTrade`), `+0x17d90` ServerMenuActor (§6.5), `+0x18248` u16 open-menu bits
(`DuplicatedMenuControl`: vt 0x6ac `dmc_CanMenuOpen(kind)`, vt 0x6b0 set bit, vt 0x6b4 clear bit; kind 0 = shop/menu,
1 = storage), `+0x5cb8` bit 4 = storage open.

### 6.2 0x200A NC_ACT_NPCCLICK_CMD `{ u16 npchandle }`

```pseudo
@ FUN_004c4b70
    if mode ∉ {1,2,6}: return
    if p.field: field.CinemaComplex.cc_ScriptInterrupt(sim_NPCClick, { npchandle, … })   # scenario scripts (§12)
    npc = GetObject(npchandle)
    if !npc: log "…NPCCLICK_CMD : NPC not found"; sp_EndOfTrade(p, 1); return
    npc.lastClicker (+0x186) = p.handle                  # vt 0x814
    if npc is a mob (5) or a door (7)
       or (npc is an NPC (4) with an AI script (+0x7e ≠ 0, script name +0x9e ≠ "")):
        npc.so_AIScriptFuncExec(0x20 = "clicked", { npc, p, "" })     # vt 0xb68 @ FUN_004ab3f0
        sp_EndOfTrade(p, 1); return
    if dist²(p, npc) ≤ 1 000 000 (same map instance and layer, FUN_004028f0): InteractWithNPC(p, npc)   # vt 0xa20
    else: sp_EndOfTrade(p, 1)

InteractWithNPC(p, npc):                                 @ FUN_004c4660
    if mode ∉ {1,2,6}: return false
    if FUN_006410c0(DAT_14d44a38, p.brief.polymorph (+0x52)) == 0x11: return false   # polymorphed into a form that cannot talk (inferred)
    p.npcEntry = RoleTable.find(npc.handle); if none: sp_EndOfTrade; return false
    p.npcHandle = npc.handle; p.npcMobId = npc.vt[0x708]()
    switch QuestPlayer.NPCClickCheck(p+0x173e8, mobId):
      1: QuestPlayer.NPCClick(mobId)                     # quest dialog (Z08); arm the 1000-unit range check
      2: nothing
      else:
        if entry has no row or no role: sp_EndOfTrade; return false
        if row.NPCMenu (+0x3f) == 0: role.nrb_Role(p, entry, npc.handle)            # act at once
        else: send 0x201C NC_ACT_NPCMENUOPEN_REQ { u16 mobid = p.npcMobId }; arm the range check
              # the client shows the NPC's dialog and answers 0x201D
    return true
```

### 6.3 0x201D NC_ACT_NPCMENUOPEN_ACK `{ u8 ack }`

```pseudo
@ FUN_004c4910
    if mode ∉ {1,2,6}: return
    if !p.npcEntry: log "…MenuAck not during npc process"; return
    if entry.role and RangeCheck(p) (≤ 1000 units from where the menu opened, else sp_EndOfTrade) and ack == 1:
        entry.role.nrb_Role(p, entry, p.npcHandle)
```

### 6.4 0x200B NC_ACT_ENDOFTRADE_CMD, 0x2073 NC_ACT_NPC_MENU_CMD

```pseudo
0x200B (no payload):                                     @ FUN_004c4a60
    if mode ∈ {1,2,6}: sp_EndOfTrade(p, 1)

sp_EndOfTrade(p, resetMenu):                             @ FUN_004c25b0
    p+0x17ce8 = 0
    if p.npcEntry:
        entry.role.nrb_EndOfTrade(p)                     # Merchant/MenuOpen: clear menu bit 0; StoreManager: clear bit 1 and +0x5cb8 bit 4
        p.npcEntry = 0; range check = 0
        if resetMenu: sma_Reset_new(p.serverMenu)        # closes an open server menu (0x3C0F), §6.5
        p+0x5cb8 &= ~0x10; p.npcHandle = 0xFFFF
        sp_GuildStorageClose(p)

0x2073 NC_ACT_NPC_MENU_CMD { u8 Ack }:                   @ FUN_004c2460
    if mode ∉ {1,2,6}: return
    npc = GetObject(p.npcHandle); if !npc: log "…NPC_MENU_CMD : NPC not found"; return
    npc.so_AIScriptFuncExec(0x3c, { npc, p, Ack })        # the NPC's AI script gets the answer (script menus)
```

### 6.5 Role actions

```pseudo
NPCRole_Merchant.nrb_Role(p, entry, npcHnd):             @ FUN_004c3c00
    mapIdx = so_mapindex(p); if invalid: log "…Wrong mapindex"; return
        # so_mapindex @ FUN_0054dd80: no field → 0xFFFF; else mapdatabox BTree lookup of the field's mapidclient name (0xFFFF if absent)
    if !p.dmc_CanMenuOpen(0): return; set menu bit 0
    switch RoleArg0:
      "SoulStone": nrm_PortionStone(p)                   @ FUN_004c2d60
          send 0x3C05 NC_MENU_SHOPOPENSOULSTONE_CMD { hp.recover, hp.maxnum = row.hpMax × p+0x2a5a2 / 1000, hp.price,
                                                      sp.recover, sp.maxnum = row.spMax × p+0x2a5a4 / 1000, sp.price }
          # row = per-level soul-stone row of the player's class data (vt 0x49c +0x10858[level])
      "Weapon": ShopMenuOpen(…, plain 0x3C03, table 0x3C09)
      "Skill":  ShopMenuOpen(…, 0x3C04, 0x3C0A)
      "Item", "WeaponTitle": ShopMenuOpen(…, 0x3C06, 0x3C0B)
      "Guild":  nrm_GuildShopMenuOpen (@ FUN_004c2990, guild shop, same packets)
    remember the role and position for the range check (p+0x17d84)

NPCRole_Merchant.nrm_ShopMenuOpen(p, npcHnd, mapIdx, npcName, plainCmd, tableCmd):   @ FUN_004c26b0
    list = NPCItemList table DAT_0da29450 .nilt_MenuPacket(npcName)        # prebuilt shop list of this NPC
    if list: send (15<<10 | tableCmd) NC_MENU_SHOPOPENTABLE_* { u16 itemnum, u16 npc = npcHnd, MENUITEM[itemnum] (3 bytes) }
    else:    every ItemInfo row whose shop-name field (+0x24, 20 bytes) equals RoleArg0 and is sold in this city
             (MerchantCityData.mcd_city(mapIdx) flag at row+0x38) → send (15<<10 | plainCmd) { u16 itemnum, u16 npc, u16 itemID[itemnum] }
             (log "…nrm_skill : Too many item" when the buffer is full)
    if the role's vt[0x38]() == 1: p.vt[0xe68]()

NPCRole_StoreManager.nrb_Role(p):                        @ FUN_004c4050
    if !p.dmc_CanMenuOpen(1): return; set bit 1
    sp_NC_ITEM_DEPOSIT_REQ(p, page 0..3, 0)              # send the storage pages (Z04/Z05)
    FUN_006446b0(p + 0x18258)

NPCRole_MenuOpen.nrb_Role(p):                            @ FUN_004c4140
    if !p.dmc_CanMenuOpen(0): return; set bit 0
    "Guild"        → send 0x3C0C NC_MENU_GUILDMENUOPEN_CMD (empty)
    "ExchangeCoin" → send 0xBC0C NC_GAMBLE_COIN_EXCHANGEMACHINE_UI_OPEN_CMD (empty)
    "RandomOption" → send 0x3C0E NC_MENU_RANDOMOPTION_CMD (empty)
    "Ranking"      → send 0x3C10 NC_MENU_INDUNRANK_CMD (empty)
    else log "NPCRole_MenuOpen::nrb_Role : Invalid argument"
    (all but Guild/ExchangeCoin arm the range check)

NPCRole_Portal.nrb_Role(p, entry, npcHnd):               @ FUN_004c2ef0  (role "Gate")
    if p has a trade partner (+0x17d5f): return
    if p rides a mover, only the mover's owner (vt 0xca8 == p.charNo) may use it
    if a server menu is already open: return
    destinations = the NPC's LinkTable rows (vt 0x24(i), count vt 0x28); level range vt 0x3c / 0x40
    check (FUN_00462040 = link condition, FUN_004626e0 = report it; Z01 §7):
        one destination: its condition; several: level must be inside [min, max] (else code 2) and each destination's condition
    if allowed:
        one destination: server menu (below) titled sprintf(text "LinkTitle", MapInfo.Name of the destination),
                         items "Yes" → smfm_Link(dest), "No" → smfm_Cancel; range limit 1000
        several: send 0x181F NC_MAP_MULTY_LINK_CMD { u16 npcHnd, u32 p.x, p.y, u16 1000, u8 count, char map[12] × count } (0x4b bytes)
                 → client answers 0x181F … SELECT_REQ (Z01 §7.3)
# ID_Portal, Mode_ID_Portal and RandomMulti_Portal (instance dungeon gates) follow the same pattern with
# smfm_LinkToDungeon; not traced line by line.

ServerMenuFuncter.smfm_Link(p, linkRow):                 @ FUN_0050ed70
    condition = linkRow.useOwnLevel (+0x61) ? FUN_00461ee0(p, row, min +0x62, max +0x64) : FUN_00462040(p, row)
    if FUN_004626e0(p, condition, levels):
        if the destination field (g_FieldList by map name) needs an item (+0x6d ≠ -1, count +0x69):
            sp_DestroyItemB(p, …) (consumes it, then links)
        elif the open NPC entry's role allows it (role vt 0x34(row)):
            if p rides a mover: copy the mover's seating to all passengers and link every passenger too
            so_LinkTo(p, row, 6, 9, 10)                  # Z01 §7.1
ServerMenuFuncter.smfm_Cancel(p):                        @ FUN_0050ecc0
    sp_EndOfTrade(p, 1); p+0x5cb9 &= ~0x04
```

### 6.6 Server menus (generic yes/no dialogs) and 0x3C02 NC_MENU_SERVERMENU_ACK `{ u8 reply }`

`ServerMenuActor` at `p+0x17d90`: `{ u32 x, y (where the menu opened); 10 slots × 0x6c (0x68 bytes of data +
callback); +0x440 slot count; +0x444 rangeLimited; +0x448 owner; +0x44c cancel slot (data + callback +0x4b4) }`.
Menus are built with `sp_ServerMenuTitle` / `sp_ServerMenuItem(callback, text, data)` and sent by
`sp_ServerMenuOpen(priority, npcHnd, pos, limitRange)` (@ FUN_0054eaa0) as 0x3C01 NC_MENU_SERVERMENU_REQ
`{ u8 title[128], u8 priority, u16 npcHandle, u32 npcPosition.x, y, u16 limitRange, u8 menunum, SERVERMENU[menunum] (0x21 bytes) }`;
the actor's x,y = the player's position. Callbacks seen: `smfm_Link`, `smfm_LinkToDungeon`, `smfm_LinkWithoutNPC`,
`smfm_LuaFuncExec`, `smfm_DeleteInstanceDungeon`, `smfm_ImmediateDivorce` / `…Cancel` (§10), `smfm_Cancel`.

```pseudo
@ FUN_0050fe60
    if mode ∉ {1,2,3,6}: p+0x5cb9 &= ~0x04; sma_Reset_new(actor); return
    tooFar = actor.rangeLimited (+0x181d4 == 1) and dist²(p.pos, actor.xy) > 1 000 000
    if !(p+0x5cb9 & 0x04) and tooFar: p+0x5cb9 &= ~0x04; sma_Reset_new(actor); return
    sma_Reply(actor, p, reply)

sma_Reply(actor, p, i):                                  @ FUN_0050fd40
    if i ≥ 10: log "ServerMenuActor::sma_Reply : Too many regist"; p+0x5cb9 &= ~0x04; sma_Reset_new; return
    (cb, data) = slot[i]; sma_Reset(actor) (@ FUN_0050f660, forget all slots); cb(p, data)

sma_Reset_new(actor):                                    @ FUN_0050fc00
    if a menu is open (owner and count ≠ 0): run the cancel callback; send 0x3C0F NC_MENU_SERVERMENU_CLOSE_CMD (empty)
    sma_Reset(actor)
```

`p+0x5cb9` bit 2 marks a menu opened without a range limit *(inferred from the check; the setter was not traced)*.

---

## 7. Tents (mini-house rest mode)

Mode 4 is "resting in a tent" (pitch sets it, fold clears it; so_LinkTo leaves it through `vt[0x488]`, Z01).

```pseudo
0x2027 NC_ACT_PITCHTENT_REQ (no payload):                @ FUN_00457760
    reply = 0x2028 NC_ACT_PITCHTENT_ACK { u16 err } (so_SendErrorCode 8/0x28)
    if mode ∉ {1,2}:                         → 0x0A82
    if feared (+0x1e78 bit 2) or vt 0xf20:   → 0x0A86   "Cannot rest during feared state."
    if no field or FieldList.CanMiniHouse (+0x9d) == 0: → 0x0A84
    scan 400 units around p (so_AllOfRange_Class0 with so_TentPoint, each object's vt 0x768):
        a resting player (mode 4 or 5), a mini-house, or an NPC with mob id 0x15E6 / 0x15E7 / 0x1644
        within 45 units (dist² ≤ 2025) refuses            → 0x0A83   "Cannot rest near NPC or other Mini House(s)"
    ClearEmoticon(p); p.CancelOnAction(); so_mobile_StopHere(p)
    p.recoverFunc (+0x29628) = sp_RecoverPoint_House     # HP/SP regeneration of the rest mode
    save p.brief.shapedata (0x2b bytes at +0x25) into +0x292ac (+0x292d7 = saved)
    if !sp_MakeTentBriefInfo(p, &brief.shapedata):        @ FUN_0056e720
        # needs the equipped mini-house item (+0x292d8): shapedata = { u16 skin = item+4 → +0, u32 -1, u32 -1, u16 -1 }
        → 0x0A85; restore the shape; return
    FUN_00448fa0(p+0x17d0c, p)                           # (skill list hook; not traced)
    p.mode = 4
    if p.petSystemState ∈ {5,6}: p+0x2abcc = g_Now + 600, +0x2abd0 = 600      # the pet reacts for 60 s (inferred)
    broadcast to sight 0x2029 NC_ACT_SOMEONEPITCHTENT_CMD { u16 hnd, CHARBRIEFINFO_CAMP camp (12 bytes = the new shapedata) }
    p+0xea0 = p+0xea4 = g_Now                            # rest timers
    smo_BashStop(p)
    → 0x0A81 (success)

0x202A NC_ACT_FOLDTENT_REQ (no payload):                 @ FUN_00457a90
    if mode ≠ 4: → 0x202B NC_ACT_FOLDTENT_ACK { 0x0A82 }; return
    p.recoverFunc = FUN_00417480 (normal regeneration); p.mode = 1
    restore the saved shapedata if any
    broadcast to sight 0x202C NC_ACT_SOMEONEFOLDTENT_CMD { u16 hnd, 0x2b bytes shapedata }      (45 bytes)
    → 0x202B { 0x0A81 }
    ClearEmoticon(p)
```

Client: `On_NC_ACT_PITCHTENT_ACK` (@ FUN_004aa010) on 0x0A81 stops auto-run, uses `Inventory::GetMiniHouseSkin`
and `ChangeCampMode(1, 4)`; 0x0A83 and 0x0A86 show the texts above; every other code resets the mode to 1 silently.
`On_NC_ACT_FOLDTENT_ACK` (@ FUN_00499e50) only reacts to 0x0A81 (`ChangeCampMode(0, 4)`).

---

## 8. Gathering and production

`Gather.shn` (`GatherProduce::GatherTable::gt_Load` @ FUN_0046a660; columns `GatherID, Index, Type, NeededTool0..2,
EqipItemView, AniNumber, Gauge`; table at DAT_0d026dc0, 12-byte entries `{ row*, u16 tool[3] (item ids, -1 = none) }`).
`Type` = `GatherType` *(pdb2017)*: 0 HERBING, 1 MINING, 2 WOODCUTTING, 3 FISHING. A gatherable object is a mob whose
`MobInfo.Type` (+99, `MobType` enum) is 8 MT_MINE, 9 MT_HERB, 10 MT_WOOD, 21 MT_BOX_HERB, 22 MT_BOX_MINE.
Player state: `p+0x2a308` u16 handle of the object being gathered (-1 = none); the timer is the action-state
object at `p+0x2a784` (shared with the normal-attack state; `.state` +0x2a790).

```pseudo
so_mob_CanGathered(mob, p, &picker):                     @ FUN_0046af50 (ShineMob vt 0x720)
    MT_MINE, MT_BOX_MINE: r = sp_GatherCheck(p, 1, &picker); if picker == -1: return 0x0B0C; return r
    MT_HERB, MT_BOX_HERB: return sp_GatherCheck(p, 0, &picker)
    MT_WOOD:              return sp_GatherCheck(p, 2, &picker)
    else: return 0x0B02
sp_GatherCheck(p, type, &picker):                        @ FUN_0046ad70
    picker = -1
    for every Gather row of this type: if each of its 3 tools is -1 or present in p's inventory:
        picker = the first tool id found; return 0x0B01 (ok)
    return 0x0B0C (no tool)

0x202D NC_ACT_GATHERSTART_REQ { u16 objhandle }:         @ FUN_0046ccb0
    if mode ∉ {1,2}:            so_SendErrorCode(8, 0x2E, 0x0B04)      # 2-byte error form of 0x202E (original bug) Z02-B4
    if p.gathering ≠ -1:        log "…During other gathering"; → 0x0B05
    obj = GetObject(objhandle); none: log "…Invalid Object"; → 0x0B02
    r = obj.vt[0x720](p, &picker)                        # so_mob_CanGathered; other object types answer their own code
    send 0x202E NC_ACT_GATHERSTART_ACK { u16 picker, u16 object = obj.handle, u16 err = r }
    if r ≠ 0x0B01: log "…No Skill"; return
    broadcast to sight 0x202F NC_ACT_SOMEONEGATHERSTART_CMD { u16 player = p.handle, u16 object, u16 picker }
    p.gathering = obj.handle
    t = SingleData "Gather_MaxTime_Gatherable" (= 4 in 2016 SingleData.shn) × 1000 ms; halved if p+0x2a5ad (charged-item bonus)
    start the action timer p+0x2a784 (FUN_0042ab50): after t → sp_Schedule_Gather (@ FUN_0046cb40) = sp_GatherComplete(p, 1)

0x2030 NC_ACT_GATHERCANCEL_CMD (no payload):             @ FUN_0046b120
    if mode ∉ {1,2}: return
    if p.gathering == -1: log "…_GATHERSTART_REQ : During other gathering" (sic) (original bug) Z02-B13; return
    obj = GetObject(p.gathering); p.gathering = -1
    if !obj: log "…Object Null"; return
    broadcast to sight 0x2031 NC_ACT_SOMEONEGATHERCANCEL_CMD { u16 player, u16 object }
    reset the action timer (state 0, callbacks FUN_00570b00 / FUN_004a9c90)

0x2032 NC_ACT_GATHERCOMPLETE_REQ (no payload):           @ FUN_0046cbf0
    reset the action timer; sp_GatherComplete(p, 2)      # the client says "done" before the server timer fires

sp_GatherComplete(p, how):                               @ FUN_0046b2f0
    reply 0x2033 NC_ACT_GATHERCOMPLETE_ACK { u16 err, u16 object }
    if mode ∉ {1,2}:                → { 0x0B04, 0xFFFF }
    if p.gathering == -1:           log "…During other gathering"; → { 0x0B06, 0xFFFF }
    obj = GetObject(p.gathering); p.gathering = -1
    if !obj:                        log "…RawObject Not found"; → { 0x0B02, 0xFFFF }
    → { 0x0B01, obj.handle }
    broadcast to sight 0x2034 NC_ACT_SOMEONEGATHERCOMPLETE_CMD { u16 player, u16 object }
    if obj's MobInfo.Type ∉ {8, 9, 10}: how = 1
    obj.vt[0x5bc](p, obj.vt[0x4e8](0, how))              # "kill" the resource with its full HP: the drop / loot goes to p (Z09)
    FUN_004d2470(p, 5)                                   # pet reaction (inferred)
```

The 2016 client handles 0x202E, 0x202F, 0x2031, 0x2033, 0x2034 in `GatheringTask::OnProcessNetMsg`
(@ FUN_00486320): on 0x202E with err 0x0B01 it opens the gathering window with the `Gather.shn` time of the
(mob type, picker) row (halved under charged effect 5) and plays `Char::ActGathering`; any other err →
`GatheringWin::GatheringFail`. None of the 0x0Bxx codes has a client error text.

```pseudo
0x2035 NC_ACT_PRODUCE_CAST_REQ { u16 produceskill }:     @ FUN_0046cf90 (profiler string says "…GATHERCOMPLETE_REQ", see §15)
    errors → 0x2036 NC_ACT_PRODUCE_CAST_FAIL_ACK { u16 err }
    if mode ∉ {1,2}:                               → 0x0B04
    if no field or FieldList.CanProduce (+0xa3) == 0: → 0x0B11
    if the action state is 2 or 3 (attacking):      → 0x0B07
    if p does not know the skill (FUN_0046a420(p+0x17d0c, p, produceskill)): → 0x0B08
    recipe = RecipeBook (DAT_0d026dc8, `GatherProduce::RecipeBook::rb_Load` @ FUN_0046a840).find(produceskill)
    if !recipe:                log "…Skill cannot found";    → 0x0B09
    if recipe.product (+4) == -1: log "…Invalid Item Produce"; → 0x0B09
    skill = SkillData (DAT_13286828).find(produceskill); none: log "…Invalid skill"; → 0x0B09
    clear the skill-cast block (p+0x1d84, SkillCastStruct scs_Clear)
    p.cast.end (+0x1d84) = g_Now + (skill.castTime(+0xcb) × 10 / 1000) × 1000 / p.castSpeed (+0x2a5c0)
    p.cast.skill = produceskill; p.cast.recipe = recipe; p.cast.skillRow = skill
    broadcast to sight 0x2038 NC_ACT_SOMEONEPRODUCE_CAST_CMD { u16 caster, u16 item = recipe.product }
    # the cast end is handled in the player tick and sends 0x203B NC_ACT_PRODUCE_MAKE_CMD { u16 item, u16 err } /
    # 0x203C (not part of this item; Z07/Z09)

0x2039 NC_ACT_PRODUCE_CASTABORT_CMD (no payload):        @ FUN_0046b620
    if mode ∈ {1,2} and a produce cast is running (p+0x1d84 ≠ 0):
        broadcast to sight 0x203A NC_ACT_SOMEONEPRODUCE_CASTCUT_CMD { u16 caster }; p+0x1d84 = 0
```

The 2016 client has **no handler** for 0x2036, 0x2038, 0x203A, 0x203B (C01); production in the 2016 client runs
through `ProductTask` (0x481D, item dept). These produce handlers are probably legacy *(inferred)* (original bug) Z02-B5.

---

## 9. Mounts, megaphone, item emotes

### 9.1 0x2044 NC_ACT_RIDE_FEEDING_REQ `{ u8 slot }`

Mode 6 = riding (only mode allowed here). `p+0x2a762` i16 inventory slot of the ride item (< 0 = not riding),
`p+0x2a764` → ride info `{ +0 u16 ride item id, +4 → row (+0x84 feed item InxName, +0xc4 / +0xc6 feed values) }`,
`p+0x2a778` = hungry (set by sp_SendHorseHungry when the gauge is 0; blocks 0x2019 in mode 6, §2.2).

```pseudo
@ FUN_0045f9e0     errors → 0x2045 NC_ACT_RIDE_FEEDING_ACK { u16 err }
    if mode ≠ 6:                  → 0x10C5
    if p.rideSlot < 0:            log "…No ride";  → 0x10C5
    if !p.rideInfo:               log "…No info";  → 0x10C6
    ride = inventory[p.rideSlot]; if ride.itemId ≠ rideInfo.itemId: log "…No Ride"; → 0x10C6
    feed = inventory[slot]; if feed.itemId ≠ ItemInfo id of rideInfo.row.feedName: → 0x10C7
    if feed.lot < 1:              log "…invalid lot"; → 0x10C7
    ride.attr.vt[0x3c](ride, row+0xc4, row+0xc6)         # add to the hunger gauge
    sp_DestroyItemB(p, hnd, feed id, 1, 0)                # use one feed item
    sp_HorseItemSave(p)
    sp_SendHorseHungry(p, ride.attr.vt[0x40](ride))       @ FUN_0045e510:
        0x2046 NC_ACT_RIDE_HUNGRY_CMD { u16 hungry }; p.hungry = (hungry == 0)
    # no 0x2045 on success
```

The 2016 client does not handle 0x2045 (original bug) Z02-B6; 0x2046 (@ FUN_004aa1c0) shows "Hunger Gauge is Zero. Your Mover cannot run
in this status…" when 0.

### 9.2 0x204B NC_ACT_ROAR_REQ `{ u8 slot, u8 len, u8 content[len] }` (megaphone)

```pseudo
@ FUN_005404d0     errors → 0x204C NC_ACT_ROAR_ACK { u16 err }
    if mode ∉ {1,2,4,6}:                       → 0x0701 "Cannot use the item due to an Abnormal State."
    if no field or FieldList.CanItem (+0x9e) == 0: → 0x0710 "The selected item cannot be used in this area."
    if open-menu bits 2 or 3 (p+0x18248 & 0x0C): so_SendErrorCode(12, 12, 0x0242) (0x300C RELOC_ACK) (original bug) Z02-B7
    if slot ≥ inventory size: log "…wrong slot"; → 0x0702
    if the cell is locked (InventoryLocking +0xfaa8 .vt[4](9, slot, +0x2a772)): → 0x070A
    item = inventory[slot]; if item.id ≠ roar item (DAT_14d504ac): → 0x0702
    if item.lot < 1 or no ItemInfo: → 0x0703
    if the field has a guild-tournament system that forbids it (FUN_0047a160): → 0x0720
    if p is GM-muted (+0x2aa54): return (item kept, nothing sent)
    UseItemNormal.uib_AfterCast(p, inventory, itemInfo, slot)           # consumes the item (Z04)
    p+0x2a79c = queue the message in the roar ring DAT_008598c0 (FUN_0053f900: entries { u16 handle, char msg[129] })
    # the message is sent when the item effect runs (not traced; Z04)
```

### 9.3 0x2067 NC_ACT_ACTIONBYITEM_REQ `{ u8 slot }` (premium emote items)

```pseudo
@ FUN_00458440     reply 0x2068 NC_ACT_ACTIONBYITEM_ACK { u16 error, u8 emoticonid }
    if p.IsInGambleGame(): SendMoveFail(p); return
    if mode ∉ {1,2,6} or no field:   → 0x1C29 "Your current situation isn't able to take the emotion."
    p.CancelOnAction()
    cell = inventory2 (p+0xf758)[slot]; no cell / item / id −1 → 0x1C2A "Wrong premium emotion item."
    use = ItemUseFunction (DAT_132878f0, `ItemUseFunction::iuf_Load`).find(item id)
    emote = the first of its 3 effects with type 9 (+0x20/+0x26/+0x2c → value +0x24/+0x2a/+0x30); none → 0x1C2B "Data error."
    → { 0x1C28, emoteId }
    sp_DoEmotion(p, p.handle, emoteId)                   # §4; the item is not consumed
```

---

## 10. Wedding

Wedding data per player = a copy of `NC_CHAR_WEDDINGDATA_ACK` (0x1081, Z07/D04) at `p+0x5cc8` (vt 0x958):
`+8 Status { Main:4, Sub:4 }`, `+0xd ApplicationLimit` (ShineDateTime), `+0x11 Partner.Name[20]`,
`+0x25 Partner.RegisterNumber` (charNo), `+0x2a RefusalCount` *(field names pdb2017; the 2016 offsets match the
code)*. Main: 0 single, 1 engaged, 2 married *(inferred from the checks)*. Sub (married): 0 none, 1/3 own divorce
application pending, 2 partner applied (agreement), 4 partner forced *(inferred)*. Item ids: proposal ring
DAT_14d504b8, invitation DAT_14d504ba. The current server time as ShineDateTime is DAT_00aa43b8. No handler here
reads the `to`/`from` handle of its packet: the counterpart is always `som_FindPlayer(p.wedding.Partner.RegisterNumber)`;
how the partner is chosen before proposing is not traced (WM/DB 0x1095 NC_CHAR_WEDDING_PARTNER_INFO_RNG, Z08) *(inferred)*.

```pseudo
ProposeResult(rcv, to, err [, word]):  rcv ← 0x2052 NC_ACT_WEDDING_PROPOSEREQ_ACK { u16 to, u16 err, char response_word[37] }   @ FUN_0059ebf0 / FUN_0059ec80
ReservResult(rcv, err, t):             rcv ← 0x2054 NC_ACT_WEDDING_HALL_RESERV_ACK { u16 err, i64 ReservedTime, tm (9 × i32 localtime) }   @ FUN_0059ed00

0x204F NC_ACT_WEDDING_PROPOSEREQ_REQ { u16 to, char propose_word[37] }:   @ FUN_0059f760 (no mode mask)
    t = FindPlayer(p.partnerCharNo); none → ProposeResult(p, p.handle, 0x12C8) "You don't have anyone to propose to."
    p:  mode ∉ {1,2,6} → 0x12C1 "Please get off from mount or cancel the mini house mode."; p.Main ≠ 0 → 0x12C5
    t:  mode ∉ {1,2,6} → 0x12C2 "Selected target does not exist."; t.Main ≠ 0 → 0x12C6 "Target user is not available for a marriage."
    if dist²(p, t) > 10000:  → 0x12C3 "Please keep a close proximity to your fiance…"
    t ← 0x2050 NC_ACT_WEDDING_PROPOSEACK_REQ { u16 from = p.handle, char propose_word[37] (36 copied + NUL) }

0x2051 NC_ACT_WEDDING_PROPOSEACK_ACK { u16 from, u8 reply, char response_word[37] }:   @ FUN_0059f900 (no mode mask)
    q = FindPlayer(p.partnerCharNo)                       # the proposer
    if !q or q is not a player: ProposeResult(p, p.handle, 0x12C8); return
    if q.Main ≠ 0: q ← 0x12C5, p ← 0x12C6; return
    if p.Main ≠ 0: q ← 0x12C6, p ← 0x12C5; return
    if reply == 0: ProposeResult(q, q.handle, 0x12CA, response_word); return       # refused (no client text) (original bug) Z02-B8
    if !sp_DestroyItemB(q, ring, 1): ProposeResult(q, q.handle, 0x12C7) "You don't have proposal items."; return
    ProposeResult(q, p.handle, 0x12C0, response_word)    # accepted
    FUN_005b92a0(DAT_13388678, q.name, p.name)           # (announcement/record; not traced)
    Character DB ← 0x1083 NC_CHAR_WEDDING_PROPOSE_REQ { u16 p.handle, u32 p.charNo, u32 q.charNo }

0x2053 NC_ACT_WEDDING_HALL_RESERV_REQ (no payload):      @ FUN_005a2330 (no profiler string; name from its log text)
    p: mode ∉ {1,2} → 0x1301; Main ≠ 1 → 0x1303 "You haven't proposed yet…"; no wedding-prepare item
       (vt 0x950 so_ply_WeddingPrepareItem) → 0x1308 "Both you and your partner need a Wedding Application…"   (sent as 0x2052) (original bug) Z02-B9
    t = FindPlayer(p.partnerCharNo); not a player or dist² > 10000 → ReservResult(p, 0x1305, 0)
    if p.ApplicationLimit has passed (FUN_00517990):        ReservResult(p, 0x1304, 0) "3 days have elapsed since the marriage proposal."
    t: same three checks (0x1302 / 0x1303 / 0x1308, sent to p as 0x2052)
    if !WeddingHall.wh_Reserv(DAT_0086ea38, p, t, &time): ReservResult(p, 0x1306, time) "All spots for reservations are full."
    give 10 invitations (DAT_14d504ba, sp_MakeItem_2(…, 10, id, 0xf)) to p and t; failure → ProposeResult(p, 0x130A) "Your inventory is full…"
    ReservResult(p, 0x1300, time); ReservResult(t, 0x1300, time)
    GameLog ← 0x065D NC_LOG_WEDDING_HALL_RESERVE { u32 p.charNo, u32 t.charNo }

0x2056 NC_ACT_WEDDING_HALL_GUEST_ENTER_READY_REQ (no payload):   @ FUN_0059fb60
    reply 0x2057 NC_ACT_WEDDING_HALL_GUEST_ENTER_READY_ACK (0xAE bytes: u16 err, GroomID[20], BrideID[20],
          i64 EnterStart, WeddingStart, WeddingEnd, 3 × tm)
    mode ∉ {1,2}: err 0x1341 (rest of the buffer stale: (original bug) Z02-B10); else WeddingHall FUN_0059ef40 fills it from the current reservation

0x2058 NC_ACT_WEDDING_HALL_GUEST_ENTER_REQ (no payload):         @ FUN_0059fcb0 (no mode mask)
    reply 0x2059 NC_ACT_WEDDING_HALL_GUEST_ENTER_ACK { u16 err } only on failure
    allowed = p's charNo is one of the couple's (hall+0x2c / hall+0x14) or p holds an invitation; else → 0x1343 "You don't have an invitation…"
    if the hall is not active (hall+0) or now is outside the entry window (hall+4 … hall+8, ShineDateTime compares
       FUN_00517990) → 0x1342 "It's not the right moment for you to enter at this time."
    sp_DestroyItemB(p, invitation, 1)                    # also tried for the couple (fails quietly without one)
    if p.mode == 4: leave the tent (vt 0x488)
    p.vt[0x3fc]({ map "Wedding", x 558, y 154 }, 1)       # link into the wedding hall map (so_LinkTo path, Z01 §7.1)

0x205B NC_ACT_WEDDING_AGREEMENT_DIVORCE_REQ (no payload):        @ FUN_0059fee0
    errors → 0x205D NC_ACT_WEDDING_DIVORCE_REQ_ACK { u16 err }
    mode ∉ {1,2} → 0x1381; money (vt 0x434) < 250 000 → 0x1383 "You don't have enough funds to get divorced…"
    switch p.Sub:
      0: if 7 days since the wedding have not passed (FUN_0059ea50(ApplicationLimit, now) false) → 0x1382
         DB ← 0x1089 NC_CHAR_WEDDING_DIVORCE_BY_AGREE_REQ { u16 handle, u32 charNo, u32 partnerCharNo }; take 250 000 (vt 0x794)
      1, 3: → 0x1388 (5000) "You already applied for divroce."
      2: DB ← 0x108D NC_CHAR_WEDDING_DIVORCE_DO_REQ { u16 handle, u32 charNo, u32 partnerCharNo, u8 0 }; take 250 000

0x205C NC_ACT_WEDDING_COMPULSORY_DIVORCE_REQ (no payload):       @ FUN_005a0120
    mode ∉ {1,2} → 0x1381
    switch p.Sub:
      0: 7-day check → 0x1382; money < 750 000 → 0x1383
         RefusalCount (+0x5cf2) < 3 ? DB ← 0x108B NC_CHAR_WEDDING_DIVORCE_BY_FORCE_REQ { handle, charNo, partner }
                                    : DB ← 0x108D DIVORCE_DO_REQ { handle, charNo, partner, u8 1 }
         take 750 000
      1, 3: → 0x1388
      4: DB ← 0x108D { handle, charNo, partner, u8 1 }    # partner forced: execute
      else: nothing

0x205E NC_ACT_WEDDING_DIVORCE_REFUSE_CMD (no payload):           @ FUN_005a0440 (profiler string "…COMPULSORY_DIVORCE_REQ", log "…DIVORCE_REFUSE_CMD")
    if p.Main == 2 and p.Sub == 4:
        DB ← 0x108F NC_CHAR_WEDDING_DIVORCE_CANCEL_REQ { header.clienthandle (not written, stale: (original bug) Z02-B11),
                 header.charregistnumber = partnerCharNo, Partner = p.charNo, u8 IncreseCount = 1 }   # partner first, as read
```

The client handles 0x2050, 0x2052, 0x2054, 0x2057, 0x2059, 0x205A, 0x205D in `WeddingTask` (C01).

---

## 11. 0x2070 NC_ACT_AUTO_WAY_FINDING_USE_GATE_REQ (no payload)

Sent by the client's auto-path (`MapNavigator`) when it reaches a gate.

```pseudo
@ FUN_00562340     reply 0x2071 NC_ACT_AUTO_WAY_FINDING_USE_GATE_ACK { u16 nError } (sent through vt 0x2f8)
    if mode ∉ {1,2,6}: → 0x2401;  if no field: → 0x2402
    gate = nearest NPC in sight whose NPC.txt Role is "Gate" (AxialListNearGateFind.ali_Work @ FUN_00429680; ctor @ FUN_00428370: handle 0xFFFF, object null)
    none, no role entry, or no LinkTable row whose argument == the NPC's RoleArg0: → 0x2403
    if p rides no mover:
        if the destination map has a level range (FUN_0046a370(DAT_0d026c30, destMap): +0x22 min, +0x24 max)
           and p.level is outside it: → 0x2404
        → 0x2400; so_LinkTo(p, row, 6, 9, 10)
    else (mover): only its owner (vt 0xca8 == p.charNo) continues; every passenger must be inside the level range, else 0x2404
        → 0x2400; copy the mover seating to the owner and the passengers, so_LinkTo every passenger, then the owner
```

Client `On_NC_ACT_AUTO_WAY_FINDING_USE_GATE_ACK` (@ FUN_004b3600): any code other than 0x2400 stops the auto
movement and shows "Automatic movement has been canceled." (no code-specific texts).

---

## 12. Scenario areas and script interrupts

Map scripts (`PineEventScriptNode::ShineInterruptSet::sa_Step` @ FUN_004ec1e0) send the client
0x6C05 NC_SCENARIO_AREAENTRY_REQ / 0x6C07 NC_SCENARIO_AREALEAVE_REQ `{ char areaindex[32] }`; the client
(`AreaInfoMgr::AddRequestAreaTest`, client @ FUN_004be410 / FUN_004be450) watches that area and answers when the
player enters or leaves it.

```pseudo
0x6C06 NC_SCENARIO_AREAENTRY_ACK { char areaindex[32] }:  @ FUN_0050cd90
0x6C08 NC_SCENARIO_AREALEAVE_ACK { char areaindex[32] }:  @ FUN_0050cf00
    if mode ∈ {1,2,6} and p.field:
        field.CinemaComplex (+0x44).cc_ScriptInterrupt(sim_AreaEntry | sim_AreaLeave, { areaindex[32], u16 p.handle })
        # every running cinema/scenario script of the field gets the event (ScriptInterruptManager, @ FUN_005088a0)
```

The same interrupt path carries NPC clicks (`sim_NPCClick`, §6.2). The area is trusted as the client reports it;
the server does not check the position (original bug) Z02-B12.

---

## 13. Field (map) permissions used here

`World/Field.txt` table `FieldList`, packed row at `field+0xc` (offsets from the `#ColumnType` line; KQ @0x36 is the
"kind 3" check of Z01 §7.1, RegenSpot @0x9a is the count the loader validates):

| Offset | Column | Used by |
|---|---|---|
| 0x9b | CanRestart | |
| 0x9c | CanTrade | (Z06) |
| 0x9d | CanMiniHouse | 0x2027 |
| 0x9e | CanItem | 0x204B |
| 0x9f | CanSkill | (Z03) |
| 0xa0 | Chat | 0x2001 |
| 0xa1 | Shout | 0x201E |
| 0xa2 | CanBooth | (Z06) |
| 0xa3 | CanProduce | 0x2035 |
| 0xa4 | CanRide | (Z07) |
| 0xa5 | CanStone | |
| 0xa6 | CanParty | (Z08) |

---

## 14. Client cross-check (summary)

| Opcode | Client handler (2016) | What the client does |
|---|---|---|
| 0x2002 | `On_NC_ACT_SOMEONECHAT_CMD` @ FUN_004a0bb0 | chat line `[%s] : %s` (GM colour `#FFFF00`), balloon |
| 0x201F | @ FUN_004a0ec0 | shout line `[%s] : %s` |
| 0x2004 / 0x2006 | accepted and ignored | |
| 0x2009 | @ FUN_004a1500 | `Char::SetMode` |
| 0x2013 | @ FUN_00499b80 | stop the other character |
| 0x2018 / 0x201A | @ FUN_004a12a0 / FUN_004b5190 | move the other character at `speed`; unknown handle → 0x1C01 |
| 0x201B | `On_NC_ACT_MOVEFAIL_ACK` @ FUN_00499b00 | snap the main character to `back` |
| 0x201C | @ FUN_004b5560 | open the NPC dialog of `mobid` (MobViewInfo) |
| 0x2021 / 0x2023 / 0x2025 | @ FUN_004a1ea0 / FUN_004a1f10 / FUN_00499d40 | emote, emote freeze, jump |
| 0x2028 / 0x202B | @ FUN_004aa010 / FUN_00499e50 | §7 |
| 0x2029 / 0x202C | @ FUN_00499e00 / FUN_00499db0 | tent shape on / off |
| 0x202E…0x2034 | `GatheringTask` @ FUN_00486320 | §8 |
| 0x2036, 0x2038, 0x203A, 0x203B, 0x2045 | not handled | |
| 0x2046 | @ FUN_004aa1c0 | hunger gauge; text at 0 |
| 0x204C | @ FUN_0049b3a0 | megaphone result |
| 0x2068 | @ FUN_0049bb00 | premium emote result (texts 0x1C29–0x1C2B) |
| 0x2071 | @ FUN_004b3600 | §11 |
| 0x0848 | @ FUN_004b2b50 | spam block minutes text |
| 0x1C07 / 0x1C06 / 0x1C19 | @ FUN_004a0540 / FUN_004a02f0 / FUN_004a5560 | create characters / abstate list |
| 0x3C01 / 0x3C0F | @ FUN_0049a950 / FUN_008b80a0 | open / close the server menu |
| 0x3C03, 0x3C09, 0x3C0B, 0x3C05 | @ FUN_006134e0 / FUN_006137c0 / FUN_004a2d20 / FUN_00613650 | shop windows (0x3C06 accepted and ignored) |
| 0x3C0C / 0x3C0E / 0x3C10 / 0xBC0C | GuildTask / FUN_0049d9e0 / FUN_0048cf70 / MHDiceGameTask | menu windows |
| 0x6C05 / 0x6C07 | @ FUN_004be410 / FUN_004be450 | area watch |

---

## Original-server bugs

Behaviour of the 2016 zone that looks unintended. A faithful rebuild reproduces it; a fixed rebuild should change it
deliberately. All items are read in the code; none was observed in a capture.

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z02-B1 | 0x2003 / 0x2005 §2.1 | the position is set to the client's `to` with no distance, cell or speed check | a client can teleport anywhere inside the field (unchecked input) | the 0x2017 checks (Near, CellFree, LineBlocked) or drop the handlers |
| Z02-B2 | 0x2017 / 0x2019 §2.2 | `moveattr` in 0x2018 / 0x201A keeps whatever `g_buf` held except bit 0 | stale bytes on the wire | write the full word |
| Z02-B3 | 0x1C01 §5.1 | the requester's abstate list (0x1C19 about p) is sent to the looked-up object | the other player gets p's abstates; p never gets obj's | send obj's abstates to p |
| Z02-B4 | 0x202D §8 | the mode error sends `{u16 0x0B04}` as 0x202E, whose layout is `{picker, object, err}` | client reads 0x0B04 as `picker` and `err` from past the payload | the full 6-byte 0x202E |
| Z02-B5 | 0x2035 / 0x2039 / produce tick §8 | sends 0x2036, 0x2038, 0x203A, 0x203B | the 2016 client has no handler for any of them | legacy path; remove or route through ProductTask |
| Z02-B6 | 0x2044 §9.1 | errors reply with 0x2045 | the 2016 client does not handle 0x2045: feeding failures are silent | a handled reply |
| Z02-B7 | 0x204B §9.2 | the open-menu refusal is sent as 0x300C NC_ITEM_RELOC_ACK | the megaphone gets no answer; the client sees a stray relocation result | 0x204C with a code |
| Z02-B8 | 0x2051 §10 | a refused proposal sends 0x12CA | no client text: the proposer is not told | a code with a text |
| Z02-B9 | 0x2053 §10 | the mode / Main / prepare-item errors go out as 0x2052 (PROPOSEREQ_ACK) | the reservation window gets no 0x2054 for these refusals | 0x2054 |
| Z02-B10 | 0x2056 §10 | on a mode failure 0x2057 carries 0xAC stale bytes after the error code | stale buffer content on the wire | zero the body |
| Z02-B11 | 0x205E §10 | `header.clienthandle` of 0x108F is not written | the DB gets a stale handle | the player's handle |
| Z02-B12 | 0x6C06 / 0x6C08 §12 | the area entry/leave is taken from the client without a position check | a client can trigger scenario area events from anywhere (unchecked input) | check the player's position against the area |
| Z02-B13 | 0x2017 / 0x2019, 0x2030, 0x2035, 0x205E | log / profiler strings name the wrong handler ("…_STOP_REQ", "…_GATHERSTART_REQ", "…GATHERCOMPLETE_REQ", "…COMPULSORY_DIVORCE_REQ") | cosmetic: misleading logs | the handler's own name |

## 15. Not reconstructed / uncertain

- **Names.** 0x2035's profiler string is `sp_NC_ACT_GATHERCOMPLETE_REQ` (copy-paste in the original); the registered
  opcode and its own logs ("…PRODUCE_CAST_REQ : Skill cannot found") make it NC_ACT_PRODUCE_CAST_REQ. 0x205E's
  string is `…COMPULSORY_DIVORCE_REQ`, its log says `…DIVORCE_REFUSE_CMD`; the PDB name NC_ACT_WEDDING_DIVORCE_REFUSE_CMD
  is used. FUN_005a2330 (0x2053) has no profiler string; named from its log text.
- `hnd` (third handler argument) is read as the player's own handle from how it is used; the dispatcher passes the
  session's second argument, which was not traced to its source.
- `+0x1e78` bit 5 (vt 0xf20) blocks movement like Fear; its setter was not found.
- `moveattr` in 0x2018/0x201A: only bit 0 is cleared, the rest is whatever `g_buf` held.
- Which client action still sends 0x2003/0x2005 (the 2016 client ignores their broadcasts).
- 0x1C01: the requester's abstate list is sent to the *looked-up object* (as read); a player looking up another
  player therefore sends its own abstates to that player (Z02-B3).
- Sight: how objects that leave sight are removed on the client (no 0x1C0E sender in the zone).
- `sp_AmpersandCommand`: the per-command behaviour and admin levels of the 119 `&` commands.
- Roar delivery after the item cast (p+0x2a79c, ring DAT_008598c0); FUN_005b92a0 after an accepted proposal.
- The portal roles ID_Portal / Mode_ID_Portal / RandomMulti_Portal and `smfm_LinkToDungeon` were not traced line by line.
- How the proposal partner (`Partner.RegisterNumber`) is set before 0x204F; WeddingHall `wh_Reserv` and the hall timetable.
- Event numbers 0x20 (click) and 0x3c (menu answer) passed to `so_AIScriptFuncExec` are read from the calls; the
  AI-script side is Z09.
- `p+0x5cb9` bit 2 (menu without range limit) setter; `FUN_005cc2a0/2d0` events 0x29/0x2a in the class/shape block.
- 0x2057 on a mode failure carries 0xAC stale bytes after the error code (Z02-B10).
