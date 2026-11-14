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
| `ac_TempLinkUsage(p)` FUN_0041a210 | four usage lines of `&templink` (§4.1) |
| `ac_MobBreedUsage(p)` FUN_0041a260 | two usage lines of `&mobbreed` (§4.2) |

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
| 9 | `&kickout` | ac_KickOutPlayer `0041cec0` | 10 | `<charName>` | disconnect a player of this zone (reason 0x68B); other zones: broken, never kicked (B6) | 0x0C1A to WM via so_Disconnect (Z01 §8.3); ring 0x1068; 0x2011 | §4.5 |
| 10 | `&추방` | ac_KickOutPlayer `0041cec0` | 10 | `<charName>` | disconnect a player of this zone (reason 0x68B); other zones: broken, never kicked (B6) | 0x0C1A to WM via so_Disconnect (Z01 §8.3); ring 0x1068; 0x2011 | §4.5 |
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
| 30 | `&makeitem` | ac_MakeItem `0041b8a0` | 100 | `<InxName> [-u<n>] [-s<n>] [-l<n>] [-p<t>/<v>] [-pi] [-e<n>] [-n<n>] …` | create an item (full stack, random options, amulet upgrade steps) in the first free inventory cell; unknown name or full inventory: silent | DB 0x3401 → 0x3402, client cell change (Z05 §9.1) | §4.3 |
| 31 | `&cleariv` | ac_ClearInventory `0041bbd0` | 1 | — | delete every unlocked inventory item | DB 0x3459 → 0x345A, client 0x3001 (Z05 §6.4) | §4.3 |
| 32 | `&dimension` | ac_Dimension `0041a5a0` | 100 | `<n>` | leave sight, layer main number = n | — | §3.1 |
| 33 | `&doorbuild` | ac_DoorBuild `0041aa50` | 100 | `<mobIndex> <x> <y> <dir> <scale>` | spawn a door object (kind 7) on the current map/layer | door appear (Z09 §13.1) | §3.3 |
| 34 | `&mobbreed` | ac_MobBreed `0041b510` | 50 | `<Mob> <num 1–64> <regenSec> <Y/n family> <count ≤250> [<region> [<dropMob> [<level>]]]` | breed num mob breeders at the GM, each respawning count times | mob appear (Z09); 0x2011 "Mob : %d" | §4.2 |
| 35 | `&mb` | ac_MobBreed_simple `0041b790` | 50 | `<Mob>` | spawn one mob at the GM, once | mob appear (Z09); 0x2011 | §4.2 |
| 36 | `&fullpoint` | ac_fullpoint `0041be90` | 50 | — | CurHP/CurSP = max | none | §4.4 |
| 37 | `&summonplayer` | ac_summonplayer `0041bf50` | 100 | `<charName>` | link a player of this zone to the GM's position; refused in a mini-house | 0x1809 or zone change (Z01 §7.1) | §4.5 |
| 38 | `&performance` | ac_performance `0041c8d0` | 10 | `[n]` (unused) | print the main-loop rate | 0x2011 | §4.5 |
| 39 | `&sethp` | ac_Sethp `0041c9d0` | 100 | `<n>` | CurHP = n clamped to 1…MaxHP | none | §4.4 |
| 40 | `&setsp` | ac_Setsp `0041cad0` | 100 | `<n>` | CurSP = n clamped to 1…MaxSP | none | §4.4 |
| 41 | `&dist` | ac_Dist `0041cbc0` | 10 | — | distance to the target in grid units | 0x2011 | §4.5 |
| 42 | `&coord` | ac_CurrentLoc `0041cd60` | 10 | — | handle, map, x, y, direction of the target (or self) | 0x2011 | §4.5 |
| 43 | `&scrint` | ac_ScriptInterrupt `0041abe0` | 10 → **50** | `<block>` | raise an admin interrupt with that call block on the map's cinema script | — | §3.3 |
| 44 | `&timer` | ac_Timer `0041ad10` | 50 | `<sec>` | show a countdown to every player of the map | 0x0810 to the map | §3.3 |
| 45 | `&templink` | ac_TempLink `0041b2f0` | 10 → **50** | `<uses> <mapSrv> <mapCli> <x> <y> [<lvFrom> <lvTo> [<party>]]` | targeted gate NPC links to that point for n uses; −1 closes it | 0x2011 on errors | §4.1 |
| 46 | `&oxblock` | ac_OXBlock `0041b1f0` | 100 → **50** | `O…` / `C…` | open / close the door block "OXBlock" (first door of the map) | 0x6C09 to the map | §4.1 |
| 47 | `&z` | ac_NoticeZone `0041aeb0` | 10 | `<text…>` | notice line to every player of the map | 0x2011 to the map | §3.3 |
| 48 | `&ㅋ` | ac_NoticeZone `0041aeb0` | 10 | `<text…>` | notice line to every player of the map | 0x2011 to the map | §3.3 |
| 49 | `&gmchat` | ac_GMChat `0041b030` | 1 | — | GM chat colour on; WM keeps it | WM 0x083D | §3.5 |
| 50 | `&gldcollectclear` | ac_GuildCollectClear `0041ae10` | 100 | — | nothing (empty body) | — | §3.6 |
| 51 | `&gldcollectset` | ac_GuildCollectSet `0041ae60` | 100 | — | nothing (empty body) | — | §3.6 |
| 52 | `&questgiveup` | ac_questgiveup `0041c190` | 100 | — | nothing (empty body) | — | §4.6 |
| 53 | `&questrecieve` | ac_questrecieve `0041c140` | 100 | — | nothing (empty body) | — | §4.6 |
| 54 | `&questcomplete` | ac_questcomplete `0041c1e0` | 100 | `<n>` (ignored) | nothing | — | §4.6 |
| 55 | `&learnskill` | ac_learnskill `0041c290` | 100 | `<skillId>` | learn an active skill, no checks | DB 0x4801 → 0x4802 → client 0x4804 (Z03 §9.3) | §4.4 |
| 56 | `&skillcooltime` | ac_skillcooltime `0041c3c0` | 100 | — | nothing (empty body) | — | §4.6 |
| 57 | `&setabstate` | ac_Setabstate `0041c410` | 100 | `<AbState> [<keepMs>] [<strength 1–39>]` | set an abnormal state on self | 0x2429, 0x2427, 0x1C18 (Z03 §6.3) | §4.4 |
| 58 | `&resetabstate` | ac_resetabstate `0041c620` | 100 | — | clear every abnormal state of self | 0x2428 per state (Z03 §6.4) | §4.4 |
| 59 | `&setabstatetarget` | ac_SetAbstateTarget `0041c6e0` | 100 | `<AbState> [<keepMs>] [<strength 1–39>]` | set an abnormal state on the target | as &setabstate, keep time of the row (B5) | §4.4 |
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
| 71 | `&block` | ac_BlockMatrix `0041ccb0` | 100 | — | nothing (calls an empty body) | — | §4.5 |
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

## 4. Commands, part 2 (handlers FUN_0041b1f0 … FUN_0041cec0)

### 4.1 Gates and doors: `&oxblock`, `&templink`

```pseudo
&oxblock O… | C…   ac_OXBlock                                       @ FUN_0041b1f0
    action = args[0][0] == 'O' ? 1 (open) : args[0][0] == 'C' ? 0 (close) : else wall "&oxblock Open or &oxblock Close"; return
        # only the first letter counts, upper case only ("open" is refused)
    so_AllInMap(gm, AxialListDoorAction{ alda_BlockIndex = "OXBlock", alda_DoorAction = action }, includeSelf 0)
AxialListDoorAction::ali_Work(it, gm, o) → continue                  @ FUN_0041b130
    return o.vt[0x318](blockIndex, action) == 0
        # doors: ShineDoor::so_door_DoorAction FUN_00550770 (Z09 §13.1) switches the map's .shbd block "OXBlock",
        #   stores the name in the door's brief info and sends 0x6C09 NC_SCENARIO_DOORSTATE_CMD to the map; returns 1
        # every other object: folded "return 0" (FUN_004021b0) → keep walking
    # the walk stops at the first door of the map, whatever block it was built for: on a map with several doors only
    # that one gets the state broadcast and the block name "OXBlock" *(inferred: the OX-quiz map has one door)*;
    # no door on the map: nothing, no message
```

`&templink` turns the targeted gate NPC (role `Gate`, `NPCRole_Portal`, Z02 §6.5) into a temporary link to any point.

```pseudo
&templink <LinkNumber> <MapNameServer> <MapNameClient> <X> <Y> [<LevelFrom> <LevelTo> [<PartyLinkable>]]
    ac_TempLink                                                      @ FUN_0041b2f0
    t = gm.so_CurrentTargetObject() (vt 0x75c); none: wall "Target needed"; return
    argnum < 6 (fewer than 5 arguments): the four lines of ac_TempLinkUsage (§1.6); return
        # the example line reads "ex    : &mobbreed  10 Rou Rou 7828 4325 1 150 0": copy-paste text (original bug) Z11-B10
    n = ac_Scanf(args[0])
    tmpl = LinkInformTemplete (0x61 bytes) {                         # NPCManager::LinkInformTemplete (pdb2016)
        index[20]      = never written: stack bytes                  # (original bug) Z11-B9
        linktoserver[33] = args[1] (strncpy 33), linktoclient[33] = args[2],
        coordx = ac_Scanf(args[3]), coordy = ac_Scanf(args[4]), direct = 0,
        Party = argnum > 8 ? (u8) ac_Scanf(args[7]) : 0 }
    (from, to) = argnum > 7 ? ((u16) ac_Scanf(args[5]), (u16) ac_Scanf(args[6])) : (1, shineparam.levellimit)
        # with exactly 6 arguments LevelFrom alone is ignored
    if to < from: ac_TempLinkUsage; return
    npc = NPCManager::nm_FindNPCFunc(npcmanager, t.handle)          # FUN_00418f10; also matches only NPC handles
    npc missing or npc.func (role) missing: wall "Target is not NPC"; return
    npc.func.vt[0x30](gm, n, &tmpl, from, to)
        # NPCRole_Portal::nrb_LinkBrench FUN_004c7ab0 (all four portal roles):
        #     nrb_BrenchNumber = n; nrb_BrenchSpot = tmpl; nrb_levelFrom = from; nrb_levelTo = to
        # every other role: NPCRoleBase::nrb_LinkBrench FUN_004c7a00 → gm notice "Not gate"
```

Effect on the gate (`NPCRole_Portal::nrb_Role` FUN_004c2ef0, the branch Z02 §6.5 does not show), state in the role
object (`+0x18 nrb_BrenchNumber`, `+0x1c nrb_BrenchSpot`, `+0x7e/+0x80 levels`), not saved, lost at restart:

```pseudo
NPCRole_Portal.nrb_Role(p, …):                                      @ FUN_004c2ef0
    nrb_BrenchNumber < 0: the gate does nothing at all (closed)           # "&templink -1 …"
    nrb_BrenchNumber == 0: normal LinkTable behaviour (Z02 §6.5)          # initial state *(inferred)*
    nrb_BrenchNumber > 0: destination = nrb_BrenchSpot, no field-entry check (ENTER_MAP_ERR_NONE);
        yes/no server menu as for one destination; the menu argument has sml_isTemplink = 1 and the temp levels,
        so smfm_Link checks the player's level against [from, to] instead of the field's condition
ServerMenuFuncter.smfm_Link → role.vt[0x34](row) = NPCRole_Portal::nrb_LinkBrenchCheck(row) → allowed  @ FUN_004c7b90
    nrb_BrenchNumber < 0: false (no link)
    row == nrb_BrenchSpot (all 0x61 bytes): nrb_BrenchNumber < 1 → false; else nrb_BrenchNumber −= 1, true
    other rows: true
    (other roles: NPCRoleBase::nrb_LinkBrenchCheck FUN_004c7b40 → false)
```

So `LinkNumber` is the number of uses; when it reaches 0 the gate is back to its LinkTable. The usage note "Permanantly
change if linknumber is large then 10000" has no code behind it: a large number is just many uses. `-1` closes the gate
until the next `&templink`. *(fh-doc)* agrees ("for amount teleports or until &templink is called again with amount -1").

### 4.2 Mobs: `&mobbreed`, `&mb`

```pseudo
&mobbreed <MobIndex> <MobNumber> <RegenSec> <Family Y|n> <RegenNumber> [<RegenRegionIndex> [<ItemDropMobIndex> [<MobLevel>]]]
    ac_MobBreed                                                       @ FUN_0041b510
    argnum < 6: usage lines (as ac_MobBreedUsage); return
    mobId = mobdatabox.mdb_btree[args[0]] (MobInfo InxName); missing: wall "Invalid mob index" + usage; return
    num = ac_Scanf(args[1]); not 1…64: wall "MobNumber wrong" + usage; return
    regenSec = ac_Scanf(args[2]); family = args[3][0] ∈ {'Y','y'}
    count = min(ac_Scanf(args[4]), 250)             # unsigned compare: a negative number also becomes 250
    region = argnum > 6 ? args[5] : "-"
    dropMob = argnum < 8 or args[6][0] == '-' ? 0xFFFF : mdb_2MobID(args[6]); 0xFFFF there: wall "DropMobIndex wrong" + usage; return
    level = argnum > 8 ? ac_Scanf(args[7]) : −1
    MobHatchery::mh_MobBreed(mobhatchery, gm.so_Field map, gm position, 0, mobId, null, num, regenSec, family, count,
                             key "Def", bandit null, region, dropMob, level, gm.so_GetLayerRegNum())    @ FUN_004b6960
        # Z09 §10.6: num breeders around a radius-50 circle at the GM's position, each regenerates its mob `count`
        # times every regenSec s; family → mobs die together; region and dropMob are passed but unused (Z09 §10.6)
    wall "Mob : %d" (mobId)

&mb <MobIndex>   ac_MobBreed_simple                                   @ FUN_0041b790
    mobId as above (missing: "Invalid mob index" + usage)
    mh_MobBreed(…, mobId, num 1, regen 0, family 0, count 1, key "Def", null, "-", 0xFFFF, −1, layer)  # one mob, once
    wall "Mob : %d"
```

The mobs are normal world mobs (sight, AI, drops, Z09); the group is freed when its breeders are spent.

### 4.3 Items: `&makeitem`, `&cleariv`

```pseudo
&makeitem <ItemInxName> [-<opt> …]   ac_MakeItem                        @ FUN_0041b8a0
    id = itemdatabox.idb_btree[args[0]] (0xFFFF when missing)
    info.key = ItemTotalInformation::iti_mkregnum(id, 0, zoneNo, worldNo)  # FUN_00640710; key kind 0 = GM make *(inferred)*
    info.itemid = id
    id ≥ idb_maxItemhandle or no ItemInfo row: return, no message       # unknown names fail silently
    row.ID ≠ id: assert "ItemDataBox::operator [] :Invalid Item index"; return
    (ItemInfo null → wall "Invalid item": dead, already excluded)       # (original bug) Z11-B12
    cls = itmattcontainer[id]                                           # ItemAttributeClass per item class (Z04)
    cls.iac_itemcreate(id, &info, "-o")                                 # vt 0x14: class defaults
    cls.iac_itemcreate(id, &info, "-l<ItemInfo.MaxLot>")                # a full stack by default
    for a in args[1] … args[11] while a[0] == '-': cls.iac_itemcreate(id, &info, a)      # GM options, in order
    if ItemInfoServer.RandomOptionDropGroup names a RandomOption table and cls.vt[0x70](&item) (option storage) ≠ null:
        ItemRandomOption::RandomOptionTable::rot_FillOption(storage, table)   # FUN_00493590: random options as for a drop
        # rot_FillOption starts with optionnumber = 1 (identified, no options): "-p" options of the GM are discarded
        # for every item with a RandomOptionDropGroup (original bug) Z11-B13
    if ItemInfo.Class == ITEMCLASS_AMULET and (u = cls.vt[0x30] iac_Getupgrade(&info)) > 0:
        for i in 1 … u: stop when not AccUpGradeDataBox::augdb_RandomOptionUpgrade(&gAccUpGradeDataBox, &item, &e, 1, i)
            # one accessory-upgrade option step per upgrade level (below)
    ShinePlayer::sp_MakeItem(gm, handle, &info)                         # FUN_00528690 (Z09 §24.2): first free unlocked
        # inventory cell → sp_CreateItemByAdmin → Character DB 0x3401 NC_ITEMDB_ADMINCREATE_REQ (Z05 §9.1); the ACK puts the
        # item in the cell and the client gets the cell change. Inventory full: nothing, no message.
```

Options (`ItemAttributeClass::iac_itemcreate`, vt 0x14 of the item's attribute class; the letter is `opt[1]`, either
case, the number is `sscanf(opt + 2, "%d")`). The same parser serves the scene `itemcreate` / `costumecreate` nodes
(Z09 §24.2):

| Attribute class (FUN_) | `-o` (defaults) | Other options |
|---|---|---|
| base `ItemAttributeClass` 00640690 | key −1, item struct zeroed, itemid 0xFFFF | — (no 2016 class uses the base body) |
| Weapon 0063ee40 | no upgrade/strengthen, 3 mob-kill counters 0xFFFF, no title (`CharacterTitleMobID` 0xFFFF), option count 0 + identified, gem sockets empty, `maxSocketCount` 0 | `-u<n>` upgrade, `-s<n>` strengthen, `-e<n>` maxSocketCount (n > 1 → 2), `-p…` option |
| Armor, Boot 0063f010; Shield 0063ef70 | no upgrade, identified, no delete time | `-u<n>`, `-s<n>`, `-p…` |
| Amulet 0063eda0; Bracelet 0063f4a0 | upgrade 0, options cleared (vt 0x84 iac_ClearItemOptionUpgrade), identified | `-u<n>` upgrade, `-p…`; every call also sets "not bound" |
| ByteLot (9 classes) 0063f330, WordLot / ActiveSkill / QuestLot 0063f430, DwrdLot 0063ed60 | — | `-l<n>` lot (byte / word / dword) |
| BindItem 0063f120 | = `-n1` | `-n<n>` n portal slots `{ map 0xFFFF, x 10000, y 10000 }` *(inferred from the constants)* |
| KQStep 0063f1e0 | step 0 | `-s<n>` step |
| ItemChest 0063f1a0 | low 4 bits of the first attribute byte cleared (content count *(inferred)*) | — |
| Riding 0063f230, CostumWeapon/CostumShield 0063f300, Amount 0063f280, Furniture 0063f0b0, Pet 0063f470, Capsule 0063f370, Decoration 0063f100, MiniHouseSkin/ActionItem 0063f1c0, CardCollect 0063f3b0, CardCollect_Close 0063f390 | every call (whatever the option) re-applies the defaults: riding hunger/HP from the riding table, costume charge, Amount = MaxLot, furniture position (276, 389, 6) and no end time, pet not summoned, card serial (CardCollect: random `(a·100 + 101 + b)·10000 + rand 1000`), … | — |
| GBCoin, KingdomQuestItem, SkillScroll, WeaponTitlaLicence | no-op FUN_004c2450 | — |

```pseudo
ItemAttributeClass::iac_Setoption(storage, opt)                         @ FUN_0063ece0   ("-p…")
    opt[2] ∈ {'I','i'}: optionnumber bit 0 = 1 (identified); return
    n = optionnumber >> 1; if n < 8 and sscanf(opt + 2, "%d/%d") == 2:
        optionlist[n] = { itemoption_type = first, itemoption_value = second }; optionnumber += 2   # up to 8 options
AccUpGradeDataBox::augdb_RandomOptionUpgrade(box, item, &e, step, level) → bool    @ FUN_005c5c60
    item must be an amulet with an ItemInfoServer row; level 0: cls.vt[0x84] clear the upgrade options, true
    table = RandomOption[RandomOptionDropGroup]; factors = AccUpGradeInfo map for ItemInfo.BasicUpInx (missing: false)
    step ≥ 0: candidates = upgrade options already present that have a factor; then the random options
        (value ≠ 0) not yet in the list; if fewer than table.MaxOpCount: candidates = every option type of the factor map
    step < 0: candidates = the random options present (value ≠ 0)
    none: false; shuffle (10 passes), take one type t (t < 15 else false)
    value = cls.vt[0x7c](item, t) + augdb_GetOptionUpGradeValue(BasicUpInx, t, step > 0, level) · step
    clamp to [0, augdb_GetOptionUpGradeLimit(BasicUpInx, t, step > 0, level)]; cls.vt[0x80](item, t, value) (store); true
```

Other callers (one step at a time; Z04 owns them): `sp_NC_ITEM_UPGRADE_REQ` FUN_0053d220 (Z04 §9.1, "stat info =
FUN_005c5c60(…, +1, lv)"), `sp_NC_ITEM_NEW_UPGRADE_REQ` FUN_0053e360, `sp_NC_ITEM_BRACELET_UPGRADE_REQ` FUN_0053ec40,
`Item_ForcedUpgrade` FUN_0053c510, `sp_NC_ITEM_MIX_ITEM_REQ` FUN_00521540. `&makeitem` replays one step per level 1…u, so
a GM-made `+u` amulet carries the same kind of option growth as an upgraded one *(inferred)*.

```pseudo
&cleariv   ac_ClearInventory   (level 1: any admin)                    @ FUN_0041bbd0
    it = UnlockedInventoryIterator(inventory type 9, gm.sp_Item.itembag.ci_Inventory, lock list vt 0x7d4)
        # only cells not reserved by another request (trade, pending DB answer …)
    no such item: return
    gpp = 0x3459 NC_ITEMDB_DESTROY_REQ {                                # to the Character DB (sock2gameDB)
        u16 handle = gm.handle, u32 charNo (vt 0x344), u16 lockindex = current lock index of the lock list,
        u8 flags = number of keys (bits 0–6), bit 7 = 0 (no item rewrite; itemId/key/attrOffset bytes stale, unread)
        u64 keys[] at payload 0x17 }
    for every unlocked cell c with an item whose ItemInfo row exists (else assert, skipped):
        keys[count & 0x7F] = c.key; count = (count & 0x80) | ((count + 1) & 0x7F)
        lock list vt 0x30 icl_ClearItem(c, 0x2400 | slot)                # reserve "clear this cell" under the lock index
    if count & 0x7F: send (0x19 + 8·count bytes), icl_IncIndex
        # Character DB deletes the keys and answers 0x345A (D03 §7.5); the zone applies the reservations (Z05 §6.4):
        # cells emptied, client gets the 0x3001 cell changes, quest item-count hooks run
    # more than 127 items (the inventory has 192 cells): the 7-bit count wraps (original bug) Z11-B8
```

### 4.4 Character state: `&fullpoint`, `&sethp`, `&setsp`, `&learnskill`, abstates

```pseudo
&fullpoint   ac_fullpoint                                             @ FUN_0041be90
    CurHP = gm.so_MaxHP() (vt 0x4f0); CurSP = gm.so_MaxSP() (vt 0x4f4)
&sethp <n>   ac_Sethp                                                 @ FUN_0041c9d0
    ShinePlayer::sp_HPChangeCheck(gm, n, 0, "AmpersandCommand::ac_Sethp")   # FUN_0055e130: calls vt 0x4e8 and 0x484,
                                                                            # discards both: no effect
    CurHP = clamp(ac_Scanf(args[0]), 1, so_MaxHP())        # 0 / missing / non-numeric → 1
&setsp <n>   ac_Setsp                                                 @ FUN_0041cad0
    CurSP = clamp(ac_Scanf(args[0]), 1, so_MaxSP())
# none of the three sends a packet: the GM's client keeps the old bars until the next HP/SP update (regeneration,
# damage, a stat packet) *(inferred)*; the values are saved with the character (Z07 CurHP +0x7f67)
```

```pseudo
&learnskill <skillId>   ac_learnskill                                @ FUN_0041c290
    send Character DB 0x4801 NC_SKILL_SKILLTEACH_REQ (0x11 bytes) {
        u16 handle, u32 charNo, u32 chrregnum = charNo, u16 skillid = (u16) ac_Scanf(args[0]), u8 ispassive = 0, u16 removeid = 0xFFFF }
    (too long: assert "AmpersandCommand::ac_learnskill : Packet Too Long", never)
    # no check here: not the skill table, class, level, or whether it is known. The DB (D04 §2, 0x4801) refuses a known
    # skill (0x4803 → client 0x4805 "Failed to learn the skill."); success 0x4802 → the zone adds the skill and sends
    # 0x4804 NC_SKILL_SKILL_LEARNSUC_CMD (Z03 §9.3). Any number is stored, also ids without an ActiveSkill row *(inferred)*
```

```pseudo
&setabstate <AbStateInxName> [<keepMs>] [<strength>]   ac_Setabstate   @ FUN_0041c410
    idx = dic_abstate.as_BTreeID[args[0]]; > as_maxhandle: assert "…as_FromID : Invalid skill id"; no row: nothing
    keep = args[1] non-empty ? ac_Scanf(args[1]) : 0;  strength = args[2] non-empty ? ac_Scanf(args[2]) : 1, outside 1…39 → 1
    sub = entry.subabstate[strength] (missing: nothing); keep == 0 → keep = sub.KeepTime
    if gm.so_AbnormalState_Set(setter gm, entry.AbStataIndex, strength, entry, now, 0, 0xFFFFFFFF, keep, 0, 0) (vt 0x638, Z03 §6.2):
        so_AbnormalState_BitSet(gm, idx); s = g_NewAbstateStrength (outside 1…39 → 1)
        if entry.subabstate[s]: gm.so_AbnormalState_Inform(idx, keep, 1) (vt 0x3f0 → 0x2429);
                                so_AbnormalState_BroadcastSet(gm, idx, keep, s) (0x2427 / 0x1C18, Z03 §6.3)
&setabstatetarget <AbStateInxName> [<keepMs>] [<strength>]   ac_SetAbstateTarget   @ FUN_0041c6e0
    t = gm.so_CurrentTargetObject(); none: nothing; entry = AbState::as_FromName(args[0]); none: nothing
    same parsing; t.so_AbnormalState_Set(setter gm, …, keep, …)           # player or mob
    on success: bit set; t.Inform(idx, sub'.KeepTime, 1) (players only send); BroadcastSet(t, idx, sub'.KeepTime, s)
        # sub' = row of the resulting strength: a given keepMs is used for the state but not for the packets
        # (original bug) Z11-B5
&resetabstate   ac_resetabstate                                       @ FUN_0041c620
    for idx in 0 … 0x317: gm.so_AbnormalState_Reset(idx) (vt 0x650, Z03 §6.4)   # every state of the GM (and its mover)
```

### 4.5 Players and information

```pseudo
&summonplayer <charName>   ac_summonplayer                             @ FUN_0041bf50
    in a mini-house (vt 0x130): wall "fail to 'summonplayer' : not allowed to do 'summonplayer' in the MH"; return
    t = som_FindPlayer(Name5 = args[0] (20)); this zone only; not found: nothing, no message
    t in a mini-house: the same "fail to 'summonplayer' …" line
    t.so_LinkTo({ server map = client map = gm's map name (12), x, y = gm position }, 6, 9, 10)   (vt 0x600, Z01 §7.1)
    # the zone-wide version through the zone ring is &psummon (part 3)

&kickout, &추방 <charName>   ac_KickOutPlayer                          @ FUN_0041cec0
    gpp payload = PROTO_NC_CHAR_KICKPLAYEROUT_RNG { ZONERINGLINKAGESTART start (7), u8 tmp (not written), Name5 charid (20) }
    ZoneRingPacketKickPlayerOut::zrpb_Request(gm, gpp)                 @ FUN_005a76f0
        t = som_FindPlayer(charid)
        t present and on a map:
            t.so_Disconnect(0x68B, 0, 0) (vt 0x5f8)                    # Z01 §8.3: "kicked by a GM"
            vt 1 zrpb_Success(gm, …) @ FUN_005a7e10: gm notice "%s is banned"
        else → zone ring (zcs_Send, 0x1E bytes): opcode 0x1068 NC_CHAR_PLAYERSEARCH_RNG with
            start = { machine = own zone no, handle = gm handle, regnum = gm charNo }
            # (original bug) Z11-B6: 0x1068 is the player *search*; with the kick layout the other zones read the name
            # one byte early ([tmp, charid[0…18]]), find nobody, and the packet returns to this zone, where
            # ZoneRingPacketFindPlayer::zrpb_Failure prints "%s is not in game" for that shifted name.
            # A player in another zone is never kicked.
```

The intended path is still in the ring handlers (Z01 §10): `zls_NC_CHAR_KICKPLAYEROUT_RNG` FUN_0045bc30 (0x106B: found
here → `so_Disconnect(0x68B)`, answer 0x106C `PROTO_NC_CHAR_PLAYERBANNED_RNG { start, Name5 charid }` (0x1D bytes); not
found → forward; back at the origin → `zrpb_Failure` FUN_005a8290 "%s is not in game") and `zls_NC_CHAR_PLAYERBANNED_RNG`
FUN_0045bdf0 (forward; at the origin → `zrpb_Failure` too, reading the name at the 0x106B offset: the GM would see the
kicked player's name minus its first letter "… is not in game" (original bug) Z11-B7). Nothing in 2016 sends 0x106B, so
both are dead.

```pseudo
&dist   ac_Dist                                                       @ FUN_0041cbc0
    t = current target; none: nothing; wall "Distance : %d Grid" (isqrt of so_DistanceSquar(gm, t))
&coord   ac_CurrentLoc                                                @ FUN_0041cd60
    o = current target, else gm; gm without a map: nothing
    wall "Location[%d] : %s/%d/%d/%d"  (o.handle, gm's map name, o.x, o.y, o direction byte)
        # the map is always the GM's (the target is in sight, so the same map)
&performance [n]   ac_performance                                     @ FUN_0041c8d0
    wall "Main performance : %g loop/sec"  (PerformanceChecker::pc_loopPERsecond(&performancechech): main-loop rate)
    n = args[0] ? ac_Scanf(args[0]) : 10; never used (original bug) Z11-B11
&block   ac_BlockMatrix                                               @ FUN_0041ccb0
    calls FUN_00549070 (a bare `ret 4`, the folded empty body) with the map's block info (+0x14) and args: nothing
    # the block-matrix dump of the development build is compiled out *(inferred)*
```

### 4.6 Empty quest and cool-time words

`&questrecieve` FUN_0041c140, `&questgiveup` FUN_0041c190 and `&skillcooltime` FUN_0041c3c0 are empty (profiler only).
`&questcomplete` FUN_0041c1e0 parses `ac_Scanf(args[0])` and drops it. The working quest debug words are `&queststart` /
`&questread` (§3.4).

## Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z11-B1 | `ListIter_AmpCmdArgument` FUN_00427550 | logs a command line only when the level is 1…100 | characters with level 101…255 use every command without an `AmpersandCommandLog` entry | log every GM (or a deliberate exemption) |
| Z11-B2 | `ListIter_AmpCmdArgument` FUN_00427550 | `strncpy(arg, word, 32)` into 33-byte slots; byte 32 never written | a word of 32+ characters has no terminator: handlers read stack garbage and the next argument | copy 32 and terminate |
| Z11-B3 | `&movelayer` FUN_00419930 | checks only `< 2` on signed `atoi` values | negative layer type / number type reach `so_ply_MoveNewLayer` | `0 ≤ v < 2` |
| Z11-B4 | `&z` FUN_0041aeb0 | loops `argnum` times (word included) over `args` | every notice ends with a space; with 12 arguments the 13th read is `liaca_argnum` (one control byte) | loop over `argnum − 1` |
| Z11-B5 | `&setabstatetarget` FUN_0041c6e0 | sets the state with the GM's keep time but sends 0x2429 / 0x1C18 with the strength row's `KeepTime` | with a keepMs argument the target's and the viewers' timers show the wrong duration (`&setabstate` sends the given time) | send `keep` as `ac_Setabstate` does |
| Z11-B6 | `&kickout` `ZoneRingPacketKickPlayerOut::zrpb_Request` FUN_005a76f0 | a player not in this zone is looked for with opcode 0x1068 NC_CHAR_PLAYERSEARCH_RNG in the 0x106B kick layout | other zones read the name one byte early, nobody is found, the GM gets "<garbled name> is not in game"; GMs can only kick players of their own zone | write 0x106B NC_CHAR_KICKPLAYEROUT_RNG |
| Z11-B7 | 0x106C `zls_NC_CHAR_PLAYERBANNED_RNG` FUN_0045bdf0 | at the origin calls `zrpb_Failure`, which reads the name at the 0x106B offset (+8) | a successful remote kick would be reported as "<name without first letter> is not in game" (dead in 2016: 0x106B is never sent, B6) | call `zrpb_Success` ("%s is banned") |
| Z11-B8 | `&cleariv` FUN_0041bbd0 | key count kept in 7 bits while the loop reserves every unlocked cell (inventory: 192 cells) | 128 items: no packet, all cells stay reserved; more: the DB deletes only the last n−128 keys, the ACK still empties all n cells in memory; the rest returns at the next login | split into several 0x3459 of ≤ 127 keys |
| Z11-B9 | `&templink` FUN_0041b2f0 | `LinkInformTemplete.index[20]` of the temp link is never written | 20 stack bytes in the gate's `nrb_BrenchSpot` (compared byte-wise by `nrb_LinkBrenchCheck`, so still consistent) | zero the template |
| Z11-B10 | `ac_TempLinkUsage` FUN_0041a210 / `&templink` | the example line starts with "&mobbreed" | misleading help text | "&templink" |
| Z11-B11 | `&performance` FUN_0041c8d0 | parses an optional number (default 10) and never uses it | none (dead code) | a sample period that was removed *(inferred)* |
| Z11-B12 | `&makeitem` FUN_0041b8a0 | "Invalid item" only after the row was already found; an unknown name or a full inventory returns without a message | the GM gets no feedback for a typo or a full bag | notice for every failure |
| Z11-B13 | `&makeitem` FUN_0041b8a0 | rolls random options (`rot_FillOption` FUN_00493590 resets the option count) after the GM's `-p` options | `-p<type>/<value>` works only on items without a RandomOptionDropGroup | skip the roll when the GM gave options |

## Not reconstructed / uncertain

- The `tokenize` helper is identified by its argument list only (§1.2); quoting and escaping follow that reading.
- `AmpersandCommandLog` file name: the third `%02d` is assumed to be the hour.
- Who sets `tCharacter.nAdminLevel` in production (operator tool, direct SQL) is outside the binaries.
- §4.1 `&oxblock`: which door of the OX-quiz map is first in the `so_AllInMap` walk was not checked against the map
  scripts; with one door per map the result is the same.
- §4.3: the attribute fields hit by the `-o` defaults are read through unions in the decompilation; the BindItem portal
  layout `{u16 map, u32 x, u32 y}` and the ItemChest count bits are *(inferred)* from the constants. The meaning of key
  kind 0 in `iti_mkregnum` (GM make) is inferred from the other callers (2 scene, 3 mob drop, 6 chest, 7 costume).
- §4.4: how the GM's client learns the HP/SP set by `&fullpoint` / `&sethp` / `&setsp` (no packet is sent) was not traced.

(Parts 2–6 add their commands as §4–§8; the sweep part adds the coverage boundary.)
