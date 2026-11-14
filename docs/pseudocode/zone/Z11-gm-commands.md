# Zone: GM ampersand (&) commands (Z11)

Source: `Files/Server/2016/w00_Zone00/5ZoneServer2.exe` (all four zones are identical). Read the code with
`python3 -I tools/protocol-re/clean.py re-data/exports/zone-pdb - <addr>` (official names and types from the NA2016
`Zone.pdb`, same build; names marked *(pdb2016)* once below) or `re-data/exports/zone` with `tools/protocol-re/names/zone`.
Evidence markers as in `AGENTS.md`: *(inferred)*, *(pdb2017)*, *(fh-doc)* (FiestaHeroes `docs/GM_Commands.md`,
third-party, written for the NA2016 set). Player vtable slots `vt 0x…` were resolved with `tools/protocol-re/rtti.py`
against the PDB function names (method in `docs/knowledge/Z11.md`).

Every command answers its GM with notice lines (`ac_wall` → 0x2011, §1.5). "Self" below is the GM who typed the line.

## 1. The command system

### 1.1 Entry: chat line → command  (registered nowhere; called from chat)

The only entry is the normal chat request 0x2001 `NC_ACT_CHAT_REQ` (Z02 §3.1 FUN_0045a400): after the mode (1…6) and
field checks, before the map's "Chat" flag, the spam check and the chat ban. So `&` commands work on maps that forbid
chat and while the GM is chat-banned. Shout (0x201E), whisper and party chat do not reach it.

```pseudo
sp_AmpersandCommand(p, hnd, PROTO_NC_ACT_CHAT_REQ *req) → bool        @ FUN_0041a060   (Z02 §3.3)
    if req.content[0] != '&': return false                 # (len is not checked: a 0-length line tests a stale byte)
    if req.len > 100: req.len = 100; req.content[100] = 0
    p.so_ply_AdminCommand(req.content, req.len)            # vt 0x964
    return true                                            # never shown as chat, also for players with level 0

ShinePlayer::so_ply_AdminCommand(p, text, len)                          @ FUN_00427a40
    char line[256] = text[0..len); line[len] = 0
    it = ListIter_AmpCmdArgument(p.handle, p, line)        # §1.2 (also writes the log line, §1.5)
    notFound = ampcmd.l_4AllInList(it)                     # List::l_4AllInList FUN_00487c50: walks the active
                                                           # elements in list order, calls it.lid_Call(elem) until
                                                           # one returns 0 (= the first element with that word)
    if notFound and p.so_AdministratorLevel() ≠ 0:         # vt 0x4d4
        ac_wall(p, sprintf("Invalid command : %s", it.liaca_command))
    # a known word whose level is too high for p: no answer at all (lid_Call returns 0 = "found")
    # a player with level 0: no answer to anything

ListIter_AmpCmdArgument::lid_Call(it, AmpersandCommandElement *e) → u8   @ FUN_00419b80
    if e.ace_command ≠ it.liaca_command (all 20 bytes, case-sensitive): return 1   # keep looking
    if it.liaca_admin.so_AdministratorLevel() (u8) ≥ e.ace_adminlevel:
        e.ace_func(it.liaca_handle, it.liaca_admin, it.liaca_argnum, it.liaca_args)
    return 0                                               # stop
```

Every handler has the signature `AmpersandCommand::ac_X(u16 handle, ShinePlayer *gm, int argnum, char args[12][33])`
*(pdb2016)*: `argnum` counts the command word, so `argnum == 2` means one argument and `args[0]` is the first argument
after the word. Handlers act on `gm` (the `handle` is the GM's own object handle).

### 1.2 Parsing: `ListIter_AmpCmdArgument`

`ListIter_AmpCmdArgument` (0x1b0 bytes, *(pdb2016)*): +0x04 `Name5 liaca_command`, +0x18 `char liaca_args[12][33]`,
+0x1a4 `int liaca_argnum`, +0x1a8 `u16 liaca_handle`, +0x1ac `ShinePlayer *liaca_admin`.

```pseudo
ListIter_AmpCmdArgument(it, handle, admin, line)                       @ FUN_00427550
    lv = admin.so_AdministratorLevel()
    if lv ≠ 0 and lv < 101:                               # levels 101…255 are not logged: (original bug) Z11-B1
        AmpersandCommandLog << "[" << admin.so_CharName() (vt 0x56c) << "] " << line << LF
    args[i][0] = 0 for i in 0..11
    tokens = tokenize(line, delimiters " ", preserve "", quote "\"", escape "\\")
        # std::string tokenizer (the CodeProject `tokenize` signature, *(inferred)* from the arguments):
        # words separated by spaces, "…" keeps spaces inside one word, \ escapes
    if tokens is empty: return                             # cannot happen: the line starts with '&'
    liaca_command = tokens[0] (strncpy 20 bytes into the zeroed Name5)
    n = min(len(tokens) − 1, 12)                           # extra words are dropped
    for i in 0..n−1: strncpy(args[i], tokens[i+1], 32)     # pads with 0 up to 32; byte 32 is never written:
        # a word of 32+ characters has no terminator and runs into stack garbage and the next slot
        # (original bug) Z11-B2
    liaca_admin = admin; liaca_handle = handle; liaca_argnum = n + 1
```

The whole line is at most 100 characters (§1.1). Command words are case-sensitive (`&HP`, `&RegenNPC`, `&startGT`,
`&Reroadkingdomquest` must be typed exactly so).

### 1.3 The command table `ampcmd` (DAT_0087c770)

`AmpersandCommand` (0x2818 bytes) derives from `List<AmpersandCommandElement>` (capacity 256, `l_MakeList(0x100)`)
and holds the elements inline: +0x18 `AmpersandCommandElement ac_command[256]`, element = { +0 `Name5 ace_command`
(20-byte word incl. '&'), +0x14 `int ace_adminlevel`, +0x18 pointer-to-member `ace_func` (16 bytes) } *(pdb2016)*.
The global `ampcmd` is built by the static initializer `_dynamic_initializer_for__ampcmd__` FUN_00694f40 (before
`main`) and destroyed at exit (FUN_0069c420).

```pseudo
AmpersandCommand::AmpersandCommand(ac)                                 @ FUN_00425b70
    l_MakeList(256); link every ac_command[i] into the free list
    169 × ac_Store(word, level, handler)                   # table §2, in this order
AmpersandCommand::ac_Store(ac, word, level, func)                      @ FUN_0041a310
    e = next free element; none → assert "Too many AmpersandCommand", ShineExit("AmpersandCommand::ac_Store")
    e.ace_command = strncpy(word, 20); e.ace_adminlevel = level; e.ace_func = func
```

169 words, 154 distinct handlers: 15 Korean aliases share the handler of an English word (`&숨어` = `&hide`, `&보여`
= `&show`, `&캐추적` = `&pfind`, `&몹추적` = `&mfind`, `&추방` = `&kickout`, `&이동` = `&linkto`, `&캐소환` = `&psummon`,
`&경험치보너스` = `&expbonus`, `&아이템보너스` = `&itembonus`, `&필드보너스` = `&fieldbonus`, `&조용히` = `&silence`, `&ㅋ` =
`&z`, `&쿨타임무시` = `&ignoreskillcooltime`, and `&루아인수` alone for `ac_LuaSec`); the strings are CP949 in the exe
(addresses 0x6a91fc…0x6a93e4, read by pushing order of FUN_00425b70). `&&&`, `&disposition` and `&slotmachine` point
at FUN_00402370, an empty function shared by identical-code folding (its PDB name `ShineObject::so_ply_CardRegist`
is one of the folded names): typing them does nothing. Of the 158 `AmpersandCommand::ac_*` functions, 153 are
handlers and 5 are helpers that no word reaches: `ac_wall`, `ac_Store`, `ac_Scanf`, `ac_TempLinkUsage`,
`ac_MobBreedUsage`.

### 1.4 Admin levels

- **Source.** The level is per character: `tCharacter.nAdminLevel` (D02 §4.1 `GetCharBaseData`, `nAdminLevel u8 → adminlevel`),
  loaded into `sp_CharData.toclient.basedata.adminlevel` = player +0x7fa1 (Z07 §1.1, `S01-player-offsets.tsv`) and read through
  `so_AdministratorLevel` (vt 0x4d4, FUN_00559740; non-players return 0). New characters get 0: the WM sends
  0x1402 `NC_AVATAR_CREATEDATA_REQ` with `adminlevel = 0` (W01 §4.1). No packet and no command changes it in the
  2016 zone; it is set in the database by an operator *(inferred: the only writer found is character creation)*.
  `&adminlevel` only prints it.
- **Client.** At login complete the zone sends 0x10C6 `NC_CHAR_ADMIN_LEVEL_INFORM_CMD { u8 nAdminLevel }` when the level
  is not 0 (Z01 §6); the 2016 client stores only `level ≠ 0` (GameFrameWork +0x92, `re-data/client-handlers.json`).
- **Check.** A command runs when `level ≥ ace_adminlevel` (§1.1). Levels used: 1, 10, 50, 100. A level-255 character can
  run everything.
- **Override table `AdminLvSet.shn`.** Loaded into `gAdminLvSet` (DAT_13388398) in `zs_start_sleep` (Z01 §2.2, stage table); row
  `AdminLvSet { char ALS_Cmd[19]; u8 ALS_Lv; }` (0x14 bytes, DataVersionKey 5) *(pdb2016)*. Right after the load,
  `zs_start_sleep` calls:

```pseudo
AmpCmdInit()                                                           @ FUN_00419f50
    for each row r of gAdminLvSet:
        GetRecord fails → ShineExit("ZoneServer::zs_start_old")
        if 1 ≤ r.ALS_Lv ≤ 100:                             # 0 and 101…255 are ignored
            ampcmd.l_4AllInList(ListIter_AmpCmdLevel("&" + r.ALS_Cmd[0..19), r.ALS_Lv))
ListIter_AmpCmdLevel(it, cmd, lv)                                      @ FUN_00419cd0   (liaml_sCommand = "&"+cmd, 20 bytes; liaml_nAdminLevel = lv)
ListIter_AmpCmdLevel::lid_Call(it, e)                                  @ FUN_00419e60
    if e.ace_command == it.liaml_sCommand: e.ace_adminlevel = it.liaml_nAdminLevel; return 0   # first match only
    return 1
```

  The rows have no '&' (the code adds it); an unknown word changes nothing. The 2016 table (54 rows, identical in
  `Files/Server/NA2016`) lists 42 English words and their 12 Korean aliases (`필드보너스` twice). Only three rows
  change a level: `scrint` 10 → 50, `templink` 10 → 50, `oxblock` 100 → 50; the other 51 repeat the built-in level.
  Column "Level" in §2 shows "built-in → effective" where they differ. The FiestaHeroes list *(fh-doc)* gives the
  built-in levels (it shows `&scrint` 10).

### 1.5 Replies and the command log

```pseudo
AmpersandCommand::ac_wall(ac, p, text)                                 @ FUN_0041a160
    p.so_ply_Notice(text)                                  # vt 0x784
ShinePlayer::so_ply_Notice(p, text)                                    @ FUN_005977e0
    send to p 0x2011 NC_ACT_NOTICE_CMD { u8 (not written: (original bug) Z09-B54), u8 len = strlen(text) & 0xFF,
                                         char text[len] }   (no NUL)
    # 2016 game scene: shown as an announce line "[Notice] %s" (Z09 §19.3)
```

`AxialListWall(text)` (FUN_004281a0, `ali_Work` FUN_004281c0) is the same notice for every object of an
`so_AllInMap` / `so_AllOfRange` walk (Z09 §19.3).

`AmpersandCommandLog` (DAT_0087c4e8, a `DebugLogging`, initializer FUN_00694f00, `EraseOldLogList` FUN_005aa080
registers the name for old-log cleanup): every `&` line typed by a character with level 1…100, valid or not, as
`[<charName>] <line>`. File name = `dl_MakeFileName` FUN_00419100 `"%s%s%02d.txt"` = `AmpersandCommandLog` + `YYYYMMDD` +
two digits *(inferred: the hour)*, opened with `"a+"` by `dl_FilePoint` FUN_004191b0, each line prefixed `"HH:MM:SS : "`.

### 1.6 Helpers

| Function | Meaning |
|---|---|
| `ac_Scanf(text)` FUN_0041a290 | `sscanf(text, "%d")`, the parsed int (0 for no number) |
| `ac_TempLinkUsage(p)` FUN_0041a210 | four usage lines of `&templink` (§2 row, part 2) |
| `ac_MobBreedUsage(p)` FUN_0041a260 | two usage lines of `&mobbreed` (part 2) |

Numbers are read with `atoi` or `ac_Scanf`: a missing or non-numeric argument reads as 0, never as an error.

## 2. All commands

Order = registration order in FUN_00425b70 (= `ampcmd` list order). "Level": built-in → effective after
`AdminLvSet` (§1.4). Rows marked "(part n)" are documented by a later part of this item (status file).

| # | Word | Handler | Level (reg → eff.) | Syntax | Effect | Packets | § |
|---|---|---|---|---|---|---|---|
| 1 | `&hide` | ac_Hide `0041a3a0` | 10 | — | leave sight, sub-layer 3, abstate STA_GMHIDEMODE; refused in a mini-house | 0x2011 on refusal; abstate inform (Z03) | §3.1 |
| 2 | `&숨어` | ac_Hide `0041a3a0` | 10 | — | leave sight, sub-layer 3, abstate STA_GMHIDEMODE; refused in a mini-house | 0x2011 on refusal; abstate inform (Z03) | §3.1 |
| 3 | `&show` | ac_Show `0041a4d0` | 10 | — | clear STA_GMHIDEMODE, sub-layer 0; refused in a mini-house | abstate reset (Z03) | §3.1 |
| 4 | `&보여` | ac_Show `0041a4d0` | 10 | — | clear STA_GMHIDEMODE, sub-layer 0; refused in a mini-house | abstate reset (Z03) | §3.1 |
| 5 | `&pfind` | ac_FindPlayer `0041d050` | 10 | (part 3) | | | |
| 6 | `&캐추적` | ac_FindPlayer `0041d050` | 10 | (part 3) | | | |
| 7 | `&mfind` | ac_FindMob `0041cf90` | 10 | (part 3) | | | |
| 8 | `&몹추적` | ac_FindMob `0041cf90` | 10 | (part 3) | | | |
| 9 | `&kickout` | ac_KickOutPlayer `0041cec0` | 10 | (part 2) | | | |
| 10 | `&추방` | ac_KickOutPlayer `0041cec0` | 10 | (part 2) | | | |
| 11 | `&linkto` | ac_LinkTo `0041a7e0` | 10 | `[<map> [<x> <y>]]` / `-` | teleport to a map (default regen point) or, without argument, to a free spot of the current map; `-` = back to the normal location | 0x1809 (same zone) or zone change (Z01 §6) | §3.1 |
| 12 | `&이동` | ac_LinkTo `0041a7e0` | 10 | `[<map> [<x> <y>]]` / `-` | teleport to a map (default regen point) or, without argument, to a free spot of the current map; `-` = back to the normal location | 0x1809 (same zone) or zone change (Z01 §6) | §3.1 |
| 13 | `&psummon` | ac_SummonPlayer `0041d140` | 10 | (part 3) | | | |
| 14 | `&캐소환` | ac_SummonPlayer `0041d140` | 10 | (part 3) | | | |
| 15 | `&expbonus` | ac_BonusExp `0041e190` | 50 | (part 3) | | | |
| 16 | `&경험치보너스` | ac_BonusExp `0041e190` | 50 | (part 3) | | | |
| 17 | `&itembonus` | ac_BonusItem `0041e2d0` | 50 | (part 3) | | | |
| 18 | `&아이템보너스` | ac_BonusItem `0041e2d0` | 50 | (part 3) | | | |
| 19 | `&fieldbonus` | ac_FieldBonus `0041e410` | 50 | (part 3) | | | |
| 20 | `&필드보너스` | ac_FieldBonus `0041e410` | 50 | (part 3) | | | |
| 21 | `&silence` | ac_KeepFromChat `0041e090` | 100 | (part 3) | | | |
| 22 | `&조용히` | ac_KeepFromChat `0041e090` | 100 | (part 3) | | | |
| 23 | `&distribute` | ac_PlayerDistribute `00422f90` | 10 | (part 6) | | | |
| 24 | `&isblock` | ac_IsBlock `0041e880` | 10 | (part 3) | | | |
| 25 | `&mobdist` | ac_MobDistribute `0041d250` | 10 | (part 3) | | | |
| 26 | `&chargeditem` | ac_ChargedItem `0041d2f0` | 100 | (part 3) | | | |
| 27 | `&parameterview` | ac_ParameterView `0041e7d0` | 100 | (part 3) | | | |
| 28 | `&adminlevel` | ac_AdminLevel `0041a650` | 1 | — | "Admin level is %d" | 0x2011 | §3.2 |
| 29 | `&serverindex` | ac_ServerIndex `0041a730` | 100 | — | prints the build tag "20120409-Hero[Release]-1" | 0x2011 | §3.2 |
| 30 | `&makeitem` | ac_MakeItem `0041b8a0` | 100 | (part 2) | | | |
| 31 | `&cleariv` | ac_ClearInventory `0041bbd0` | 1 | (part 2) | | | |
| 32 | `&dimension` | ac_Dimension `0041a5a0` | 100 | `<n>` | leave sight, layer main number = n | — | §3.1 |
| 33 | `&doorbuild` | ac_DoorBuild `0041aa50` | 100 | `<mobIndex> <x> <y> <dir> <scale>` | spawn a door object (kind 7) on the current map/layer | door appear (Z09 §13.1) | §3.3 |
| 34 | `&mobbreed` | ac_MobBreed `0041b510` | 50 | (part 2) | | | |
| 35 | `&mb` | ac_MobBreed_simple `0041b790` | 50 | (part 2) | | | |
| 36 | `&fullpoint` | ac_fullpoint `0041be90` | 50 | (part 2) | | | |
| 37 | `&summonplayer` | ac_summonplayer `0041bf50` | 100 | (part 2) | | | |
| 38 | `&performance` | ac_performance `0041c8d0` | 10 | (part 2) | | | |
| 39 | `&sethp` | ac_Sethp `0041c9d0` | 100 | (part 2) | | | |
| 40 | `&setsp` | ac_Setsp `0041cad0` | 100 | (part 2) | | | |
| 41 | `&dist` | ac_Dist `0041cbc0` | 10 | (part 2) | | | |
| 42 | `&coord` | ac_CurrentLoc `0041cd60` | 10 | (part 2) | | | |
| 43 | `&scrint` | ac_ScriptInterrupt `0041abe0` | 10 → **50** | `<block>` | raise an admin interrupt with that call block on the map's cinema script | — | §3.3 |
| 44 | `&timer` | ac_Timer `0041ad10` | 50 | `<sec>` | show a countdown to every player of the map | 0x0810 to the map | §3.3 |
| 45 | `&templink` | ac_TempLink `0041b2f0` | 10 → **50** | (part 2) | | | |
| 46 | `&oxblock` | ac_OXBlock `0041b1f0` | 100 → **50** | (part 2) | | | |
| 47 | `&z` | ac_NoticeZone `0041aeb0` | 10 | `<text…>` | notice line to every player of the map | 0x2011 to the map | §3.3 |
| 48 | `&ㅋ` | ac_NoticeZone `0041aeb0` | 10 | `<text…>` | notice line to every player of the map | 0x2011 to the map | §3.3 |
| 49 | `&gmchat` | ac_GMChat `0041b030` | 1 | — | GM chat colour on; WM keeps it | WM 0x083D | §3.5 |
| 50 | `&gldcollectclear` | ac_GuildCollectClear `0041ae10` | 100 | — | nothing (empty body) | — | §3.6 |
| 51 | `&gldcollectset` | ac_GuildCollectSet `0041ae60` | 100 | — | nothing (empty body) | — | §3.6 |
| 52 | `&questgiveup` | ac_questgiveup `0041c190` | 100 | (part 2) | | | |
| 53 | `&questrecieve` | ac_questrecieve `0041c140` | 100 | (part 2) | | | |
| 54 | `&questcomplete` | ac_questcomplete `0041c1e0` | 100 | (part 2) | | | |
| 55 | `&learnskill` | ac_learnskill `0041c290` | 100 | (part 2) | | | |
| 56 | `&skillcooltime` | ac_skillcooltime `0041c3c0` | 100 | (part 2) | | | |
| 57 | `&setabstate` | ac_Setabstate `0041c410` | 100 | (part 2) | | | |
| 58 | `&resetabstate` | ac_resetabstate `0041c620` | 100 | (part 2) | | | |
| 59 | `&setabstatetarget` | ac_SetAbstateTarget `0041c6e0` | 100 | (part 2) | | | |
| 60 | `&resetabstatetarget` | ac_ReSetAbstateTarget `00423ba0` | 100 | (part 6) | | | |
| 61 | `&kqreward` | ac_KQReward `00423cc0` | 100 | (part 6) | | | |
| 62 | `&killallmob` | ac_killallmob `0041d3c0` | 50 | (part 3) | | | |
| 63 | `&mobdamage` | ac_mobdamage `0041d460` | 100 | (part 3) | | | |
| 64 | `&suicideallmob` | ac_SuicideAllMob `0041d540` | 50 | (part 3) | | | |
| 65 | `&suicidemob` | ac_SuicideMob `0041d620` | 100 | (part 3) | | | |
| 66 | `&kingdomquest` | ac_KingdomQuest `00423dd0` | 100 | (part 6) | | | |
| 67 | `&Reroadkingdomquest` | ac_ReroadKingdomQuest `0041dc80` | 100 | (part 3) | | | |
| 68 | `&endofkq` | ac_EndOfKingdomQuest `0041dbd0` | 100 | (part 3) | | | |
| 69 | `&guildtournament` | ac_GuildTournament `0041da30` | 100 | (part 3) | | | |
| 70 | `&zonelink` | ac_ZoneLinkTest `0041d950` | 100 | (part 3) | | | |
| 71 | `&block` | ac_BlockMatrix `0041ccb0` | 100 | (part 2) | | | |
| 72 | `&emptymap` | ac_EmptyMap `0041d850` | 100 | (part 3) | | | |
| 73 | `&serversocketcut` | ac_ServerSocketCut `0041d760` | 100 | (part 3) | | | |
| 74 | `&staticdamage` | ac_staticdamage `0041dfd0` | 50 | (part 3) | | | |
| 75 | `&deathaura` | ac_deathaura `0041dd70` | 100 | (part 3) | | | |
| 76 | `&immortal` | ac_immortal `0041ddf0` | 10 | (part 3) | | | |
| 77 | `&enterminihouse` | ac_EnterMiniHouse `0041df80` | 100 | (part 3) | | | |
| 78 | `&horsespeed` | ac_HorseSpeed `0041ded0` | 100 | (part 3) | | | |
| 79 | `&charinform` | ac_CharInform `0041e510` | 10 | (part 3) | | | |
| 80 | `&partyinfo` | ac_PartyInform `0041e5e0` | 100 | (part 3) | | | |
| 81 | `&propose` | ac_Propose `0041e9d0` | 100 | (part 4) | | | |
| 82 | `&proposeres` | ac_ProposeRes `0041eb30` | 100 | (part 4) | | | |
| 83 | `&weddingreset` | ac_WeddingReset `0041ec70` | 100 | (part 4) | | | |
| 84 | `&reserve` | ac_WeddingReserve `0041ed70` | 100 | (part 4) | | | |
| 85 | `&enterready` | ac_WeddingGuestEnterReady `0041ee40` | 100 | (part 4) | | | |
| 86 | `&enter` | ac_WeddingGuestEnter `0041ef10` | 100 | (part 4) | | | |
| 87 | `&learnpassive` | ac_learnPassive `0041f270` | 100 | (part 4) | | | |
| 88 | `&unlearn` | ac_Unlearnskill `0041f050` | 100 | (part 4) | | | |
| 89 | `&unlearnpassive` | ac_UnlearnPassive `0041f160` | 100 | (part 4) | | | |
| 90 | `&wedding` | ac_Wedding `0041f3a0` | 100 | (part 4) | | | |
| 91 | `&showid` | ac_ShowPlayerID `0041f4a0` | 100 | (part 4) | | | |
| 92 | `&mobhatchery` | ac_MobHatchery `0041f6c0` | 100 | (part 4) | | | |
| 93 | `&allcritical` | ac_AllCritical `0041f770` | 100 | (part 4) | | | |
| 94 | `&erasechargebuf` | ac_EraseChargeBuff `0041f620` | 100 | (part 4) | | | |
| 95 | `&startGT` | ac_StartGuildTournament `0041f850` | 100 | (part 4) | | | |
| 96 | `&flagcapture` | ac_FlagCapture `0041fa10` | 100 | (part 4) | | | |
| 97 | `&useguildskill` | ac_UseGuildSkill `0041fb20` | 100 | (part 4) | | | |
| 98 | `&observerlinkto` | ac_ObserverLinkTo `0041fc00` | 100 | (part 4) | | | |
| 99 | `&observerout` | ac_ObserverOut `0041fcb0` | 100 | (part 4) | | | |
| 100 | `&HP` | ac_HPChange `004248e0` | 100 | (part 6) | | | |
| 101 | `&SP` | ac_SPChange `00424a70` | 100 | (part 6) | | | |
| 102 | `&speed` | ac_EditSpeed `0041fd50` | 50 | (part 4) | | | |
| 103 | `&linktosavedata` | ac_LinktoSaveData `004194f0` | 100 | — | teleport to the current map's save-link point | as &linkto | §3.1 |
| 104 | `&reloaddata` | ac_ReLoadData `00424c00` | 100 | (part 6) | | | |
| 105 | `&captivate` | ac_Captivate `00424d60` | 100 | (part 6) | | | |
| 106 | `&ignoreskillcooltime` | ac_IgnoreSkillCoolTime `00424ec0` | 100 | (part 6) | | | |
| 107 | `&쿨타임무시` | ac_IgnoreSkillCoolTime `00424ec0` | 100 | (part 6) | | | |
| 108 | `&invenview` | ac_InventoryView `004206b0` | 100 | (part 4) | | | |
| 109 | `&runto` | ac_RunTo `0041fe20` | 100 | (part 4) | | | |
| 110 | `&ghostremove` | ac_GhostRemove `0041fef0` | 100 | (part 4) | | | |
| 111 | `&curtime` | ac_CurTime `0041ffb0` | 100 | (part 4) | | | |
| 112 | `&amibusy` | ac_AmIBusy `004200d0` | 100 | (part 4) | | | |
| 113 | `&knockback` | ac_KnockBack `00420350` | 100 | (part 4) | | | |
| 114 | `&partblock` | ac_PartBlock `00420470` | 100 | (part 4) | | | |
| 115 | `&debuglogging` | ac_DebugLogging `00420760` | 100 | (part 4) | | | |
| 116 | `&&&` | (no-op) `00402370` | 100 | — | nothing: empty function FUN_00402370 | — | §3.6 |
| 117 | `&npcrevive` | ac_NPCRevive `004231a0` | 100 | (part 6) | | | |
| 118 | `&ts_DiceFix` | ac_TaiSai_DiceFix `00420860` | 100 | (part 4) | | | |
| 119 | `&ts_DiceProbability` | ac_TaiSai_DiceProbability `004209f0` | 100 | (part 4) | | | |
| 120 | `&GB_DiceFix` | ac_Gamble_TaiSai_DiceFix `00420bb0` | 100 | (part 4) | | | |
| 121 | `&GB_DiceProbability` | ac_Gamble_TaiSai_DiceProbability `00420d30` | 100 | (part 4) | | | |
| 122 | `&makeraid` | ac_makeraid `00420ef0` | 100 | (part 5) | | | |
| 123 | `&outraid` | ac_outraid `00421040` | 100 | (part 5) | | | |
| 124 | `&inraid` | ac_inraid `00423330` | 100 | (part 6) | | | |
| 125 | `&PlayIns` | ac_PlayInstanceDungeon `00421190` | 100 | (part 5) | | | |
| 126 | `&bigbang` | ac_BigBang `004240d0` | 100 | (part 6) | | | |
| 127 | `&alllearnskill` | ac_AllLearnSKill `004212e0` | 100 | (part 5) | | | |
| 128 | `&levelup` | ac_LevelUp `00421710` | 100 | (part 5) | | | |
| 129 | `&showallchar` | ac_ShowAllChar `00423480` | 100 | (part 6) | | | |
| 130 | `&루아인수` | ac_LuaSec `0041e6d0` | 100 | (part 3) | | | |
| 131 | `&testlink` | ac_TestLink `004217e0` | 50 | (part 5) | | | |
| 132 | `&gtieffect` | ac_GuildTournamentItemEffect `004218b0` | 50 | (part 5) | | | |
| 133 | `&iareset` | ac_ItemActionCoolTimeReset `00421990` | 50 | (part 5) | | | |
| 134 | `&queststart` | ac_QuestStartReq `00419500` | 50 | `[<questId>]` | runs the client handler 0x4414 for that quest (Z08 §3.2) | as 0x4414 | §3.4 |
| 135 | `&questread` | ac_QuestReadReq `00419540` | 50 | `[<questId>]` | runs the client handler 0x4416 (Z08 §3.2) | as 0x4416 | §3.4 |
| 136 | `&disposition` | (no-op) `00402370` | 50 | — | nothing: empty function FUN_00402370 | — | §3.6 |
| 137 | `&idtimechange` | ac_IDTimeChange `00419580` | 50 | `[<min>]` (10) | set the party's instance-dungeon time limit to n minutes | 0x0810 to self; 0x2011 | §3.3 |
| 138 | `&releasechatban` | ac_ReleaseChatBan `00421a60` | 50 | (part 5) | | | |
| 139 | `&slotmachine` | (no-op) `00402370` | 1 | — | nothing: empty function FUN_00402370 | — | §3.6 |
| 140 | `&godofslotmachine` | ac_GodOfSlotMachine `00419790` | 100 | `<9 symbols>` | force the next slot-machine screens | — | §3.4 |
| 141 | `&viewaggrolist` | ac_ViewAggroList `004196f0` | 50 | — | aggro list of the current target (or self) as notices | 0x2011 | §3.4 |
| 142 | `&ebcu` | ac_EquipBelongedCancelUse `00421b00` | 50 | (part 5) | | | |
| 143 | `&luaobserver` | ac_LuaObserver `00419730` | 100 | `[x]` | with an argument: self becomes the Lua observer; without: observer cleared | 0x2011 later (Z09 §14.7) | §3.4 |
| 144 | `&luafuncexec` | ac_LuaFuncExec `00419760` | 100 | `<func> <arg>` | call a Lua function of the current target's AI script | — | §3.4 |
| 145 | `&mobitemdrop` | ac_MobItemDrop `00421ba0` | 100 | (part 5) | | | |
| 146 | `&getmoney` | ac_GetMoney `00421bf0` | 100 | (part 5) | | | |
| 147 | `&fnpc` | ac_FindNPC `00421cb0` | 100 | (part 5) | | | |
| 148 | `&RegenNPC` | ac_RegenNPC `00421e50` | 100 | (part 5) | | | |
| 149 | `&ReleaseNPC` | ac_ReleaseNPC `00421fc0` | 100 | (part 5) | | | |
| 150 | `&gmtestmode` | ac_GMTestMode `00425020` | 100 | (part 6) | | | |
| 151 | `&arrangeiv` | ac_ArrangeInven `004197e0` | 100 | — | start an inventory auto-arrange (Z04 §12.5) | inventory packets (Z04) | §3.4 |
| 152 | `&cmt` | ac_CameraMoveTest `004220c0` | 100 | (part 5) | | | |
| 153 | `&reloadid` | ac_IndunReload `00419810` | 100 | `<map>` | drop all running films of the instance map and reload its script | — | §3.3 |
| 154 | `&vie` | ac_ViewSlot_Equip `00419890` | 100 | `<itemIndex>` | preview an item in a view slot (Z09 §17.8) | equipment change to sight | §3.4 |
| 155 | `&viue` | ac_ViewSlot_UnEquip `004198e0` | 100 | `<slot>` | clear one view slot | equipment change to sight | §3.4 |
| 156 | `&viuea` | ac_ViewSlot_UnEquipAll `00419910` | 100 | — | clear all view slots (Z09 §17.8) | equipment change to sight | §3.4 |
| 157 | `&setlp` | ac_Setlp `00422330` | 100 | (part 5) | | | |
| 158 | `&movelayer` | ac_MoveNewLayer `00419930` | 100 | `<layerType> <numberType>` | move self to a new layer (base/tutorial × base/charNo) | sight (Z06 §1) | §3.1 |
| 159 | `&moveotherlayer` | ac_MoveOtherLayer `00419970` | 100 | `<charNo>` | move self to that player's layer | sight | §3.1 |
| 160 | `&godmode` | ac_GodMode `00422350` | 100 | (part 5) | | | |
| 161 | `&fieldmobcount` | ac_FieldMobCount `00425290` | 100 | (part 6) | | | |
| 162 | `&reloadpetlua` | ac_PetSystemTest_LuaReload `00424740` | 100 | (part 6) | | | |
| 163 | `&getpetinfo` | ac_PetSystemTest_GetTendency `00422480` | 100 | (part 5) | | | |
| 164 | `&setpetinfo` | ac_PetSystemTest_SetTendency `00422590` | 100 | (part 5) | | | |
| 165 | `&vanishdropitem` | ac_VanishDropItem `00422800` | 100 | (part 5) | | | |
| 166 | `&walkto` | ac_WalkTo `004228c0` | 100 | (part 5) | | | |
| 167 | `&castteleport` | ac_CastTeleport `004229b0` | 100 | (part 5) | | | |
| 168 | `&setobjectdirect` | ac_SetObjectDirect `00422a90` | 100 | (part 5) | | | |
| 169 | `&pvp` | ac_SetPVP `00420230` | 100 | (part 4) | | | |

## 3. Commands, part 1 (handlers FUN_004194f0 … FUN_0041b030)

### 3.1 Visibility, layers and teleports

```pseudo
&hide, &숨어   ac_Hide                                                @ FUN_0041a3a0
    if gm.so_ply_MH_GetActiveMH() (vt 0x130):              # inside a mini-house
        wall "fail to 'hide' : not allowed to do 'hide' in the MH"; return
    if gm.smo_GetMode() (vt 0x484) == 6 and sp_MoverSystem_Type(gm) == MVST_MOVER: sp_MoverSystem_GetOff(gm, 0)
    so_Logout(gm)                                          # FUN_0054b780: the others lose the GM from sight
    gm.so_layer.layer→l_Sub = 3                            # GM sub-layer: g_SubLayerCanSee hides it (Z09 §5.2 so_layer row)
    if gm.so_AbnormalState_Set(gm, STA_GMHIDEMODE (0x120), strength 1, dic_abstate entry, now, …, keep 0xFFFFFFFF, …)  (vt 0x638, Z03 §6.2):
        gm.so_AbnormalState_Inform(0x120, 4 200 000 000 ms, 0)                               (vt 0x3f0, Z03 §6.3)

&show, &보여   ac_Show                                                @ FUN_0041a4d0
    in a mini-house: wall "fail to 'show' : not allowed to do 'show' in the MH"; return
    gm.so_AbnormalState_Reset(0x120)                       # vt 0x650, Z03 §6.4
    gm.so_layer.layer→l_Sub = 0
    # no appear broadcast here: the others see the GM again on their next sight exchange *(inferred)*

&dimension <n>   ac_Dimension                                        @ FUN_0041a5a0
    so_Logout(gm); gm.so_layer.layer→l_Main = ac_Scanf(args[0])
    # objects of another main layer do not see each other; &dimension 0 returns to the normal layer *(inferred)*,
    # *(fh-doc)*: "Disable by passing 0"

&linkto, &이동 [<map> [<x> <y>]] | -   ac_LinkTo                     @ FUN_0041a7e0
    in a mini-house: wall "fail to 'linkto' : not allowed to do 'linkto' in the MH"; return
    if argnum == 1 (no argument) and gm has a field:
        args[0] = name of the current map; (x, y) = BlockingDistribute::bd_FindEmptyCoord(field.map…+0x42c)
        args[1], args[2] = "%d" x, y; argnum = 4           # = jump to a free spot of the same map
    if args[0][0] == '-': gm.so_ply_ToNormalLoc(0) (vt 0xa24, Z01 §7); return
    attr = FieldOption::fo_GetFieldAttr(fieldlist.fc_FieldOption, args[0])   # World/Field.txt row by server map name
    info = mapdatabox[attr.mapidclient]                    # MapInfo by client map id
    attr or info missing: wall "Invalid map name"; return
    link = { destMap = args[0] (12), destMapForClient = attr.mapidclient name (32), x, y }
    (x, y) = argnum == 4 ? (ac_Scanf(args[1]), ac_Scanf(args[2])) : (info.RegenX, info.RegenY)
    gm.so_LinkTo(link, 6, 9, 10)                           # vt 0x600, Z01 §7.1: same zone → 0x1809
                                                           # NC_MAP_LINKSAME_CMD, else the zone change
    # coordinates are used only with exactly two of them (argnum 4); otherwise the map's regen point

&linktosavedata   ac_LinktoSaveData                                  @ FUN_004194f0
    ShinePlayer::sp_LinktoCurMapSaveData(gm)               # FUN_00560170 (Z09 §22.4, note on fm_GetSaveLinktoData): the current map's save-link
                                                           # record (fm_GetSaveLinktoData) → so_LinkTo(rec, 6, 9, 10)

&movelayer <layerType> <numberType>   ac_MoveNewLayer                @ FUN_00419930
    t = atoi(args[0]); n = atoi(args[1])
    if t < 2 and n < 2: gm.so_ply_MoveNewLayer(t, n)       # vt 0xdbc FUN_0054ab90
        # LAYER_TYPE 0 LT_BASE / 1 LT_TUTORIAL, LAYER_NUMBER_TYPE 0 LNT_BASE / 1 LNT_CHAR_NUMBER *(pdb2016)*
        # negative values pass the check: (original bug) Z11-B3
ShinePlayer::so_ply_MoveNewLayer(p, t, n)                              @ FUN_0054ab90
    only when p.so_slantedlist.LayerRegistInfo.LayerRegNumber (+0x4e, u64) == 0 (base layer) and not in a mini-house:
    sp_tradebreak, sp_CloseStreetBooth, vt 0x8d0 (cancel the current action), dismount (horse: sp_HorseOff;
    mover: sp_MoverSystem_GetOff(2)), vt 0xdc4 (leave the old layer), LayerRegNumber = vt 0xdb8(t, n) (new
    layer number), vt 0xdd8 (enter it), re-mount the same mover/ride slot (vt 0xdd4)          (Z06 §1 lists the callers)

&moveotherlayer <charNo>   ac_MoveOtherLayer                         @ FUN_00419970
    o = som_FindPlayer(charNo = atoi(args[0]))             # FUN_00550360; absent: nothing
    gm.so_ply_MoveOtherLayer(so_GetLayerRegNum(o))         # vt 0xdc0 FUN_0054ac70: same steps as above without the
                                                           # base-layer test, LayerRegNumber = that number
```

### 3.2 Information

```pseudo
&adminlevel   ac_AdminLevel                                          @ FUN_0041a650
    wall sprintf("Admin level is %d", gm.so_AdministratorLevel())
&serverindex   ac_ServerIndex                                        @ FUN_0041a730
    wall serverindex                                       # DAT_0074d3d4 = "20120409-Hero[Release]-1" (build tag; also
                                                           # written to a file at start-up)
```

### 3.3 Map, script and instance tools

```pseudo
&doorbuild <mobIndex> <x> <y> <dir> <scale>   ac_DoorBuild              @ FUN_0041aa50
    id = mobdatabox.mdb_btree[args[0]]; unknown → wall "Invalid mob index"; return
    d = som_AllocObject(&h, kind 7)                        # a ShineDoor; none → wall "Too many doors"; return
    if d.so_door_Build(gm.field, x = scanf(args[1]), y = scanf(args[2]), dir = scanf(args[3]), h, id,
                       scale = scanf(args[4]), layer = so_GetLayerRegNum(gm)) ≠ 0:   # vt 0x6dc FUN_0043f7b0, Z09 §13.1
        wall "Make fail"; som_FreeObject(h, REMOVE_NOW, 0x27)
    # the door appears to the players around it through the normal door path (Z09 §13.1); it is not saved

&scrint <block>   ac_ScriptInterrupt                                 @ FUN_0041abe0
    argnum ≠ 2: wall "Called block needed"; return
    no field: wall "Null map"; return
    tok = PineScriptToken(args[0])                         # 256-byte token buffer
    field.CinemaComplex (+0x44).cc_ScriptInterrupt(sim_AdminInterrupt, { tok, u16 gm.handle })
        # Z09 §15.3 / §15.4: wakes a Pine script waiting with `waitinterrupt Admin` and hands it the call block
        # name and the GM's handle (sib_AdminInterrupt FUN_0050b780)

&timer <sec>   ac_Timer                                              @ FUN_0041ad10
    s = (u16) ac_Scanf(args[0]); s == 0 → wall "sec needed"; return
    to every player of gm's map (so_AllInMap, AxialListPacketBroadcast):
        0x0810 NC_MISC_RESTMINUTE_CMD { u8 flag = 1, u16 second = s }
    # client: stores the u16 (DAT_00a8315c, C01) = the map countdown display; no server-side timer is started

&idtimechange [<minutes>]   ac_IDTimeChange                          @ FUN_00419580
    no field: return (silently)
    mc = cm_FindMapCluster(mapclustermanager, field map name)   # none → wall "NotFind InstanceDungeon System"; return
    m = argnum == 2 ? atoi(args[0]) : 10;  m < 2 → 1       # (unsigned compare: negative numbers stay huge)
    reg = gm.so_PartyRegistNumber()                        # vt 0x550: the cluster's instance is keyed by party
    MapCluster::mc_SetLimitItem(mc, m, reg)                # FUN_0049f740: first instance with RegisterNumber == reg and
                                                           # bIsLimitTime: LimitExpirationTime interval = m × 600 ticks
                                                           # (tick = 0.1 s, so m minutes), next = now + interval
        fails → wall "Time Change Fail"; return
    if mc_GetLimitTime(mc, &rest, reg) (FUN_0049f610: rest = next − now ticks):
        send to gm 0x0810 { u8 1, u16 second = rest / 10 }
    wall "Time Change OK"
    # only the GM's own client gets the new countdown; the party members keep the old display until their next login

&reloadid <map>   ac_IndunReload                                     @ FUN_00419810
    info = fieldlist.fc_GetInstanceDungeonInfoByMapName(args[0] (12), ILT_NORMAL); none → nothing
    ClusterManager::cm_AllDropFilm(mapclustermanager, args[0][0])   # FUN_00486ec0 (Z14): stop every film of the instances
        # (passes only the first character of the name as the argument *(inferred: the decompiled call; Z14 owns the callee)*)
    ScenarioBookShelf::sbsReLoad(scenarioshelf, info.ScriptName)    # FUN_00507c90, Z09 §22.5: reload the instance script
        # (with Z09-B84/B96 a reload of a once-failed Pine book double-frees)

&z, &ㅋ <text…>   ac_NoticeZone                                      @ FUN_0041aeb0
    text = ""
    for i in 0 .. argnum−1:                                # argnum counts the word: one slot more than there are
        if i > 0: text += " "                              #   arguments → always a trailing space, and with 12
        if strlen(text) + 33 > 255: stop                   #   arguments args[12] = the bytes of liaca_argnum
        text += args[i]                                    #   (original bug) Z11-B4
    to every object of gm's map: AxialListWall(text)       # players: 0x2011 NC_ACT_NOTICE_CMD "[Notice] …"
    # *(fh-doc)* calls it "GM Shout"; on the wire it is a notice, not a shout
```

### 3.4 Debug wrappers around other handlers

```pseudo
&queststart [<questId>]   ac_QuestStartReq                           @ FUN_00419500
    fake NETCOMMAND in g_buf: u16 opcode 0x5011 (unchecked filler), u16 nQuestID = argnum == 2 ? atoi(args[0]) : 0xFFFF
    sp_NC_QUEST_START_REQ(gm, cmd, len 2, handle 0xFFFF)   # FUN_00578e90 = 0x4414 handler, Z08 §3.2
&questread [<questId>]   ac_QuestReadReq                             @ FUN_00419540
    same with opcode filler 0x5811 → sp_NC_QUEST_READ_REQ  # FUN_00578f90 = 0x4416 handler, Z08 §3.2

&viewaggrolist   ac_ViewAggroList                                    @ FUN_004196f0
    t = gm.so_CurrentTargetObject() (vt 0x75c) or gm itself
    if gm has a field: t.vt[0x6fc](gm)                     # mob/NPC: ShineMob::so_mob_ViewAggroList FUN_0042d2a0
                                                           # (Z09 §6.8): one notice "%d) %s : %d" per aggro entry;
                                                           # players: folded no-op (so_ply_CollectCardOpen)

&luaobserver [x]   ac_LuaObserver                                    @ FUN_00419730
    g_LuaScriptObserver = args[0] non-empty ? gm : null    # LuaScriptObserver::operator= FUN_005d5f00 (Z09 §14.7):
                                                           # Lua errors and cDebugLog lines then go to gm as notices

&luafuncexec <func> <arg>   ac_LuaFuncExec                           @ FUN_00419760
    t = gm.so_CurrentTargetObject(); none → nothing
    t.so_AIScriptFuncExec(args[0], args[1])                # vt 0xb6c FUN_004aa0b0 (Z09 §14.3): call that function of
                                                           # the target's Lua AI with one string argument

&godofslotmachine [<9 symbols>]   ac_GodOfSlotMachine                @ FUN_00419790
    copy args[0] (max 9 characters, NUL-terminated) into gm.sp_GodOfSlotMachine (char[10], vt 0xb58 FUN_0061ddf0)
    # used by SlotMachineScreenManager::smsm_Action FUN_006228f0 (from SMS_StopButton FUN_00625340, Z06 §5)
    # on every stop of gm's slot machine while the string has exactly 9 characters:
    #   symbol(c) = c − '0' (c < 'A') or c − 'A' + 10, values > 8 → 0
    #   chars 0‑2 → screen row 2, chars 3‑5 → row 1, chars 6‑8 → row 0 (columns left to right)
    #   instead of the jackpot roll and the card deck; the payout is computed from that screen as usual
    # the string stays until the GM types &godofslotmachine without a 9-character argument (or relogs: cleared
    # in the player constructor)

&arrangeiv   ac_ArrangeInven                                         @ FUN_004197e0
    gm.so_ply_SetArrangeInven(1) (vt 0xd18 FUN_00560dc0); gm.so_ply_ArrangeInven() (vt 0xd1c FUN_00563500)
    # = the auto-arrange of 0x304A without its checks and its 0x30A8 answer (Z04 §12.5, Z05 §4)

&vie <itemIndex>   ac_ViewSlot_Equip                                 @ FUN_00419890
    id = itemdatabox.idb_btree[args[0]] (unknown → 0xFFFF); gm.so_ply_ViewSlot_Equip(id)   # vt 0xd64, Z09 §17.8
&viue <slot>   ac_ViewSlot_UnEquip                                   @ FUN_004198e0
    gm.so_ply_ViewSlot_UnEquip(atoi(args[0]))              # vt 0xd68
ShinePlayer::so_ply_ViewSlot_UnEquip(p, slot)                          @ FUN_0052b3c0
    id = ie_ViewSlot_GetItemID(slot); 0xFFFF or no ItemInfoServer row → nothing
    so_ply_EquipmentChange(0xFFFF, slot, null, 1) (vt 0xd60); ie_ViewSlot_Clear(slot)
    the real items hidden by that preview (eec_ConflictWithNewEquip / eec_ConflictWithOldEquip): for each worn one
        so_ply_EquipmentChange(itemId, its slot, cell, 1); then so_briefequipset (vt 0x5c8)
&viuea   ac_ViewSlot_UnEquipAll                                      @ FUN_00419910
    gm.so_ply_ViewSlot_UnEquipAll(1)                       # vt 0xd6c FUN_0052b510, Z09 §17.8
```

### 3.5 GM chat colour

```pseudo
&gmchat   ac_GMChat                                                  @ FUN_0041b030
    gm.sp_GameData.zone.bIsGM (+0x7fb8) = 1                # read by smo_GMChatColor (vt 0xef4 FUN_0055a500) in so_Chat,
                                                           # so_Shout: flag bit 0 of 0x2002 / 0x201F (Z02 §3.1, §3.2):
                                                           # the client draws the line in the GM colour
    send WM 0x083D NC_MISC_GM_CHAT_COLOR_REQ { u32 nCharNo = gm.so_GetCharRegistNumber() (vt 0x344) }
        # WM FUN_0042b860 (W01 §7.4): if the character's adminlevel ≠ 0, its game block byte = 1, which comes back
        # with 0x1030 NC_CHAR_ZONE_GAME_CMD on every zone change, so the colour stays on for the session
    # there is no command to switch it off
```

### 3.6 Words that do nothing

`&&&` (100), `&disposition` (50) and `&slotmachine` (1) call the empty FUN_00402370; `&gldcollectclear` and
`&gldcollectset` (100) have empty bodies (FUN_0041ae10, FUN_0041ae60: only the profiler entry). Development leftovers
*(inferred)*. The FiestaHeroes list *(fh-doc)* carries them without description.

## Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z11-B1 | `ListIter_AmpCmdArgument` FUN_00427550 | logs a command line only when the level is 1…100 | characters with level 101…255 use every command without an `AmpersandCommandLog` entry | log every GM (or a deliberate exemption) |
| Z11-B2 | `ListIter_AmpCmdArgument` FUN_00427550 | `strncpy(arg, word, 32)` into 33-byte slots; byte 32 never written | a word of 32+ characters has no terminator: handlers read stack garbage and the next argument | copy 32 and terminate |
| Z11-B3 | `&movelayer` FUN_00419930 | checks only `< 2` on signed `atoi` values | negative layer type / number type reach `so_ply_MoveNewLayer` | `0 ≤ v < 2` |
| Z11-B4 | `&z` FUN_0041aeb0 | loops `argnum` times (word included) over `args` | every notice ends with a space; with 12 arguments the 13th read is `liaca_argnum` (one control byte) | loop over `argnum − 1` |

## Not reconstructed / uncertain

- The `tokenize` helper is identified by its argument list only (§1.2); quoting and escaping follow that reading.
- `AmpersandCommandLog` file name: the third `%02d` is assumed to be the hour.
- Who sets `tCharacter.nAdminLevel` in production (operator tool, direct SQL) is outside the binaries.

(Parts 2–6 add their commands as §4–§8; the sweep part adds the coverage boundary.)
