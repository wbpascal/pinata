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
| 5 | `&pfind` | ac_FindPlayer `0041d050` | 10 | `<charName>` | show where a player is (any zone) and move the GM there (so_ply_BriefLink); a house player is shown at the house entrance (this zone only, B14) | ring 0x1068 / 0x1069; 0x2011; GM's map link | §5.1 |
| 6 | `&캐추적` | ac_FindPlayer `0041d050` | 10 | `<charName>` | show where a player is (any zone) and move the GM there (so_ply_BriefLink); a house player is shown at the house entrance (this zone only, B14) | ring 0x1068 / 0x1069; 0x2011; GM's map link | §5.1 |
| 7 | `&mfind` | ac_FindMob `0041cf90` | 10 | `<mobIndex>` | move the GM to the first mob of that MobInfo index on the GM's map | 0x2011 on failure; GM's map link | §5.1 |
| 8 | `&몹추적` | ac_FindMob `0041cf90` | 10 | `<mobIndex>` | move the GM to the first mob of that MobInfo index on the GM's map | 0x2011 on failure; GM's map link | §5.1 |
| 9 | `&kickout` | ac_KickOutPlayer `0041cec0` | 10 | `<charName>` | disconnect a player of this zone (reason 0x68B); other zones: broken, never kicked (B6) | 0x0C1A to WM via so_Disconnect (Z01 §8.3); ring 0x1068; 0x2011 | §4.5 |
| 10 | `&추방` | ac_KickOutPlayer `0041cec0` | 10 | `<charName>` | disconnect a player of this zone (reason 0x68B); other zones: broken, never kicked (B6) | 0x0C1A to WM via so_Disconnect (Z01 §8.3); ring 0x1068; 0x2011 | §4.5 |
| 11 | `&linkto` | ac_LinkTo `0041a7e0` | 10 | `[<map> [<x> <y>]]` / `-` | teleport to a map (default regen point) or, without argument, to a free spot of the current map; `-` = back to the normal location | 0x1809 (same zone) or zone change (Z01 §6) | §3.1 |
| 12 | `&이동` | ac_LinkTo `0041a7e0` | 10 | `[<map> [<x> <y>]]` / `-` | teleport to a map (default regen point) or, without argument, to a free spot of the current map; `-` = back to the normal location | 0x1809 (same zone) or zone change (Z01 §6) | §3.1 |
| 13 | `&psummon` | ac_SummonPlayer `0041d140` | 10 | `<charName>` | move a player of any zone to the GM's position (no house check, no answer) | ring 0x106A; 0x2011 on failure | §5.1 |
| 14 | `&캐소환` | ac_SummonPlayer `0041d140` | 10 | `<charName>` | move a player of any zone to the GM's position (no house check, no answer) | ring 0x106A; 0x2011 on failure | §5.1 |
| 15 | `&expbonus` | ac_BonusExp `0041e190` | 50 | `<A\|x> <rate‰>` | set fm_FieldBonus.fb_Experience of the GM's map (A: every map of every zone); nothing reads it (B15, B16) | ring 0x1810; 0x2011 usage | §5.4 |
| 16 | `&경험치보너스` | ac_BonusExp `0041e190` | 50 | `<A\|x> <rate‰>` | set fm_FieldBonus.fb_Experience of the GM's map (A: every map of every zone); nothing reads it (B15, B16) | ring 0x1810; 0x2011 usage | §5.4 |
| 17 | `&itembonus` | ac_BonusItem `0041e2d0` | 50 | `<A\|x> <rate‰>` | set fm_FieldBonus.fb_DropRate (drop roll factor) of the GM's map (A: every map of every zone) (B16) | ring 0x1811; 0x2011 usage | §5.4 |
| 18 | `&아이템보너스` | ac_BonusItem `0041e2d0` | 50 | `<A\|x> <rate‰>` | set fm_FieldBonus.fb_DropRate (drop roll factor) of the GM's map (A: every map of every zone) (B16) | ring 0x1811; 0x2011 usage | §5.4 |
| 19 | `&fieldbonus` | ac_FieldBonus `0041e410` | 50 | — | show the GM's map EXP / drop bonus in percent | 0x2011 | §5.4 |
| 20 | `&필드보너스` | ac_FieldBonus `0041e410` | 50 | — | show the GM's map EXP / drop bonus in percent | 0x2011 | §5.4 |
| 21 | `&silence` | ac_KeepFromChat `0041e090` | 100 | `<charName>` | only answers "Success to silence"; no chat ban (B17) | 0x2011 | §5.6 |
| 22 | `&조용히` | ac_KeepFromChat `0041e090` | 100 | `<charName>` | only answers "Success to silence"; no chat ban (B17) | 0x2011 | §5.6 |
| 23 | `&distribute` | ac_PlayerDistribute `00422f90` | 10 | (part 6) | | | |
| 24 | `&isblock` | ac_IsBlock `0041e880` | 10 | — | block test around the GM for radius 0…3 | 0x2011 | §5.7 |
| 25 | `&mobdist` | ac_MobDistribute `0041d250` | 10 | — | list every object of the map with position | 0x2011 per object | §5.2 |
| 26 | `&chargeditem` | ac_ChargedItem `0041d2f0` | 100 | `<effectHandle>` | turn the GM's first charged buff into buff n ending in 5 min (memory only, B18) | — | §5.6 |
| 27 | `&parameterview` | ac_ParameterView `0041e7d0` | 100 | `<0…11>` | show one stat across nine smo_Param layers | 0x2011 | §5.7 |
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
| 62 | `&killallmob` | ac_killallmob `0041d3c0` | 50 | — | kill every attackable live mob of the map, GM as killer | kill packets (Z03 §7) | §5.2 |
| 63 | `&mobdamage` | ac_mobdamage `0041d460` | 100 | `<Y\|N> <Y\|N> [factor]` | set the Lua-certification combat factor flags (freeze, recover) and value | 0x2011 | §5.3 |
| 64 | `&suicideallmob` | ac_SuicideAllMob `0041d540` | 50 | — | every mob of the map kills itself (no EXP) | 0x243C per mob; kill packets | §5.2 |
| 65 | `&suicidemob` | ac_SuicideMob `0041d620` | 100 | `<mobIndex>` | every mob of that index on the map kills itself | 0x2011; 0x243C per mob | §5.2 |
| 66 | `&kingdomquest` | ac_KingdomQuest `00423dd0` | 100 | (part 6) | | | |
| 67 | `&Reroadkingdomquest` | ac_ReroadKingdomQuest `0041dc80` | 100 | `<script>` | stop the films of that script and reload the scenario book | — | §5.5 |
| 68 | `&endofkq` | ac_EndOfKingdomQuest `0041dbd0` | 100 | `<kqHandle>` | end a kingdom quest at the WM and drop its contribution list (map not cleared) | WM 0x5810 | §5.5 |
| 69 | `&guildtournament` | ac_GuildTournament `0041da30` | 100 | — (arguments ignored) | start guild tournament map 0 on GuildT01 locally with fixed times | GT start (Z16) | §5.5 |
| 70 | `&zonelink` | ac_ZoneLinkTest `0041d950` | 100 | — | send a probe round the zone ring and list every zone's next address | ring 0x0811; 0x2011 | §5.5 |
| 71 | `&block` | ac_BlockMatrix `0041ccb0` | 100 | — | nothing (calls an empty body) | — | §4.5 |
| 72 | `&emptymap` | ac_EmptyMap `0041d850` | 100 | `<map>` | name a free instance map of that cluster (moves the cluster's cursor) | 0x2011 | §5.5 |
| 73 | `&serversocketcut` | ac_ServerSocketCut `0041d760` | 100 | `<0…3>` | close slot n of the WM, GameDB and GameLog connections (they reconnect) | — | §5.5 |
| 74 | `&staticdamage` | ac_staticdamage `0041dfd0` | 50 | `[n]` | fixed damage n for every GM hit (0/none = off); also the death-aura radius | — | §5.3 |
| 75 | `&deathaura` | ac_deathaura `0041dd70` | 100 | — | toggle: every tick kill all mobs within smo_admindamage of the GM | kill packets | §5.3 |
| 76 | `&immortal` | ac_immortal `0041ddf0` | 10 | — | toggle: refill HP/SP/LP every tick | 0x2011 | §5.3 |
| 77 | `&enterminihouse` | ac_EnterMiniHouse `0041df80` | 100 | — | nothing (empty) | — | §5.6 |
| 78 | `&horsespeed` | ac_HorseSpeed `0041ded0` | 100 | `<n>` | set the GM's mount run speed | — | §5.6 |
| 79 | `&charinform` | ac_CharInform `0041e510` | 10 | — (target) | dump the target's name, level, mode, location, HP (+ player house/booth/ride state) | 0x2011 lines | §5.7 |
| 80 | `&partyinfo` | ac_PartyInform `0041e5e0` | 100 | `[charName]` | dump the party of a player (default: self) from the zone's party mirror | 0x2011 lines | §5.7 |
| 81 | `&propose` | ac_Propose `0041e9d0` | 100 | `<charName> <word>` | run the client's proposal (0x204F) for the GM; the GM's partner is asked, the name only has to exist | 0x2050 / 0x2052 (Z02 §10) | §6.1 |
| 82 | `&proposeres` | ac_ProposeRes `0041eb30` | 100 | `<charName> <1\|other>` | answer a proposal as the GM (0x2051); accept = engagement in the DB | 0x2052; DB 0x1083 (Z02 §10) | §6.1 |
| 83 | `&weddingreset` | ac_WeddingReset `0041ec70` | 100 | — | fake couple-entrance lap with the GM as both partners: the hosting zone cancels its wedding-hall reservation | ring 0x2055; GameLog 0x065F | §6.1 |
| 84 | `&reserve` | ac_WeddingReserve `0041ed70` | 100 | — | the client's hall reservation 0x2053 with all checks | 0x2054 / 0x2052; GameLog 0x065D (Z02 §10) | §6.1 |
| 85 | `&enterready` | ac_WeddingGuestEnterReady `0041ee40` | 100 | — | the client's 0x2056: show the current reservation | 0x2057 | §6.1 |
| 86 | `&enter` | ac_WeddingGuestEnter `0041ef10` | 100 | — | take one invitation if held and link the GM into the wedding hall (Wedding 558,154) without any check | GM's map link | §6.1 |
| 87 | `&learnpassive` | ac_learnPassive `0041f270` | 100 | `<passiveId>` | learn a passive skill through the DB, unchecked | DB 0x4801 (ispassive 1) → 0x4804, WM 0x4820 | §6.2 |
| 88 | `&unlearn` | ac_Unlearnskill `0041f050` | 100 | `<skillId>` | delete a skill through the DB, unchecked (≥ 30000 = passive) | DB 0x4825 → 0x4827 | §6.2 |
| 89 | `&unlearnpassive` | ac_UnlearnPassive `0041f160` | 100 | `<passiveId>` | delete a passive skill (id + 30000) through the DB | DB 0x4825 → 0x4827 | §6.2 |
| 90 | `&wedding` | ac_Wedding `0041f3a0` | 100 | `<charName>` | marry the GM to the named player if the two are engaged (DB 0x1091, skips the ceremony) | DB 0x1091 → 0x1092 (Z07) | §6.1 |
| 91 | `&showid` | ac_ShowPlayerID `0041f4a0` | 100 | — | list names / guilds of the visible players to the GM, only on NameHide maps; the client ignores the packet (B23) | 0x1C16; 0x2011 on refusal | §6.5 |
| 92 | `&mobhatchery` | ac_MobHatchery `0041f6c0` | 100 | — | dump the regen groups and breeders of the GM's map | 0x2011 lines | §6.5 |
| 93 | `&allcritical` | ac_AllCritical `0041f770` | 100 | `[0]` | every normal attack of the GM is critical; `0` = off | — | §6.4 |
| 94 | `&erasechargebuf` | ac_EraseChargeBuff `0041f620` | 100 | — | set every charged buff of the GM to an expired end date | — | §6.4 |
| 95 | `&startGT` | ac_StartGuildTournament `0041f850` | 100 | `<char1> <char2> [playMin]` | start guild tournament map 0 here for the two players' guilds, both get member grade 0 | GT start (Z16); 0x2011 | §6.3 |
| 96 | `&flagcapture` | ac_FlagCapture `0041fa10` | 100 | `<npcName>` | start capturing the named flag NPC (0x74CA path) | 0x74CB, 0x2047 (Z08 §8.1); 0x2011 | §6.3 |
| 97 | `&useguildskill` | ac_UseGuildSkill `0041fb20` | 100 | `<n>` | use guild-tournament skill n on the GM's map (no ack) | GT system (Z16); 0x2011 | §6.3 |
| 98 | `&observerlinkto` | ac_ObserverLinkTo `0041fc00` | 100 | `<seed>` | enter tournament `seed` as observer without asking the WM | 0x74D8; WM 0x4019 if another zone | §6.3 |
| 99 | `&observerout` | ac_ObserverOut `0041fcb0` | 100 | — | leave the tournament map (stored position or Roumen) | GM's map link | §6.3 |
| 100 | `&HP` | ac_HPChange `004248e0` | 100 | (part 6) | | | |
| 101 | `&SP` | ac_SPChange `00424a70` | 100 | (part 6) | | | |
| 102 | `&speed` | ac_EditSpeed `0041fd50` | 50 | `<n>` | set the GM's base move speed (min 1000) | — | §6.4 |
| 103 | `&linktosavedata` | ac_LinktoSaveData `004194f0` | 100 | — | teleport to the current map's save-link point | as &linkto | §3.1 |
| 104 | `&reloaddata` | ac_ReLoadData `00424c00` | 100 | (part 6) | | | |
| 105 | `&captivate` | ac_Captivate `00424d60` | 100 | (part 6) | | | |
| 106 | `&ignoreskillcooltime` | ac_IgnoreSkillCoolTime `00424ec0` | 100 | (part 6) | | | |
| 107 | `&쿨타임무시` | ac_IgnoreSkillCoolTime `00424ec0` | 100 | (part 6) | | | |
| 108 | `&invenview` | ac_InventoryView `004206b0` | 100 | — | list the GM's inventory and equipment (cell, key, name) | 0x2011 lines | §6.6 |
| 109 | `&runto` | ac_RunTo `0041fe20` | 100 | `<x> <y>` | move the GM server-side towards (x, y) at speed 10000; the client is not told | — | §6.4 |
| 110 | `&ghostremove` | ac_GhostRemove `0041fef0` | 100 | — | remove every dropped item, NPC, mob, door, bandit and effect object of the GM's map | removal packets (Z09 §13) | §6.5 |
| 111 | `&curtime` | ac_CurTime `0041ffb0` | 100 | — | show the world date/time and world seconds | 0x2011 | §6.6 |
| 112 | `&amibusy` | ac_AmIBusy `004200d0` | 100 | — | show the KQ list size and the GM's mob kills in the map's KQ | 0x2011 lines | §6.6 |
| 113 | `&knockback` | ac_KnockBack `00420350` | 100 | — (target) | STA_KNOCKBACK on the GM with the target as setter (B22) | 0x2429, 0x2427 / 0x1C18 (Z03) | §6.4 |
| 114 | `&partblock` | ac_PartBlock `00420470` | 100 | `<x> <y> <r>` | write the move / attack block grid around (x, y) into PartBlock.txt | — | §6.5 |
| 115 | `&debuglogging` | ac_DebugLogging `00420760` | 100 | `<BalanceLog\|other> <0\|1>` | switch BalanceLog or all debug logs (also AmpersandCommandLog) on/off | 0x2011 | §6.6 |
| 116 | `&&&` | (no-op) `00402370` | 100 | — | nothing: empty function FUN_00402370 | — | §3.6 |
| 117 | `&npcrevive` | ac_NPCRevive `004231a0` | 100 | (part 6) | | | |
| 118 | `&ts_DiceFix` | ac_TaiSai_DiceFix `00420860` | 100 | `<ddd>` | fix the next throw of the mini-house TaiSai table the GM is in | 0x2011 on failure | §6.7 |
| 119 | `&ts_DiceProbability` | ac_TaiSai_DiceProbability `004209f0` | 100 | `[<ddd> <weight>]` | set one outcome weight of that table (no argument: reload all) | 0x2011 on failure | §6.7 |
| 120 | `&GB_DiceFix` | ac_Gamble_TaiSai_DiceFix `00420bb0` | 100 | `<ddd>` | fix the next throw of the targeted gamble-house TaiSai machine | 0x2011 on failure | §6.7 |
| 121 | `&GB_DiceProbability` | ac_Gamble_TaiSai_DiceProbability `00420d30` | 100 | `[<ddd> <weight>]` | set one outcome weight of that machine (no argument: reload all) | 0x2011 on failure | §6.7 |
| 122 | `&makeraid` | ac_makeraid `00420ef0` | 100 | — | turn the GM's party into a zone-only raid (second member moved to raid party 1); WM not told, members not linked (B26) | 0x2011 | §7.1 |
| 123 | `&outraid` | ac_outraid `00421040` | 100 | — | remove the GM from its raid in the zone copy; fewer than 2 left: dissolve it (zone only, B27) | 0x2011 | §7.1 |
| 124 | `&inraid` | ac_inraid `00423330` | 100 | (part 6) | | | |
| 125 | `&PlayIns` | ac_PlayInstanceDungeon `00421190` | 100 | — | on an instance map: start the instance script on a free instance keyed {PARTY, GM charNo} (B28) | — | §7.2 |
| 126 | `&bigbang` | ac_BigBang `004240d0` | 100 | (part 6) | | | |
| 127 | `&alllearnskill` | ac_AllLearnSKill `004212e0` | 100 | — | teach every active / passive skill whose book fits the GM's class and level and that is not known (persistent) | 0x4801 per skill to the Character DB (→ 0x4804) | §7.3 |
| 128 | `&levelup` | ac_LevelUp `00421710` | 100 | `[<n>]` (1) | n level-ups without EXP and without the level limit (B30); persistent | 0x240C, 0x240D, WM 0x1074 / 0x400E, GameLog 0x041E, DB save, 0x4810 | §7.3 |
| 129 | `&showallchar` | ac_ShowAllChar `00423480` | 100 | (part 6) | | | |
| 130 | `&루아인수` | ac_LuaSec `0041e6d0` | 100 | — | show the Lua certification counters | 0x2011 | §5.7 |
| 131 | `&testlink` | ac_TestLink `004217e0` | 50 | — | run the 0x181F multi-link request for "RouCos02" (needs a clicked link NPC) | 0x1820 or a map link | §7.2 |
| 132 | `&gtieffect` | ac_GuildTournamentItemEffect `004218b0` | 50 | `[<GTIServer id>]` (0 = random) | apply a guild-tournament item effect to the GM (registered GT player only) | 0x74F0 + effect packets (Z16) | §7.2 |
| 133 | `&iareset` | ac_ItemActionCoolTimeReset `00421990` | 50 | — | clear every item-action cool-down | 0x482C; 0x2011 | §7.4 |
| 134 | `&queststart` | ac_QuestStartReq `00419500` | 50 | `[<questId>]` | runs the client handler 0x4414 for that quest (Z08 §3.2) | as 0x4414 | §3.4 |
| 135 | `&questread` | ac_QuestReadReq `00419540` | 50 | `[<questId>]` | runs the client handler 0x4416 (Z08 §3.2) | as 0x4416 | §3.4 |
| 136 | `&disposition` | (no-op) `00402370` | 50 | — | nothing: empty function FUN_00402370 | — | §3.6 |
| 137 | `&idtimechange` | ac_IDTimeChange `00419580` | 50 | `[<min>]` (10) | set the party's instance-dungeon time limit to n minutes | 0x0810 to self; 0x2011 | §3.3 |
| 138 | `&releasechatban` | ac_ReleaseChatBan `00421a60` | 50 | `<charName>` | ask the WM to lift a chat ban (GM needs CHARDATA admin level 50…100); persistent | WM 0x0866 → DB 0x0868; 0x0867 to the GM | §7.7 |
| 139 | `&slotmachine` | (no-op) `00402370` | 1 | — | nothing: empty function FUN_00402370 | — | §3.6 |
| 140 | `&godofslotmachine` | ac_GodOfSlotMachine `00419790` | 100 | `<9 symbols>` | force the next slot-machine screens | — | §3.4 |
| 141 | `&viewaggrolist` | ac_ViewAggroList `004196f0` | 50 | — | aggro list of the current target (or self) as notices | 0x2011 | §3.4 |
| 142 | `&ebcu` | ac_EquipBelongedCancelUse `00421b00` | 50 | `<boundSlot> <cancelSlot>` | run the unbinding-item request (0x3048) on two inventory slots | as 0x3048 (DB 0x34A6, 0x3049) | §7.4 |
| 143 | `&luaobserver` | ac_LuaObserver `00419730` | 100 | `[x]` | with an argument: self becomes the Lua observer; without: observer cleared | 0x2011 later (Z09 §14.7) | §3.4 |
| 144 | `&luafuncexec` | ac_LuaFuncExec `00419760` | 100 | `<func> <arg>` | call a Lua function of the current target's AI script | — | §3.4 |
| 145 | `&mobitemdrop` | ac_MobItemDrop `00421ba0` | 100 | — | nothing: empty body | — | §7.4 |
| 146 | `&getmoney` | ac_GetMoney `00421bf0` | 100 | `<n>` | add n Cen (u32; negative adds 2^32 − \|n\|, B31); persistent; the answer repeats the last pick message (B32) | DB 0x3438; 0x1033; 0x300A | §7.4 |
| 147 | `&fnpc` | ac_FindNPC `00421cb0` | 100 | `<npcIndexName>` | show name, map and position of the first NPC with that MobInfo index in this zone | 0x2011 | §7.5 |
| 148 | `&RegenNPC` | ac_RegenNPC `00421e50` | 100 | `<npcIndexName> [<x> <y>]` | spawn a dynamic copy of a table NPC of the GM's map at (x, y) or the GM's spot | 0x2011 on failure; NPC appears in sight | §7.5 |
| 149 | `&ReleaseNPC` | ac_ReleaseNPC `00421fc0` | 100 | — | take the targeted NPC off the map | 0x2011 on failure; disappear in sight | §7.5 |
| 150 | `&gmtestmode` | ac_GMTestMode `00425020` | 100 | (part 6) | | | |
| 151 | `&arrangeiv` | ac_ArrangeInven `004197e0` | 100 | — | start an inventory auto-arrange (Z04 §12.5) | inventory packets (Z04) | §3.4 |
| 152 | `&cmt` | ac_CameraMoveTest `004220c0` | 100 | `<0\|1> [<aXZ> <aY> <dist> [<x> <y>]]` | set the map's camera state and send a camera move to the whole map (B34) | 0x6C14 to the map; 0x2011 | §7.6 |
| 153 | `&reloadid` | ac_IndunReload `00419810` | 100 | `<map>` | drop all running films of the instance map and reload its script | — | §3.3 |
| 154 | `&vie` | ac_ViewSlot_Equip `00419890` | 100 | `<itemIndex>` | preview an item in a view slot (Z09 §17.8) | equipment change to sight | §3.4 |
| 155 | `&viue` | ac_ViewSlot_UnEquip `004198e0` | 100 | `<slot>` | clear one view slot | equipment change to sight | §3.4 |
| 156 | `&viuea` | ac_ViewSlot_UnEquipAll `00419910` | 100 | — | clear all view slots (Z09 §17.8) | equipment change to sight | §3.4 |
| 157 | `&setlp` | ac_Setlp `00422330` | 100 | `<n>` | set the GM's current LP (memory, no packet) | — | §7.6 |
| 158 | `&movelayer` | ac_MoveNewLayer `00419930` | 100 | `<layerType> <numberType>` | move self to a new layer (base/tutorial × base/charNo) | sight (Z06 §1) | §3.1 |
| 159 | `&moveotherlayer` | ac_MoveOtherLayer `00419970` | 100 | `<charNo>` | move self to that player's layer | sight | §3.1 |
| 160 | `&godmode` | ac_GodMode `00422350` | 100 | — | fixed damage 1 000 000, no cool-downs, speed 10 000, immortal, +10 000 000 max HP / SP (memory) | 0x2011 ×6 | §7.6 |
| 161 | `&fieldmobcount` | ac_FieldMobCount `00425290` | 100 | (part 6) | | | |
| 162 | `&reloadpetlua` | ac_PetSystemTest_LuaReload `00424740` | 100 | (part 6) | | | |
| 163 | `&getpetinfo` | ac_PetSystemTest_GetTendency `00422480` | 100 | — | show the targeted pet's number, mind and stress | 0x2011 | §7.7 |
| 164 | `&setpetinfo` | ac_PetSystemTest_SetTendency `00422590` | 100 | `<mind> <stress>` | set the targeted pet's mind / stress (owner's PetInfo + DB; persistent) | DB 0xD401; 0x2011 | §7.7 |
| 165 | `&vanishdropitem` | ac_VanishDropItem `00422800` | 100 | — | remove every dropped item of the GM's map | 0x2011; disappear in sight | §7.4 |
| 166 | `&walkto` | ac_WalkTo `004228c0` | 100 | `<x> <y>` | server-side walk of the GM to (x, y) at speed 1000 | — | §7.6 |
| 167 | `&castteleport` | ac_CastTeleport `004229b0` | 100 | `<x> <y>` | jump to (x, y) on the same map | sight / move-fail packets (Z09 §9.3) | §7.6 |
| 168 | `&setobjectdirect` | ac_SetObjectDirect `00422a90` | 100 | `<dir> [<x>]` | set the GM's direction and broadcast it; one argument: not to the GM itself (B33) | 0xBC1C to sight | §7.6 |
| 169 | `&pvp` | ac_SetPVP `00420230` | 100 | `<1\|0>` | set the map's free-PvP flag and tell every player on/off | 0x1812 / 0x1813; 0x2011 usage | §6.5 |

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
    ClusterManager::cm_AllDropFilm(mapclustermanager, args[0])      # FUN_00486ec0 (Z14): stop every film of the instances
        # (the pointer to the name: the push in the disassembly; the decompiler shows args[0][0])
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
    # the zone-wide version through the zone ring is &psummon (§5.1)

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

## 5. Commands, part 3 (handlers FUN_0041cf90 … FUN_0041e880)

### 5.1 Finding and summoning: `&mfind`, `&pfind`, `&psummon`

All three refuse in a mini-house (`vt 0x130 so_ply_MH_GetActiveMH`) with the wall line
"fail to '<word>' : not allowed to do '<word>' in the MH". The GM (or the target) moves with
`so_ply_BriefLink(map, xy)`:

```pseudo
ShinePlayer::so_ply_BriefLink(p, Name3 map, SHINE_XY_TYPE xy)     (vt 0x890)          @ FUN_00452c10
    map or xy null: assert "ShineObjectClass::ShinePlayer::so_ply_BriefLink : Error"; return
    attr = fo_GetFieldAttr(map); none → nothing
    client map = attr.mapidclient; not in mapdatabox (MapInfo) → nothing
    p.so_LinkTo({ server map = map (12), client map (32), x, y }, 6, 9, 10)           # vt 0x600, Z01 §7.1
        # same arguments as &summonplayer / &linkto: another zone's map becomes a zone change
```

```pseudo
&mfind, &몹추적 <mobIndex>   ac_FindMob                                @ FUN_0041cf90
    ShinePlayer::sp_Admin_FindMob(gm, args[0])                          @ FUN_00452e10
        id = mobdatabox.mdb_btree[args[0]] (MobInfo InxName); none → notice "%s is not Mob index"; return
        walk gm's map with AxialListMobFind { mobid = id, ObjectType 5 (mob), Skip 0 }
            ali_Work @ FUN_00428130: first object with so_ObjectType (vt 0x4d0) == 5 and so_mob_MobID (vt 0x708) == id
            (Skip is a "take the n-th" counter, always 0 here) → stop
        none → notice "%s is not in this map"
        else gm.so_ply_BriefLink(mob.so_Field.fm_MapID, mob position)   # the GM jumps to the first such mob

&pfind, &캐추적 <charName>   ac_FindPlayer                              @ FUN_0041d050
    gpp payload = PROTO_NC_CHAR_PLAYERSEARCH_RNG { ZONERINGLINKAGESTART start; Name5 charid = args[0] (20) }   (0x1B)
    ZoneRingPacketFindPlayer::zrpb_Request(gm, gpp)                     @ FUN_005a7190
        t = som_FindPlayer(charid)
        t here:
            t has no map → vt 8 zrpb_Failure: notice "%s is not in game"            @ FUN_005a8050
            loc = { t's map fm_MapID, t.x, t.y }
            t in a mini-house (vt 0x130): mh = som_GetObject(t.so_ply_MH_GetMyHandle (vt 0x138));
                loc = mh.so_LoginLocation() (ShineMiniHouse vt 0x14c FUN_00555e50: the house's entrance map + xy);
                no house object or no location: nothing at all
            vt 4 zrpb_Success(gm, { start, map, coord, charid })                     @ FUN_005a7b70
                notice "%s is at %s %d/%d" (name, map, x, y); gm.so_ply_BriefLink(map, coord)
        not here → zone ring (zcs_Send, 0x1D bytes) 0x1068 NC_CHAR_PLAYERSEARCH_RNG,
            start = { machine = own zone no, handle = gm handle, regnum = gm charNo (vt 0x344) }

0x1068 NC_CHAR_PLAYERSEARCH_RNG (ring) { start; Name5 charid }   zls_NC_CHAR_PLAYERSEARCH_RNG  @ FUN_0045b870
    start.machine < 10 and ≠ own zone:
        t = som_FindPlayer(charid); t here and on a map:
            ring 0x1069 NC_CHAR_PLAYERFOUND_RNG { start, Name3 map = t's fm_MapID, SHINE_XY_TYPE coord = t.x/y,
                                                 Name5 charid }   (0x31 bytes)
            # (original bug) Z11-B14: no mini-house substitution here, unlike the local path: a player in a house in
            # another zone is reported (and the GM linked) at the house map itself
        else: forward the packet unchanged (0x1D)
    else (back at the origin): o = som_GetObject(start.handle); o.charNo == start.regnum → zrpb_Failure "%s is not in game"

0x1069 NC_CHAR_PLAYERFOUND_RNG (ring)   zls_NC_CHAR_PLAYERFOUND_RNG                       @ FUN_0045ba60
    not the origin: forward unchanged (0x31); origin: o = som_GetObject(start.handle), charNo check → zrpb_Success
        (notice + so_ply_BriefLink: the GM changes zone to the player's map)

&psummon, &캐소환 <charName>   ac_SummonPlayer                         @ FUN_0041d140
    gm without a map: nothing
    gpp payload = PROTO_NC_CHAR_PLAYERSUMMON_RNG { start; Name5 charid = args[0]; Name3 map = gm's fm_MapID;
                                                   SHINE_XY_TYPE coord = gm.x/y }   (0x2F)
    ZoneRingPacketSummonPlayer::zrpb_Request(gm, gpp)                   @ FUN_005a6fd0
        t here: no map → vt 8 zrpb_Failure: notice "%s is not in game"              @ FUN_005a7f30
                else vt 4 zrpb_Success                                              @ FUN_005a7ab0
                    t = som_FindPlayer(charid) again; t.so_ply_BriefLink(map, coord)   # no message to anyone
        not here → ring (0x31 bytes) 0x106A NC_CHAR_PLAYERSUMMON_RNG with start = { own zone, gm handle, gm charNo }

0x106A NC_CHAR_PLAYERSUMMON_RNG (ring)   zls_NC_CHAR_PLAYERSUMMON_RNG                    @ FUN_0045b700
    not the origin: t here and on a map → zrpb_Success(null, packet): t.so_ply_BriefLink(GM's map, GM's xy)
                    (a zone change for t; nothing goes back to the origin); else forward unchanged (0x31)
    origin: charNo check → zrpb_Failure "%s is not in game"
```

Unlike `&summonplayer` (§4.5), `&psummon` reaches every zone and does not refuse a target that is in a mini-house.
FiestaHeroes lists `&pfind` / `&psummon` as "find / summon a player" *(fh-doc)*; the code adds that `&pfind` also moves the GM.

### 5.2 Mob tools: `&mobdist`, `&killallmob`, `&suicideallmob`, `&suicidemob`

```pseudo
&mobdist   ac_MobDistribute → ShinePlayer::sp_MobDistribute(gm)       @ FUN_0041d250 → FUN_00459410
    so_AllInMap(gm, AxialListMobDistribute { almd_Admin = gm }, 1)      # FUN_0054b9e0: the map's walker with flag 1
                                                                        # (passed through; meaning not read)
        ali_Work @ FUN_004567e0: for every object: notice "%s/%d/%d" (so_CharName (vt 0x56c), x, y); never stops
    # no type filter: one 0x2011 line per object the walk visits (mobs, NPCs, players …); hundreds on a busy map

&killallmob   ac_killallmob → ShinePlayer::sp_KillAllMob(gm)           @ FUN_0041d3c0 → FUN_0055e460
    so_AllInMap(gm, AxialListDeathAura, 0)
        AxialListDeathAura::ali_Work(gm, o)                             @ FUN_0055e190
            same main layer (or either layer −1), so_SubLayer_CanAttack(gm, o),
            o.vt[0x89c]() (true only for ShineMob: the base returns 0, ShineMob's slot returns 1),
            o.smo_GetMode (vt 0x484) ≠ 3 (dead):
                o.so_KilledBy(gm, o.so_GetHP(), 1000, 1)                # vt 0x5bc, Z03 §7: the GM is the killer
                                                                        # (EXP, drops and quest credit as for a kill *(inferred)*)

&suicideallmob   ac_SuicideAllMob                                      @ FUN_0041d540
    so_AllInMap(gm, AxialListMobSuicide { alms_MobID = 0xFFFF }, 0)
&suicidemob <mobIndex>   ac_SuicideMob                                 @ FUN_0041d620
    id = mobdatabox.mdb_btree[args[0]]; none → wall "Invalid mob index"; return
    wall "SuicideMob : %d" (id); so_AllInMap(gm, AxialListMobSuicide { alms_MobID = id }, 0)

AxialListMobSuicide::ali_Work(o)                                      @ FUN_004f18b0
    o.so_ObjectType == 5 (mob) and (alms_MobID == 0xFFFF or o.so_mob_MobID == alms_MobID): alms_SelfKill(o); never stops
AxialListMobSuicide::alms_SelfKill(m)                                 @ FUN_004f1720
    m.so_AmIAlreadyDead (vt 0x28): return
    m.so_KilledBy(m, m.so_GetHP(), 1000, 1)                             # the mob is its own killer: no EXP for anyone
    broadcast to every object in sight of m (so_AllOfRange, default range) 0x243C NC_BAT_DOTDAMAGE_CMD {
        u16 object = m.handle; u32 resthp = 0; u16 damage = m.so_GetHP() (read after the kill);
        u16 abstate = 0x318 (none); u16 hpchangeorder = m.so_mobile_GetHPChangeOrder (vt 0x7e8); u8 IsMissDamage = 0 }  (0x0F)
    so_DamageLog(m, "alms_SelfKill", …); resthp == 0 (always): m.so_mobile_DeadCheck(4) (vt 0x8d4, Z03 §7)
```

The client draws 0x243C as a damage-over-time tick (Z03); with `resthp` 0 the mob dies on screen.

*(fh-doc)* says `&suicidemob` kills "the first alive" mob of the index; the walker returns 1 (go on) for every mob, so
every mob of that index on the map dies. *(fh-doc)* `&mfind` says "first alive": the code does not test life.

### 5.3 Combat debug: `&deathaura`, `&immortal`, `&staticdamage`, `&mobdamage`

`ShinePlayer.sp_AdminFunction` (+0x29318, a member-function pointer *(pdb2016)*) is called once per player tick by
`ShinePlayer::so_Routine` FUN_0056c790. It is reset to `sp_NoAdmin` FUN_0055e150 (empty) at map login
(`sp_NC_MAP_LOGINCOMPLETE_CMD` FUN_00443390), at socket connect (`so_FirstActionAfterSocketConnect` FUN_00554870) and on
revive (`sp_ReviveNow` FUN_0057d290); the last two and the login also set `smo_admindamage` (+0x1e7c) = −1.
A zone change or a death therefore ends every mode below.

```pseudo
&deathaura   ac_deathaura                                              @ FUN_0041dd70
    toggle sp_AdminFunction between sp_DeathAura and sp_NoAdmin (no message)
    ShinePlayer::sp_DeathAura(gm)   (every tick)                       @ FUN_0055e2a0
        so_AllOfRange(gm, center = gm position, range = gm.smo_admindamage, AxialListDeathAura)   # FUN_0054baf0
        # every attackable live mob in range dies with the GM as killer (ali_Work as in &killallmob).
        # The radius is the &staticdamage value: 0 → the map's sight range; the default −1 kills nothing *(inferred:
        # the map's range walk with a negative radius)*. So the aura needs "&staticdamage <radius>" first, which also
        # fixes the GM's damage to that value.

&immortal   ac_immortal                                                @ FUN_0041ddf0
    sp_AdminFunction == sp_Immortal:
        sp_MiscFlag.InAdminImmortal = 0; sp_AdminFunction = sp_NoAdmin; wall "Immortal Mode False"
    else: InAdminImmortal = 1; sp_AdminFunction = sp_Immortal; wall "Immortal Mode True"
    ShinePlayer::sp_Immortal(gm)   (every tick)                        @ FUN_0055e390
        CurHP = so_MaxHP (vt 0x4f0); CurSP = so_MaxSP (vt 0x4f4); so_ply_Sen_GainLP(so_ply_Sen_MaxLP) (vt 0xd98/0xd94)
        # a direct write: no HP/SP packet in this function; the client sees the refill with the next HP/SP change (Z03)
    # &godmode (§7.6) sets sp_Immortal too; &deathaura replaces the immortal function (the flag stays set)

&staticdamage [n]   ac_staticdamage                                    @ FUN_0041dfd0
    gm.smo_admindamage (+0x1e7c, pdb2016) = (args[0] given and ac_Scanf(args[0]) ≥ 0) ? that value : 0
    # > 0: every normal hit (smo_SwingDamage, so_Bash) and skill hit (smo_SkillBlast) of the GM deals exactly n and
    # never misses (Z03 §3.2 "fixedDamage"); 0 switches it off (≤ 0 = off); also the &deathaura radius

&mobdamage <freeze Y/N> <recover Y/N> [factor]   ac_mobdamage          @ FUN_0041d460
    ShineMob::sm_DamageSet(gm, args[0] … args[9])   (__cdecl; name pdb2016, the body has nothing mob-specific)   @ FUN_0055e5f0
        g_LUA_SCRIPT_SECURITYFactor.lsf_IsFreeze  = args[0][0] ∈ {'Y','y'}
        g_LUA_SCRIPT_SECURITYFactor.lsf_IsRecover = args[1][0] ∉ {'N','n'}
        args[2] given: v = sscanf("%lg"); v > 0 → lsf_Factor = v
        notice "%g" (lsf_Factor)
    # lsf_Factor is the run-time certification's combat factor (Z10 §6.3): it multiplies every swing's hit roll
    # (Z03 smo_SwingDamage) and grows × 1.01 per world minute unless frozen; "recover" lets the next Lua
    # certification reset it to 1.0. The word is a test hook for that mechanism.
```

### 5.4 Bonus events: `&expbonus`, `&itembonus`, `&fieldbonus`

Per map `FieldMap.fm_FieldBonus` (+0x4c) = `FieldBonus { int fb_Experience; int fb_DropRate }` *(pdb2016)* in
per mille, both 1000 after `FieldMap::fm_Init` FUN_00464bc0. These two commands are the only other writers (Z09 §11.9
lists only `fm_Init` / `operator=`). The only reader in the zone is the drop roll: `dilfs_ItemDrop` FUN_0048ef80 takes
`max(fb_DropRate, 0)` as `rr_FieldBonus` (Z09 §11.2). `fb_Experience` has no reader: `&expbonus` has no effect on
EXP (original bug) Z11-B15.

```pseudo
&expbonus <A | anything> <rate>   ac_BonusExp                          @ FUN_0041e190
&itembonus <A | anything> <rate>  ac_BonusItem                         @ FUN_0041e2d0
    gm without a map: nothing
    argnum ≠ 3: wall "Usger : &expbonus [map] [rate]" / "Usger : &itembonus [map] [rate]"; return
    rate = ac_Scanf(args[1]); rate < 1 → 0                              # per mille: 1000 = normal, 2000 = double
    args[0][0] ∈ {'A','a'} → every map of every zone:
        local 11-byte packet { u16 opcode 0x1810 NC_MAP_EXPBONUS_RNG / 0x1811 NC_MAP_ITEMBONUS_RNG,
                               ZONERINGLINKAGESTART start (not initialised here), u16 bonus = (u16) rate }
        ZoneRingPacketExpBonus::zrpb_Request(gm, pkt) / ZoneRingPacketItemBonus::zrpb_Request   @ FUN_005a79a0 / FUN_005a7890
            copy into gpp; gm given: start = { own zone no, gm handle, gm charNo }
            zcs_Send(ring, 0x0B)
            vt 4 zrpb_Success(null, pkt): for every loaded map of fieldlist (in-use flag set):   @ FUN_005a9100 / FUN_005a9040
                map.fm_FieldBonus.fb_Experience / .fb_DropRate = bonus
    else → only gm's current map: fb_Experience / fb_DropRate = rate (full int)
        # (original bug) Z11-B16: the usage line asks for a map, but the word is never compared with a map name:
        # anything other than "A…" means "this map"

0x1810 NC_MAP_EXPBONUS_RNG / 0x1811 NC_MAP_ITEMBONUS_RNG (ring) { start; u16 bonus }      @ FUN_0045bf30 / FUN_0045bff0
    start.machine < 10 and ≠ own zone: zrpb_Request(null, packet): forward unchanged (start kept) + apply to all maps here
    back at the origin: nothing (stops)

&fieldbonus, &필드보너스   ac_FieldBonus                                @ FUN_0041e410
    gm on a map: wall "E[%g%%] D[%g%%]" (fb_Experience / 10.0, fb_DropRate / 10.0)   # percent: "E[100%] D[100%]"
```

The values are memory only: a zone restart, or a map that is reloaded (`fm_Init`), is back to 1000. Nothing tells
the players. The ring path sends the rate as u16, the local path keeps the int, so rates above 65535 differ
(irrelevant in practice).

### 5.5 Server and map tools

```pseudo
&serversocketcut <n>   ac_ServerSocketCut                              @ FUN_0041d760
    n = ac_Scanf(args[0]) (unsigned); n < 4:
        sock2gameDB[n].m_Status = sock2gamelog[n].m_Status = sock2wldman[n].m_Status = SESSION_STATUS_CLOSEING (3)
            # ZoneBaseSession::SESSION_STATUS (pdb2016): 0 EMPTY, 1 CONNECTED, 2 CONNECTING, 3 CLOSEING
    # the next ZoneServer::zs_PacketProcess sees a state outside {1, 2}; SocketBundle::sb_Packet closes the socket and
    # reconnects after the pool's delay (Z09 §1.5). One index cuts slot n of all three pools at once (WM, GameDB,
    # GameLog); with one server of each kind only n = 0 does anything. Test word for reconnect handling.

&emptymap <map>   ac_EmptyMap                                          @ FUN_0041d850
    f = ClusterManager::cm_FindEmpty(mapclustermanager, args[0])        @ FUN_004a05e0
        cluster = the MapCluster whose mc_MapIndex == args[0] (12; list search with mc_CompName FUN_0049f580)
        none → null; else MapCluster::mc_FindEmpty(cluster)             @ FUN_0049f460
            round robin from mc_Pointer + 1 over the cluster's mc_MapNumber instance maps: the first whose
            fm_Multiflex (Movie::CinemaComplex) first u16 is 0 *(inferred: no film running)*; mc_Pointer is left there
    wall f ? f.fm_MapID (12) : "NULL"
    # side effect: the cluster's cursor moves, so the next instance assignment (Z14) starts after this map

&zonelink   ac_ZoneLinkTest                                            @ FUN_0041d950
    ring 0x0811 NC_MISC_ZONERINGLINKTEST_RNG { start = { own zone, gm handle, gm charNo }, u8 mechines = 0 }   (10 bytes)
0x0811 (ring) { start; u8 mechines; Name4 addr[mechines] }   zls_NC_MISC_ZONERINGLINKTEST_RNG   @ FUN_0045b4d0
    always first: addr[mechines] = zipc_GetNextIP() (16 bytes, this zone's next-zone address); mechines++
        (written in place into the received buffer; no bound *(inferred: ≤ 9 zones in practice)*)
    not the origin: forward (mechines × 16 + 10 bytes)
    origin: o = som_GetObject(start.handle), charNo check: notice "%d mechines travel complete" (mechines), then one
        notice per entry with the address string
    # one ring lap: the GM sees every zone's next-hop address, the last one being the own zone's

&guildtournament   ac_GuildTournament                                  @ FUN_0041da30
    attr = fo_GetFieldAttr("GuildT01") (fixed; the GM's arguments are not read)
    attr none or its client map not in mapdatabox: wall "Invalid map name"; return
    WorldManagerSession::wms_GuildTournamantStart(sock2wldman[0], &PROTO_NC_GUILD_TOURNAMENT_START_CMD {
        nTournamentSeed 0, nTournamentMapNo 0, nExploerTimeMin 1, nWaitPlayTimeSec 30, nPlayTimeMin 60, nNo1 4, nNo2 1 })
        # FUN_00476de0 is the zone's own handler of the WM's GT start (Z08 §8.2, owned by Z16); called directly, it
        # starts tournament map 0 here as if the WM had ordered it: explore 1 min, wait 30 s, play 60 min, guilds 4 vs 1.
        # Nothing goes to the WM.

&endofkq <kqHandle>   ac_EndOfKingdomQuest                             @ FUN_0041dbd0
    WorldManagerSession::wms_EndOfKQPacket(sock2wldman[0], ac_Scanf(args[0]))   @ FUN_005a4800 (Z09 §26.1)
        → WM 0x5810 NC_KQ_Z2W_END_CMD { u32 Handle }   (W04 §6.3: the WM marks the KQ ended, state 5)
        and kqpl_EndOfKQ(&g_KQContributeList, h): drops the KQ's contribution list
    # unlike the script statement endofkq (Z09 §26.1) the map is not cleared and the handle is not checked

&Reroadkingdomquest <script>   ac_ReroadKingdomQuest                   @ FUN_0041dc80
    book = ScenarioBookShelf::sbs_GetScenarioBook(scenarioshelf, args[0], &index)   @ FUN_00507b90 (Z09 §22.5); none: nothing
    ClusterManager::cm_AllDropFilm(mapclustermanager, args[0])          # FUN_00486ec0 (Z14): stop the films named so
    ScenarioBookShelf::sbsReLoad(scenarioshelf, args[0])                # FUN_00507c90: reload the book
    # the same pair as &reloadid (§3.3), keyed by the script name instead of an instance map; no message
```

### 5.6 Player tools: `&horsespeed`, `&enterminihouse`, `&silence`, `&chargeditem`

```pseudo
&horsespeed <n>   ac_HorseSpeed                                        @ FUN_0041ded0
    gm.sp_RideCast.runspd = (short) ac_Scanf(args[0])   # the mount run speed (Z10 §5.4: the speed base while riding)
    # no packet is sent; the server's speed limits use it from now on, the client is not told *(inferred)*

&enterminihouse   ac_EnterMiniHouse                                    @ FUN_0041df80
    empty (no profiler either)

&silence, &조용히 <charName>   ac_KeepFromChat                          @ FUN_0041e090
    t = som_FindPlayer(Name5 = args[0] (20)); none → wall "Player not found"
    t.so_ply_KeepFromChat(gm)   (vt 0x8f0)                             @ FUN_00549f60
        gm notice "Success to silence"; nothing else
    # (original bug) Z11-B17: no chat ban is set; the working chat ban is the WM one, 0x0865 NC_MISC_SPAMMER_ZONE_CHAT_BAN_CMD (Z01 §9), and
    # &releasechatban (§7.7)

&chargeditem <effectHandle>   ac_ChargedItem                           @ FUN_0041d2f0
    ShinePlayer::sp_ChargedItemTest(gm, ac_Scanf(args[0]))              @ FUN_00451360
        row = first chargedbuffdatabox entry (ChargedEffect data) with Handle == n; none: nothing
        e = first element of gm.sp_ChargedItem.ci_List (head index ≠ −1; vt 8 = element by index); none: nothing
        ChargedItemEffectElement::ciee_SetEndTime(e, row, now(world) as yy−100, mon+1, mday, hour, min + 5)  @ FUN_004504d0
            # e.ciee_Index = row; end = now + 5 minutes; the minute is not carried: 55…59 become 60…64
            # (original bug) Z11-B18
    # memory only: no packet, no DB write; turns the GM's first charged buff into buff n expiring in 5 minutes,
    # to test the expiry (Z09 §2.4 per-minute check)
```

### 5.7 Information: `&charinform`, `&partyinfo`, `&루아인수`, `&parameterview`, `&isblock`

All answers are 0x2011 notices to the GM. `StringMaker::Maker` (`maker`, FUN_0058dc10 … FUN_0058dfd0) builds one line
per `<< Finisher`, which sends it with `f_Admin.vt[0x784]` (so_ply_Notice).

```pseudo
&charinform   ac_CharInform                                            @ FUN_0041e510
    t = current target (vt 0x75c); none → wall "Target needed"
    t.so_SendInform2Admin(gm)   (vt 0x8d8)
        ShineObject (drop item, mini-house …): nothing                  @ FUN_0058e080
        ShineMobileObject (doors; base of the rest)                     @ FUN_0058e0d0
            "Name : %s", "Level : %d" (vt 0x4d8), "Mode : %d" (vt 0x484), "Location : <map>/<x>/<y>" or "Location : Null",
            "HP : <cur>/<max>"
        ShineMob (also NPCs): the mobile-object lines                   @ FUN_0058e5d0
        ShinePlayer: the mobile-object lines, then                      @ FUN_0058e310
            "MiniHouse(Inven) : <the mini-house inventory cell>", "MiniHouse(SkinHandle) : <handle | NULL handle | NULL Data>"
            mode 4 (camp): "MiniHouse(Brief:Camp) : <brief Equ_Head>"
            mode 5 (booth): "MiniHouse(Brief:Booth) : <Equ_Head>[<board text | NULL>]", " [<brief shape +0xd>]",
                            " [<sb_SignBoard>]" when a booth board exists
            mode 6 (riding): "Riding(Brief:Camp) : <ride horse>"

&partyinfo [charName]   ac_PartyInform                                 @ FUN_0041e5e0
    t = som_FindPlayer(args[0]) (this zone), else gm itself
    t.so_ply_SendPartyInformTo(gm)   (vt 0x578)                        @ FUN_004ccf30
        "PartyRegNum[%d]CharRegNum[%d]HndW[%d]HndZ[%d]CharID[%s]"  (vt 0x550, vt 0x344, so_GetWMSHandle vt 0x340,
                                                                    zone handle, name)
        party = partycontainer[partyRegNum]; none → "Null party"
        else "Party member : %d\n", and per member
            "RegNum[%d]hndZ[%d]hndW[%d]CharID[%s]Level[%d]Flag[%d]Merchine[%d]Obj[%s]"  (Obj = "Ext" when the member
            has an object pointer in this zone, else "NULL")       # the zone's party mirror (Z08 §1)

&루아인수   ac_LuaSec   (profiler label "AmpersandCommand::ac_PartyInform", copy-paste)        @ FUN_0041e6d0
    notice "Thread : %d : %d/%d : %d/%d\n" = g_LuaArgument { Count : Summary / Interval : SkipNumber / MaxSkip }
    # the run-time certification counters (Z10 §6.1, §6.2)

&parameterview <k>   ac_ParameterView → ShinePlayer::sp_ParameterView(gm, ac_Scanf(args[0]))   @ FUN_0041e7d0 → FUN_004cb670
    k = 0…11 selects one stat: Str, Con, Dex, Int, Men, WCmin, WCmax, AC, TH, TB, CR (CriDamRate +0x80), MCR (MagCriDamRate +0x84)
    notice "<Stat>/%d/%d/%d/%d/%d/%d/%d/%d/%d" = that member of nine smo_Param (Parameter::Container, +0xfc0) clusters:
        PureCharParam, Item.Plus, Item.Rate, Upgrade.Plus, Upgrade.Rate, WeaponTitle.Plus, WeaponTitle.Rate,
        PassiveSkill.Plus, PassiveSkill.Rate     # not ItemPowerRate, AbnormalState, LastTune or Total (Z12 owns the layers)
    other k: nothing

&isblock   ac_IsBlock                                                  @ FUN_0041e880
    for r = 0…3: b[r] = mbi_OccupCellCheck(gm map's fm_BlockInfo, gm.x, gm.y, r)   # FUN_0049e230, Z09 §9.2
    notice "Block : %d/%d/%d/%d  0:Block 1:Non-Block"
    # 1 = some free cell in the (2r+1)² square around the GM; gm without a map dereferences null (GMs are on a map)
```

## 6. Commands, part 4 (handlers FUN_0041e9d0 … FUN_00420d30)

### 6.1 Wedding: `&propose`, `&proposeres`, `&weddingreset`, `&reserve`, `&enterready`, `&enter`, `&wedding`

Most of these words call the client's wedding handlers (Z02 §10) with a packet built in the global send buffer `gpp`.
Those handlers never read the handle in their packet: the counterpart is always the caller's partner from the
wedding data (`p+0x5cc8`, Z02 §10), so the character a GM names here only has to be online in this zone.
`MH` = `gm.so_ply_MH_GetActiveMH()` (vt 0x130) is non-zero, i.e. the GM is inside a mini-house. In that case five
of the words refuse with the `&pfind` text "fail to 'pfind' : not allowed to do 'pfind' in the MH"
(original bug) Z11-B19.

```pseudo
&propose <charName> <word>   ac_Propose                                @ FUN_0041e9d0
    MH: wall "fail to 'pfind' : …"; return                                    # Z11-B19
    t = som_FindPlayer(Name5 = args[0] (20)); none → wall "Failed : Cannot find character"; return
    gpp = 0x204F NC_ACT_WEDDING_PROPOSEREQ_REQ { u16 to = t.handle, char propose_word[37] = args[1] (37, last byte 0) }
    ShinePlayer::sp_NC_ACT_WEDDING_PROPOSEREQ_REQ(gm, gpp, 0x27, 0xFFFF)       @ FUN_0059f760 (Z02 §10)
        # every check of the client request applies (mode, single, partner within 100 units); the proposal goes to the
        # GM's partner, not to t; replies 0x2052 / 0x2050 as described there

&proposeres <charName> <1|other>   ac_ProposeRes                       @ FUN_0041eb30
    MH: wall "fail to 'pfind' : …"; return                                    # Z11-B19
    t = som_FindPlayer(args[0]); none → wall "Failed : Cannot find character"; return
    gpp = 0x2051 NC_ACT_WEDDING_PROPOSEACK_ACK { u16 from = t.handle, u8 reply = (args[1][0] == '1') }
        # response_word[37] (payload +3) is not written: it holds whatever the last packet left in gpp
        # (original bug) Z11-B20
    ShinePlayer::sp_NC_ACT_WEDDING_PROPOSEACK_ACK(gm, gpp, 0x28, 0xFFFF)       @ FUN_0059f900 (Z02 §10)
        # reply 1: the proposer (the GM's partner) loses one proposal ring, both get 0x2052 err 0x12C0 with the stale
        # response_word, and the Character DB gets 0x1083 NC_CHAR_WEDDING_PROPOSE_REQ (engagement, persistent)
        # reply 0: the proposer gets 0x12CA (refused) with the stale word

&reserve   ac_WeddingReserve                                           @ FUN_0041ed70
    MH: wall "fail to 'pfind' : …"; return                                    # Z11-B19
    ShinePlayer::sp_NC_ACT_WEDDING_HALL_RESERV_REQ(gm, gpp, 0, 0xFFFF)          @ FUN_005a2330 (Z02 §10)
        # = the client's 0x2053 with all its checks; success reserves this zone's hall (WeddingHall::wh_Reserv), gives
        # 10 invitations to both and logs 0x065D

&enterready   ac_WeddingGuestEnterReady                                @ FUN_0041ee40
    MH: wall "fail to 'pfind' : …"; return                                    # Z11-B19
    ShinePlayer::sp_NC_ACT_WEDDING_HALL_GUEST_ENTER_READY_REQ(gm, gpp, 0, 0xFFFF)   @ FUN_0059fb60 (Z02 §10)
        # gm ← 0x2057 with the current reservation (groom, bride, entry / wedding times)

&enter   ac_WeddingGuestEnter                                          @ FUN_0041ef10
    MH: wall "fail to 'pfind' : …"; return                                    # Z11-B19
    ShinePlayer::sp_DestroyItem(gm, gm.handle, itemdatabox.idb_specialid.sii_InvitationCard, 1, null)
        # one invitation, if the GM holds one (the result is not checked)
    link = LinkInformTemplete { map "Wedding", "Wedding", x 558, y 154 }
    gm.smo_GetMode() (vt 0x484) == 4 (tent): gm.so_ply_ReinforceFoldtent() (vt 0x488)
    gm.so_LinkToReserv(link, 1)   (vt 0x3fc, Z01 §7.1)
    # = the success path of 0x2058 NC_ACT_WEDDING_HALL_GUEST_ENTER_REQ (Z02 §10) without its checks: no invitation,
    # couple membership or entry window is needed and no hall needs to be reserved

&weddingreset   ac_WeddingReset                                        @ FUN_0041ec70
    zone ring ← 0x2055 NC_ACT_WEDDING_COUPLE_ENTRANCE_RNG {                    # 0x10 bytes (pdb2016 struct)
        ZONERINGLINKAGESTART start = { u8 machine = own zone no, u16 handle = 0xFFFF, u32 regnum = 0xFFFFFFFF },
        u32 groom = gm charNo (vt 0x344), u32 bride = gm charNo, u8 RecallCount = 0 }
    zcs_Send(&zoneconnect, gpp, 0x12)
```

The 0x2055 lap is the one the hall timer starts (`WeddingHall::wh_Routine` FUN_005a2a10, Z13 scope "wedding hall
timetable and ceremony flow"): at the entry time the hosting zone sets `Started`, recalls groom and bride if they are
its own (`wh_RecallCouple` FUN_005a27f0), and if not both were found sends this packet round the ring with the count.
`&weddingreset` fakes such a lap with the GM as both partners:

```pseudo
0x2055 NC_ACT_WEDDING_COUPLE_ENTRANCE_RNG { start, u32 groom, u32 bride, u8 RecallCount }   zls_…  @ FUN_005a2b60
    start.machine ≠ own zone:
        n = wh_RecallCouple(groom) + wh_RecallCouple(bride)                     @ FUN_005a27f0
            # charNo online here, not in a mini-house, map ≠ "EldPri": destroy one wedding coupon
            # (sii_WeddingCoupon), fold a tent, so_LinkToReserv({ "Wedding", 558, 154 }, 1); true
            # online but in a mini-house: true without a recall; offline / on EldPri / no map: false
        forward the 16 bytes with RecallCount += n                             (zcs_Send, 0x12)
    start.machine == own zone (back at the origin):
        RecallCount == 0: weddinghall.Reserved = 0, Started = 0
                          GameLog ← 0x065F NC_LOG_WEDDING_HALL_CANCEL { u32 groom, u32 bride }     ("WeddingHall::wh_Cancel")
        else:             WeddingHall::wh_Start(&weddinghall)                   @ FUN_005a25a0
                          # play film "Wedding/Wedding" on map "Wedding", announce, GameLog 0x065E NC_LOG_WEDDING_HALL_START
```

With the GM as groom and bride nobody is recalled anywhere (the GM is in the origin zone, which does not recall on the
lap), so the count returns 0 and the origin **cancels its hall reservation**: `Reserved` / `Started` are cleared and a
cancel with the GM's charNo twice is logged. The couple that had reserved is not told, keeps its invitations and
its `ApplicationLimit`, and the hall can be reserved again (`wh_Reserv`). If the ring is broken the packet never
comes back and nothing is reset *(inferred)*. The reset is effective only on the zone that hosts the hall.

```pseudo
&wedding <charName>   ac_Wedding                                       @ FUN_0041f3a0
    t = som_FindPlayer(args[0]); none, or t.so_ObjectType() (vt 0x4d0) ≠ 2: nothing
    Character DB ← 0x1091 NC_CHAR_WEDDING_DO_REQ { u16 handle = gm.handle, u32 charNo = gm charNo, u32 Partner = t charNo }
        (12 bytes with the opcode, sock2gameDB; too long: assert "PineEventScriptNode::ac_Wedding::sa_Step : Packet Too Long")
    # no message to the GM; the DB answer 0x1092 → GameDBSession::gds_NC_CHAR_WEDDING_DO_ACK FUN_005a1830 (Z07)
```

`p_Char_Wedding_Do` (D02 §0x1091, *(db-backup)*) marks both `tMarriage` rows married (`nStatus 2`, `nSubStatus 0`,
`dSubWhen` = now + 7 days, `nMarriageCount + 1`) only if each row exists and points at the other; otherwise it rolls
back and answers failure. So `&wedding` marries **the GM** to the named character, and only when the two are already
engaged to each other (an accepted proposal, 0x1083): it skips the hall reservation and ceremony, which normally end
in the same 0x1091 sent by the script statement `weddingcomplete` (Z09 §26.7). It cannot marry two other players.

### 6.2 Skills: `&unlearn`, `&unlearnpassive`, `&learnpassive`

```pseudo
&unlearn <skillId>   ac_Unlearnskill                                   @ FUN_0041f050
    Character DB ← 0x4825 NC_SKILL_ERASE_REQ { u16 handle = gm.handle, u32 charNo, u16 skill = (u16) ac_Scanf(args[0]) }
        (10 bytes with the opcode; assert "AmpersandCommand::ac_Unlearnskill : Packet Too Long", never)
&unlearnpassive <passiveId>   ac_UnlearnPassive                        @ FUN_0041f160
    same packet with skill = (u16)(ac_Scanf(args[0]) + 30000)               # passives are stored as id + 30000 (D04 §2)
&learnpassive <passiveId>   ac_learnPassive                            @ FUN_0041f270
    Character DB ← 0x4801 NC_SKILL_SKILLTEACH_REQ (0x11 bytes) {
        u16 handle, u32 charNo, u32 chrregnum = charNo, u16 skillid = (u16) ac_Scanf(args[0]), u8 ispassive = 1, u16 removeid = 0xFFFF }
```

None of the three checks anything (skill table, class, level, whether the skill is known); the skill-erase item and
its queue (`sp_NC_SKILL_UNLEARN_REQ`, Z03 §9) are bypassed. The DB side (D04 §2):

- **0x4825**: `p_Skill_Del(charNo, skill)` deletes the `tSkill` row (success also when there was none) and answers
  0x4826 err 0x1501 (fail 0x1504). The zone's `so_UnlearnSkillAck` (Z03 §9) removes the skill from memory: id < 30000
  → active list (`csl_UnLearn`), else passive list with err 0x1505 and the passives re-applied; the GM's client gets
  0x4827 NC_SKILL_UNLEARN_ACK ("Deleted %s skills"). `&unlearn 30005` is therefore the same as `&unlearnpassive 5`.
- **0x4801 ispassive 1**: `p_Skill_SetPassive(charNo, skillid + 30000, no old row)` inserts the passive (a duplicate
  fails: 0x4803 → client "Failed to learn the skill."); success 0x4802 → the zone adds it, sends 0x4804
  NC_SKILL_SKILL_LEARNSUC_CMD and tells the WM (0x4820 NC_SKILL_PASSIVESKILL_LEARN_CMD), Z03 §9.3. Any number is
  stored, also ids without a PassiveSkill row *(inferred, as for `&learnskill` §4.4)*.

All three are persistent (the `tSkill` table).

### 6.3 Guild tournament: `&startGT`, `&flagcapture`, `&useguildskill`, `&observerlinkto`, `&observerout`

The tournament system (`GuildTournamentSystem`, the seed table `guildtournamentinfo`, match flow) is Z16's; these
words call its entry points directly.

```pseudo
&startGT <charName1> <charName2> [playMin]   ac_StartGuildTournament   @ FUN_0041f850
    gm without a map: wall "Fail CreateGuildtournamentSystem"; return
    a = som_FindPlayer(args[0]); b = som_FindPlayer(args[1])         # both must be online in this zone
    min = atoi(args[2]); < 1 → 1
    a or b missing: wall "Fail CreateGuildtournamentSystem"; return
    WorldManagerSession::wms_GuildTournamantStart(sock2wldman[0], &PROTO_NC_GUILD_TOURNAMENT_START_CMD {   @ FUN_00476de0
        nTournamentSeed 0, nTournamentMapNo 0, nExploerTimeMin 1, nWaitPlayTimeSec 0, nPlayTimeMin = min,
        nNo1 = a.so_mobile_GetGuildRegnum() (vt 0x818), nNo2 = b's guild })
    GuildTournamentSystem::SetGuildMemberGrade(a charNo, 0); …(b charNo, 0)    @ FUN_0047ccd0
        # static map sm_mapGuildMemberGrades[charNo] = 0; normally filled from the WM's
        # 0x…MEMBERGRADE_ACK (wms_NC_GUILD_TOURNAMENT_ZONE_MEMBERGRADE_ACK FUN_00476460) and copied into the
        # participant record by GuildTournamentSystem::PlayerRegister FUN_0047f970 (m_nGuildMemberGrade)
    wall "CreateGuildtournamentStart"
```

Like `&guildtournament` (§5.5) this runs the zone's own handler of the WM's start order: tournament map 0 starts
here, explore 1 min, no wait, `min` minutes of play, with the guilds of the two named players; nothing goes to the WM.
Grade 0 for both players is *(inferred)* the guild-master grade, so they may use the guild skills (`0x1B4C` authority
check, Z08 §8.1). A player without a guild gives guild number 0, and the same name twice gives one guild against
itself: neither is checked (original bug) Z11-B21.

```pseudo
&flagcapture <npcName>   ac_FlagCapture                                @ FUN_0041fa10
    gm on a map and n = som_FindNPC(Name5 = args[0]):
        gm.so_ply_FlagCaptureCast(n.handle) (vt 0x930)                @ FUN_00477d90
            # = 0x74CA NC_GUILD_TOURNAMENT_FLAGCAPTURE_REQ (Z08 §8.1): all checks apply (tournament map, participant,
            # distance ≤ 100, mode); replies 0x74CB, on success the 4 s cast bar 0x2047 and the capture callback
        wall "FlagCapture"                                             # also when the cast was refused
    else wall "Fail FlagCapture"

&useguildskill <n>   ac_UseGuildSkill                                  @ FUN_0041fb20
    gm without a map: wall "Fail ac_UseGuildSkill"; return
    gt = fm_GetGuildTournamentSystem(gm map); gt: GuildTournamentSystem::GuildBuffUse(gt, gm, atoi(args[0]))   @ FUN_0047b9a0
        # the skill use of 0x74CF NC_GUILD_TOURNAMENT_USESKILL_REQ (Z08 §8.1) without its ack 0x74D0 and the map
        # broadcast 0x74D1; GuildBuffUse's own checks (points, authority, cool time) and error sink apply (Z16)
    wall "Soccess ac_UseGuildSkill"                                    # also without a tournament or when the use failed

&observerlinkto <seed>   ac_ObserverLinkTo                             @ FUN_0041fc00
    ShinePlayer::sp_Guild_Tournamnet_Observer_Enter(gm, atoi(args[0]))     @ FUN_004788c0
&observerout   ac_ObserverOut                                          @ FUN_0041fcb0
    ShinePlayer::sp_Guild_Tournamnet_Observer_Out(gm, 0)                   @ FUN_00475ba0
        !sp_RunRollBackPosEvent(gm) and gm map is a tournament map (fm_IsGuildTournametnMap): sp_2Roumen(gm)
        # = the 0x74DB NC_GUILD_TOURNAMENT_OBSERVER_OUT_REQ handler (Z08 §8.1): back to the stored position, else Roumen
```

`sp_Guild_Tournamnet_Observer_Enter` is what the zone runs when the WM accepts a player's 0x74D7 observer request
(Z08 §8.1: 0x74D7 → WM 0x74D9 → answer → FUN_004788c0). The GM skips the WM:

```pseudo
sp_Guild_Tournamnet_Observer_Enter(p, seed)                            @ FUN_004788c0   (owned by Z16; summary)
    seed == 0xFF or > 31: p ← 0x74D8 NC_GUILD_TOURNAMENT_OBSERVER_ENTER_ACK { u16 err 0x1B42 } (11-byte payload, rest stale)
    mode ∈ {0, 3, 5, 7}: nothing
    !so_AbnormalState_Set_Simple(p, STA_OBSERVERHIDEMODE (289), 1, 0) (vt 0x644): nothing
    mode 4 (tent): fold it (vt 0x488)
    GuildTouramentLoginDataInfo::GetLinkData(guildtournamentinfo[seed], &link, p) false: nothing
    p ← 0x74D8 { u16 err 0x1B40, u8 seed, u32 nNo1, u32 nNo2 }
    tournament map on this zone: so_LinkTo(link, 6, 9, 10) (vt 0x600) + RollBackPosCallBackEvent (return position)
    else: WM ← 0x4019 NC_CHARSAVE_2WLDMAN_LINK_FROM_CMD { u16 wmHandle, u32 charNo, map (12), x, y }; so_LinkTo(link, 6, 9, 10)
```

### 6.4 Character and combat: `&speed`, `&runto`, `&allcritical`, `&knockback`, `&erasechargebuf`

```pseudo
&speed <n>   ac_EditSpeed                                              @ FUN_0041fd50
    ShinePlayer::sp_SetTotalMoveSpeed(gm, max(atoi(args[0]), 1000))       @ FUN_00560150 (Z09 §17.5)
        # PureCharParam.MoveSpeed = n, c_MakeTotal; run speed = Total.MoveSpeed × chrrunspeed / 1000
    # same as Lua cStaticSpeed (Z09 §17.5); no packet here, the client learns it with the next parameter update
    # (inferred, as there); memory only

&runto <x> <y>   ac_RunTo                                              @ FUN_0041fe20
    gm.so_mobile_MoveReserve(&{ ac_Scanf(args[0]), ac_Scanf(args[1]) }, speed 10000, kind 2 (run), backwards 0)   (vt 0x660)
        # FUN_00555970 (Z09 §9.1): the server moves the GM's position towards (x, y) at 10000 units/s, no block check
    # no packet: the GM's client is not told and keeps its own position *(inferred)*; the profiler label is
    # "AmpersandCommand::ac_IgnoreSkillCoolTime" (copied from another handler; harmless)

&allcritical [0]   ac_AllCritical                                      @ FUN_0041f770
    gm.smo_RulesOfNormalAttack (+0x1e74) = (args[0] == "0") ? RulesOfEngagementNormalPY (roe_normalPY)
                                                             : RulesOfEngagementAlwaysCritical (roe_alwaysCritical)
        (ShinePlayer::sp_SetRulesOfEngagement FUN_0054a110)
```

`RulesOfEngagementAlwaysCritical` is `RulesOfEngagementNormalPY` (Z03 §4 table) with the critical-rate slots (vt +4
and +0x24) replaced by `roe_CriticalRateByGlobalAction` FUN_004ffda0 = 1000.0 (‰): every **normal** attack of the GM
is critical; skills use their own rule sets and are unchanged. `&allcritical` without an argument turns it on
(only the exact word "0" turns it off, back to `roe_normalPY`, the set every player has from the `ShineMobileObject`
constructor FUN_005591c0; only mobs switch to `roe_normalMA`, Z09 §5.3). While it is on, the code that tests the
rule set by address (`smo_SwingDamage` FUN_00432f30: attack type physical / magical for item actions; the heal-on-hit
abstate checks 0xC9 / 0xCA in `smo_AttackedDamage` FUN_0042aeb0) matches neither set *(effect not traced further)*.
Memory only.

```pseudo
&knockback   ac_KnockBack                                              @ FUN_00420350
    t = gm.so_CurrentTargetObject() (vt 0x75c); none: nothing
    e = dic_abstate.as_StateIndexList[STA_KNOCKBACK (346)]               # AbState row StaKnockBack, SubStaKnockBack
    gm.so_AbnormalState_Set(setter t, e.AbStataIndex, strength 1, e, now, 0, 0xFFFFFFFF, keep 1000, 5, 0)   (vt 0x638, Z03 §6.2)
    so_AbnormalState_BitSet(gm, idx)                                     # result of the set not checked
    e.subabstate[1]: gm.so_AbnormalState_Inform(idx, sub.KeepTime, 1) (0x2429); so_AbnormalState_BroadcastSet(gm, idx, sub.KeepTime, 1)
```

The knock-back state lands on **the GM**, with the target as the one who set it; `&setabstatetarget` (§4.4) does it
the other way round (state on the target, GM as setter). The GM is thrown back from the target instead of the
target from the GM (original bug) Z11-B22 *(intent inferred from the name and the target lookup)*.

```pseudo
&erasechargebuf   ac_EraseChargeBuff                                   @ FUN_0041f620
    ShinePlayer::sp_RemoveAllChargeBuff(gm)                              @ FUN_00418280
        for each active entry of gm.sp_ChargedItem.ci_List (List<ChargedItemEffectElement>, 12-byte entries):
            e.ciee_Index (ChargedItemEffect row) ≠ null: e.ciee_Year = 1     # end date → 2001
```

Nothing is removed directly: every charged buff gets an end date in the past and is dropped by the per-minute
expiry check (Z09 §2.4) *(inferred: the check compares the end date with now)*. No packet, no DB write here.

### 6.5 Map tools: `&showid`, `&pvp`, `&ghostremove`, `&partblock`, `&mobhatchery`

```pseudo
&showid   ac_ShowPlayerID                                              @ FUN_0041f4a0
    gm map or its FieldList row (map +0xc) missing: nothing
    row.NameHide (+0x6a) == 0: wall "fail to 'showid' : This instruction code is not used in condition which the
                                     FieldMap option - NameHide is activated."; return
        # i.e. it works only on maps that hide names (the text reads the other way round)
    gpp = 0x1C16 NC_BRIEFINFO_PLAYER_LIST_INFO_APPEAR_CMD { u8 nPlayerCnt = 0 }      (AxialListShowID ctor FUN_004281e0)
    so_AllOfRange(gm, allofrangearg, gm position, …, AxialListShowID)       # every object in the GM's view range
        AxialListShowID::ali_Work(gm, o)                                    @ FUN_00429170
            o is a player (vt 0x4d0 == 2) and so_SubLayer_CanSee(gm, o):
                PlayerInfo[n] = PROTO_NC_BRIEFINFO_PLAYER_INFO_APPEAR_CMD { u16 nHnd = o.handle, Name5 sID = o.so_CharName()
                    (vt 0x56c), CHARTITLE_BRIEFINFO CharTitle = o.so_GetCharacterTitle() (vt 0x420) +0x488 Type, +0x489
                    ElementNo, +0x48a MobID, u32 nGuildID = o.so_mobile_GetGuildRegnum() (vt 0x818) }      # 30 bytes
                n == 28: send 3 + 28·30 bytes to the GM (so_GetDataSocketStream vt 0x2f8), n = 0
    0 < n < 28: send 3 + n·30 bytes to the GM
```

The packet carries the names of the visible players to the GM only. The 2016 client has no handler for 0x1C16 (C01:
"a player, ignored by this client build"), so the command shows nothing (original bug) Z11-B23.

```pseudo
&pvp <1|other>   ac_SetPVP                                             @ FUN_00420230
    argnum ≠ 2: wall "usage: &SetPVP 1/0"; return                          # the word is &pvp
    gm map and its centre object (fm_GetCenterObject): v = ac_Scanf(args[0])
        map.fm_PKField (+0x54) = (u8) v                                     # the free-PvP flag (Z03 knowledge +0x54)
        so_AllInMap(centre, AxialListProtocolSend(6, v == 1 ? 0x12 : 0x13), 0)
            # every player of the map ← 0x1812 NC_MAP_FREEPKZONE_ON_CMD {} ("This area is enabled for PvP.") or
            # 0x1813 NC_MAP_FREEPKZONE_OFF_CMD {}
```

Same flag and packets as the Lua `cSetFreeBattle` and the script word `pk` (Z09 §17.6). Any value other than 1 is
announced as "off" but stored as it is: `&pvp 2` keeps a non-zero free-PvP flag while every client is told PvP is off
(original bug) Z11-B24 *(inferred: the readers test the flag as non-zero)*. Memory only; `fm_Init` clears it.

```pseudo
&ghostremove   ac_GhostRemove                                          @ FUN_0041fef0
    FieldMap::fm_ClearObject(gm map, 0x3b2)                               @ FUN_00495a10 (Z09 §24.8)
        so_AllInMap(map, AxialListObjectClear{0x3b2}, 1); ali_Work FUN_00495940: (0x3b2 >> o.so_ObjectType) & 1 →
            o.so_RetrateFromMap() (vt 0x3f4, removed next tick)
```

`0x3b2` = kinds 1 (dropped item *(inferred from `som_AllocObject` type 1, Z05)*), 4 NPC, 5 mob, 7 door, 8 bandit,
9 effect object: everything on the GM's map except players, mini-houses and magic fields (the clear mask the
instance and KQ code use is 0x3b0, the same without dropped items). NPCs and gates do not come back until the map
script respawns them *(inferred)*. A GM without a map dereferences null (GMs chat from a map).

```pseudo
&partblock <x> <y> <r>   ac_PartBlock                                  @ FUN_00420470
    gm without a map: nothing; r = ac_Scanf(args[2]); r > 100 or fopen("PartBlock.txt", "w") fails: nothing
    write "MoveBlock\n"; for dy = −r…r: for dx = −r…r: char(mbi_IsMoveBlock(map block info (map +0x14), x+dx, y+dy)); "\n"
    write "\n", "AttackBlock\n"; same grid with mbi_IsAttackBlock
    char = blocked ? (centre ? '@' : '*') : (centre ? ':' : '.')
    fclose
```

A text picture of the move-block and attack-block bits (Z09 §9.2: `.shbd` / `.shab`) around a world point, one
character per world unit (a block cell is 6.25 units wide, so cells repeat), into `PartBlock.txt` in the zone's working
directory (overwritten each time). A negative `r` writes only the two headers. Nothing goes to the GM.

```pseudo
&mobhatchery   ac_MobHatchery                                          @ FUN_0041f6c0
    MobHatchery::mh_View(mobhatchery, gm)                                 @ FUN_004b3a60 (Z09 §10.9)
        # one GM notice per regen group of the GM's map and per breeder (mob, spawns left, handle, next regen)
```

### 6.6 Information and logs: `&curtime`, `&amibusy`, `&invenview`, `&debuglogging`

```pseudo
&curtime   ac_CurTime                                                  @ FUN_0041ffb0
    t = mysecond()                                                         # FUN_00450360: time() + diffence2world (Z09 §1.2)
    d = chargeditemcheck.ct_Current (DAT_00aa43b8, ShineDateTime of the world clock)
    wall sprintf("%d.%d.%d %d:%d[%u]", (d & 0xff) + 2000, d >> 8 & 0x1f, d >> 13 & 0x3f, d >> 19 & 0x3f, d >> 25, t)
        # year.month.day hour:minute of the packed date, then the world time in seconds

&amibusy   ac_AmIBusy                                                  @ FUN_004200d0
    wall "TotalKQList : %d" (KQContributeList::kqcl_KQListNumber(&g_KQContributeList) FUN_00499bd0: entries of 0x14 bytes)
    h = gm map.fm_KQHandle (+0x3c)
    h == 0xFFFFFFFF: wall "No KQ"
    kqc_SearchHandle(&kqcontainer, h) (FUN_004954f0) none: wall "KQElement[%d] not found" (h)
    else wall "MyKill : %d" (KQContributeList::kqcl_GetMobKill(&g_KQContributeList, h, gm) FUN_00499d80: the GM's
        mob-kill count in that KQ's contribution list, 0 when not listed)

&invenview   ac_InventoryView                                          @ FUN_004206b0
    gm.so_ply_InvenWrite(null) (vt 0xa58)                                 @ FUN_0051ad90
        for each item of the inventory (ItemBoxIterItem): wall "     Inv %3d   %I64u   %.40s" (cell, item key, ItemInfo name)
        then for each equipped item:                   wall "     Equ %3d   %I64u   %.40s"
        # an item whose id has no ItemInfo row ends the whole listing; with an empty inventory the equipment part is
        # skipped too (it is inside the inventory branch) (original bug) Z11-B25

&debuglogging <BalanceLog|other> <0|1>   ac_DebugLogging               @ FUN_00420760
    v = (u8) ac_Scanf(args[1])
    args[0] == "BalanceLog": BalanceLog.dl_Activ = v;      wall "BalanceLog changed"
    else:                    DebugLogging::dl_ActivAll = v; wall "All of log changed"
```

`dl_ActivAll` is the master switch every `DebugLogging` file log tests before writing (`dl_FilePoint` FUN_004191b0 and
the write paths, §1.5), so `&debuglogging x 0` also stops `AmpersandCommandLog`: later commands of every GM are not
logged until someone sets it back to 1 or the zone restarts. `BalanceLog` is switched off at start-up (Z09 §1.1).

### 6.7 Dice: `&ts_DiceFix`, `&ts_DiceProbability`, `&GB_DiceFix`, `&GB_DiceProbability`

The TaiSai dice table exists in two forms (Z06): the one in a mini-house (`ShineMiniHouse.smh_DiceTaiSai`) and the
gamble-house machine (`CGambleDiceTaiSaiObject.G_DiceTaiSai`, Z06 §4.4). `ts_` works on the house the GM is in, `GB_` on
the machine the GM has targeted. The dice are three digits 1…6 typed together (`args[0][0..2]`, more characters are
ignored); the replies are Korean (CP949) GM notices, translated here.

```pseudo
dice(s) = for i in 0…2: d[i] = s[i] − '0'; any s[i] ∉ '1'…'6' → notice "Enter a value between 1 and 6." (1 ~ 6 사이의 값을 입력해 주세요.)

&ts_DiceFix <ddd>   ac_TaiSai_DiceFix                                  @ FUN_00420860
    argnum ≠ 2: notice "Enter the dice together, 111 ~ 666." (111 ~ 666 사이의 주사위를 붙여서 입력하세요.); return
    d = dice(args[0])
    no map: "No map information." (맵 정보가 없습니다.); not in a house (vt 0x130): "You are not in a mini house."
    h = som_GetObject(gm.so_ply_MH_GetMyHandle() (vt 0x138)); none: "Mini house information not found."
    !h.so_mh_SetDiceFix(d) (vt 0x1cc)                                     @ FUN_005117d0
        # so_mh_IsActiveDiceTaiSai (vt 0x214) and nGameStatus ∈ {DTGS_NONE_BETTING, DTGS_BETTING}:
        # bIsAdminDice = 1, CurrentRollingDice = d → the next roll shows these dice (Z06 §3.4)
        → "Dice setting failed." (주사위 셋팅에 실패 하였습니다.)

&ts_DiceProbability [<ddd> <weight>]   ac_TaiSai_DiceProbability        @ FUN_004209f0
    no map / not in a house / house not found: as above
    argnum 1: !h.so_mh_SetDiceProbability(null, 0) (vt 0x1d0)            @ FUN_00511830
        # reload all 216 weights nDiceRate[] and nDiceRateSum from gMiniHouseDiceRate (DiceRate table); fewer rows → false
        → "Dice probability reset failed." (주사위 확률 초기화에 실패 하였습니다.)
    argnum 3: d = dice(args[0]); w = (u16) atoi(args[1])
        !h.so_mh_SetDiceProbability(d, w): table active (vt 0x214) and DiceTaiSai::ConvertDice(d) → index i:
            nDiceRateSum += w − nDiceRate[i]; nDiceRate[i] = w
        → "Dice probability setting failed." (주사위 확률 셋팅에 실패 하였습니다.)
    other argnum: "Enter dice 111 ~ 666 and a probability 0 ~ 65535." (111 ~ 666 사이의 주사위, 0~65535 사이의 확률을 입력하세요.)

&GB_DiceFix <ddd>   ac_Gamble_TaiSai_DiceFix                           @ FUN_00420bb0
    no map: "No map information."; no target (vt 0x75c): "Use it after clicking the dice machine." (주사위 게임기를 클릭 한 후 사용하세요.)
    argnum ≠ 2: the 111 ~ 666 usage; d = dice(args[0])
    g = CGambleObjectManager::gom_GetGambleObject(&gGambleObjectManager, target.handle)   @ FUN_00615830 (machine by NPC handle)
    none: "Dice machine information not found." (주사위 게임기 정보를 찾을 수 없습니다.)
    !g.vt[0xa8](d) = CGambleDiceTaiSaiObject::GDTSO_SetDiceFix          @ FUN_0061b5d0   (status 0/1 as above, no active check)
        → "Dice setting failed."

&GB_DiceProbability [<ddd> <weight>]   ac_Gamble_TaiSai_DiceProbability   @ FUN_00420d30
    no map / no target / no machine: as above
    argnum 1: g.vt[0xac](null, 0) = GDTSO_SetDiceProbability              @ FUN_0061b6b0   (reload from gGBDiceRate)
        false → "Dice probability reset failed."
    argnum 3: d = dice(args[0]); GDTSO_SetDiceProbability(d, (u16) atoi(args[1])) → index i, sum and weight as above
        false → "Dice probability setting failed."
    other: the 111 ~ 666 / 0 ~ 65535 usage
```

All four change memory only: the weights stay until the next reset or zone restart, a fixed throw is used once.
The roll that reads `bIsAdminDice`, `nDiceRate` and `nDiceRateSum` is Z06 §3.4 / §4.4. A weight of 0 removes an outcome;
the probability of outcome i is `nDiceRate[i] / nDiceRateSum`. Nothing tells the players that the dice are fixed.

## 7. Commands, part 5 (handlers FUN_00420ef0 … FUN_00422a90)

### 7.1 Raid tests: `&makeraid`, `&outraid`

Both work on the zone's own copy of the parties and raids (`RaidSystem` over the zone party table `partycontainer`,
Z08 §1–§2). Real raids are made by the WM, which sends 0xB004 NC_RAID_ZONE_MAKE_CMD (Z08 §2); neither word tells the
WM or any client. Notice texts are Korean (CP949), translated here.

```pseudo
&makeraid   ac_makeraid                                                @ FUN_00420ef0
    partyNo = gm.so_PartyRegistNumber() (vt 0x550)
    raid = RaidTask::rt_CreateRaid(partyNo, parties = NULL)            @ FUN_005cde10 (Z08 §2)
        # NULL parties → RaidSystem::CreateRaidAndParty(&raid, partyNo, &err)   @ FUN_0063d760
        #   no party table: err 0x1EC1; partyNo 0xFFFF (GM not in a party): err 0x1E84 → NULL
        #   raidNo = index of the first free slot of the 500 m_RaidSlot (m_Raidnum == 0xFFFF); none free → NULL
        #   three empty parties for raid positions 1…3: CParty::CreateRaidParty FUN_006451d0 (first empty party
        #     slot < 4000, NumOfMember 0, isRaidTypeParty = true); one fails → delete the ones made, err 0x1E85, NULL
        #   Raid::InitRaid(slot, raidNo, {partyNo, p1, p2, p3})        @ FUN_0063d240
        #     m_Leader = looter = member 0 of the GM's party, m_NumOfMember = its size, the four parties isRaidTypeParty
        # this branch never calls so_SetRaid (vt 0xa88) on the members (the WM branch does, Z08 §2) (original bug) Z11-B26
    raid == NULL: wall "레이드 생성 실패" ("Raid creation failed"); return
    wall "레이드 전환 성공" ("Raid conversion succeeded")
    it = Raid::Begin(raid); ++it                                        # position {party 0, slot 1} (Raid::iterator::operator++ FUN_0063d080)
    Raid::SlotChangeMember(raid, charNo at it, party index 1, slot 0, &err)   @ FUN_0063dc10
        # the second member of the GM's party leaves it (CParty::MemberLeave) and joins raid party 1 (CParty::MemberJoin);
        # errors (result not checked): no member there (charNo −1) 0x1F48, target party missing 0x1F4A, slot < its
        # member count 0x1F4B, iterator without a member 0x1F41, join failed 0x1F46
    MapClusterManager::ClusterManager::cm_ChangeCategory(partyNo, CATEGORY_PARTY → raidNo, CATEGORY_RAID)   @ FUN_00485210
        # the party's instance dungeons now belong to the raid (as for 0xB004, Z08 §5.1)
```

The result is a raid that only this zone knows: the members' raid pointers stay NULL, so nothing that asks
`so_GetRaid` (raid loot, raid packets, `&outraid`) sees it, while the second member has left the GM's party in the
zone's table only. The WM keeps the old party; its next party or raid packet for these members refers to slots the
zone has changed, and the zone raid number (first free slot) can be one the WM later sends in 0xB004, which then fails
("Not Make Raid", Z08 §2) (original bug) Z11-B26.

```pseudo
&outraid   ac_outraid                                                  @ FUN_00421040
    raid = gm.so_GetRaid() (vt 0xa84; only set by the WM raid packets, Z08 §2); none: nothing
    if Raid::DeleteMember(raid, gm.charNo, &err)                       @ FUN_0063de00
            # the GM leaves its raid party in the zone table (CParty::MemberLeave); refused with 0x1F48 when the
            # charNo is not in the raid, 0x1E86 when the party is missing
        gm.so_SetRaid(NULL) (vt 0xa88); wall "레이트 탈퇴 성공" ("Raid leave succeeded"; 레이트 is a typo of 레이드)
    if raid.m_NumOfMember < 2:                                          # checked also when the delete failed
        for every raid member online in this zone (RaidTask::rt_GetRaidPlayer FUN_005ce6f0 → _GetRaidPlayer FUN_005ce000):
            p.so_SetRaid(NULL); p.so_SetParty(0xFFFF) (vt 0x574)
        Raid::Reset(raid, &err)                                         @ FUN_0063d970
            # every member leaves its party, the four parties are deleted (CParty::PartyDelete), the record is
            # cleared (raidNo, leader, sub-leaders −1, looting reset)
        wall "레이드 해체" ("Raid disbanded")
```

Only the zone's copy changes: the WM still lists the GM in the raid and keeps sending its raid packets (member lists,
moves) for a member the zone has removed; the GM's client still shows the raid (original bug) Z11-B27. The real way out
is the client's raid-leave request through the WM (W02).

### 7.2 Instance, link and tournament tests: `&PlayIns`, `&testlink`, `&gtieffect`

```pseudo
&PlayIns   ac_PlayInstanceDungeon                                      @ FUN_00421190
    name = gm.so_Field.fm_FieldOption → map name (the map's FieldOption row; for an instance its base map)
    info = fieldlist.fc_GetInstanceDungeonInfoByMapName(name, ILT_NORMAL); none (not an instance map): nothing
    inst = mapclustermanager.cm_FindEmptyByRegnum(name, regnum = gm.charNo, CATEGORY_PARTY, ILT_NORMAL)   @ FUN_00486290 (Z08 §5.1)
        # the key is the GM's character number under the PARTY category (original bug) Z11-B28
    inst ≠ NULL: Movie::CinemaComplex::cc_PlayFilm(inst.fm_Multiflex, info.ScriptName, empty token, inst.fm_MapID)
        # FUN_005089a0 (Z09 §27.2): start the instance's script on that free instance
    no message in any case; the GM is not moved to the instance
```

Unlike the gate's entry (0xA410, Z08 §5), the instance is not cleared (`fm_ClearObject`) and no mode row is set; the
film runs on an instance nobody is in until a player enters a dungeon with the same key.

```pseudo
&testlink   ac_TestLink                                                @ FUN_004217e0
    gpp = { opcode 0x7C06, char map[12] = "RouCos02" }                 # 0x7C06 is NC_PRISON_GET_REQ (original bug) Z11-B29
    ShinePlayer::sp_NC_MAP_MULTY_LINK_SELECT_REQ(gm, gpp, len 0x27, 0xFFFF)   @ FUN_0055b430 (Z01 §7.3)
        # the 0x181F handler: needs the last NPC the GM clicked to be near and to have a link entry to "RouCos02";
        # otherwise it answers 0x1820 NC_MAP_MULTY_LINK_SELECT_ACK with 0x2029 / 0x202B / 0x202C / 0x202D
        # (no client text, Z01-B4); with such an NPC the GM is linked to RouCos02 (smfm_Link, 0x2028)
```

The handler reads only the payload, so the wrong opcode in the buffer has no effect; the word is a fixed test of the
multi-link NPC menu.

```pseudo
&gtieffect [<GTIServer id>]   ac_GuildTournamentItemEffect             @ FUN_004218b0
    gts = gm.so_Field.fm_GetGuildTournamentSystem(); none (not a tournament map): nothing
    GuildTournamentSystem::CreateItemEffect(gts, from = NULL, gm, atoi(args[0]))   @ FUN_0047c1e0 (Z16)
        # only for a GM registered in the running tournament (IsPlayerRegister) whose guild is group A or B;
        # id 0 = roll one by the group's advantage (GTIGetRateTable::GetItemIDbyProbabilityCalculate);
        # GM ← 0x74F0 NC_GUILD_TOURNAMENT_ITEM_PICK_CMD { u16 id } (client: "Used %s"); then the GTIServer row's
        # action (flag multiplier, abstate, skill, mob breed …) on its targets
```

The GM gets the effect of a tournament item box as if it had picked one up. The box effects are Z16's.

### 7.3 Skills and level: `&alllearnskill`, `&levelup`

```pseudo
&alllearnskill   ac_AllLearnSKill                                      @ FUN_004212e0
    for each row s of skilldatabox (ActiveSkill):
        skip unless CharClassDataBox::ccdb_CheckClass(s.UseClass, gm class (so_CharacterClass vt 0x49c → vt 0x38))
        book = itemdatabox[s.InxName]                                  # the skill book has the skill's index name
        skip unless the book exists (its ItemInfo.ID must equal its index, else assert "ItemDataBox::operator [] :
            Invalid Item index") and book.DemandLv ≤ gm level (vt 0x4d8)
        skip if CharaterSkillList::csl_IsLearn(gm.sp_SkillList, s.ID)
        Character DB ← 0x4801 NC_SKILL_SKILLTEACH_REQ { u16 handle, u32 charNo, u32 chrregnum = charNo,
                                                       u16 skillid = s.ID, u8 ispassive = 0, u16 removeid = 0xFFFF }   (0x11 bytes)
    for each row s of passivedatabox (PassiveSkill):
        book = itemdatabox[s.InxName] as above (exists, DemandLv ≤ level)
        skip unless ccdb_CheckClass(book.UseClass, gm class)           # the passive's class comes from its book
        skip if bit s.ID of gm.sp_Passive.cpl_Passive is set (already known)
        Character DB ← 0x4801 { …, skillid = s.ID, ispassive = 1, removeid = 0xFFFF }
    # assert text on a failed length: "sp_NC_SKILL_PRODUCTFIELD_REQ Learn Skill  : Packet Too Long" (copied, never hit)
```

One 0x4801 per missing skill row, each answered by the DB as for `&learnskill` (§4.4, D04 §2, Z03 §9.3): every row is
stored in `tSkill` (persistent) and the zone adds it, sends 0x4804 NC_SKILL_SKILL_LEARNSUC_CMD (and for passives
0x4820 to the WM). Each skill level is its own ActiveSkill row with its own book, so every level whose book the GM's
level allows is taught *(inferred from the per-row loop)*. Skills without a book item in ItemInfo are never taught.
Unlike `&learnskill` the class and level are checked; the already-known test is done here, not by the DB, so a second
`&alllearnskill` while the first answers are still pending sends the same rows again (duplicates fail in the DB:
0x4803 → "Failed to learn the skill.").

```pseudo
&levelup [<n>]   ac_LevelUp                                            @ FUN_00421710
    n = (argnum == 2) ? atoi(args[0]) : 1
    repeat n times (n ≤ 0: never): gm.so_AmpersandCommand_LevelUp()   (vt 0xa9c)

ShinePlayer::so_AmpersandCommand_LevelUp(p)                            @ FUN_0042fa00
    p.level (sp_CharData.basedata.Level, u8) += 1                       # no level-limit test (original bug) Z11-B30
    p.so_allparametercalculate() (vt 0x57c); sp_HPChangeCheck(MaxHP); CurHP = so_MaxHP; CurSP = so_MaxSP   # full heal
    CCharacterTitleZone::CT_LevelUp(p.sp_CharacterTitle, level)        # level titles
    CAnnounceSystem::AnnounceSystem_LevelMax(gAnnounceSystem, charid, level)   # max-level announcement
    quest diary level hook (sp_QuestDiary vt +4, level)
    p ← 0x240C NC_BAT_LEVELUP_CMD { u8 level, u16 mobhandle = 0, CHAR_PARAMETER_DATA (so_fill_CHAR_PARAMETER_DATA vt 0x668) }   (0xED bytes)
    sight (so_AllOfRange, not p) ← 0x240D NC_BAT_SUMEONELEVELUP_CMD { u16 handle = p, u16 mobhandle = 0 }
    WholeSaver::ws_savelevel2worldmamager(p)                           # FUN_00453580 → WM 0x400E (Z01 §8)
    WM ← 0x1074 NC_CHAR_LEVEL_CHANGED_CMD { u16 wmHandle (vt 0x340), u32 charNo, u8 level }   (W01 §7.5)
    GameLog ← 0x041E NC_LOG_GAME_LEVEL_UP { u32 charNo, map[12], u32 x, u32 y, u8 level, u64 exp }
    WholeSaver::ws_save2DB(p, 1, 8)                                     # character save to the DB
    academy member with an academy (vt 0x858 / 0x85c):
        Character DB ← 0x986B NC_GUILD_ACADEMY_DB_ACADEMY_REWARD_REQ { u16 handle, u32 charNo, u32 charNo, u32 academyNo, u8 level }
    free = so_ply_TotalSkillEmpower (vt 0x6b8) − csl_EmpowerSummary(p.sp_SkillList)
    free > 0: p ← 0x4810 NC_SKILL_EMPOWPOINT_CMD { u8 restempow = free }
    sp_StatRemainSend(p) (stat points); vt 0x20(level); so_ply_SaveFame (vt 0x450); so_ply_ChangeFame (vt 0x44c)
    p.sp_NextSaveExp = sp_NextSaveExperience(p); brief info Level = level; vt 0xb18 (so_Gamble_ChangeExchangedCoin, PDB name of the slot)
```

This is the level-up block of `sp_GainExp` (Z03 §8.3, the same packets in the same order) with three differences: the
experience is not touched (it stays below the new level's threshold, so the next kill's EXP counts towards the level
after; the EXP bar the client draws starts from the old value *(inferred)*); the `levellimit` test of `sp_GainExp` is
missing; and `GMEventManager::GMEM_CheckAllConditionAndApply` (the GM-event check at the end of the normal level-up) is
not called. Everything is persistent: the level reaches the WM (0x1074, 0x400E) and the character save.

`&levelup 300` raises the level past `shineparam.scp_param.levellimit`; the u8 wraps to 0 after 255, and every later
`sp_GainExp` indexes the per-level EXP table (`scp_param.nextexp[level]`) beyond the limit *(effect inferred)* (original
bug) Z11-B30.

### 7.4 Items and money: `&getmoney`, `&iareset`, `&ebcu`, `&vanishdropitem`, `&mobitemdrop`

```pseudo
&getmoney <n>   ac_GetMoney                                            @ FUN_00421bf0
    argnum < 2 or atoi(args[0]) == 0: nothing
    gm.so_ply_PickupMoney((u32) atoi(args[0]))   (vt 0x790)            @ FUN_0052fe80

ShinePlayer::so_ply_PickupMoney(p, cen)                                # also the money branch of a normal pick-up (Z04 §3.3)
    p.Cen (sp_CharData.basedata.Cen, u64) += cen                        # cen is a u32: a negative n adds 2^32 − |n| (original bug) Z11-B31
    Character DB ← 0x3438 NC_ITEMDB_PICKMONEY_REQ { u16 handle, u32 charNo, u32 owner = charNo,
                                                    u64 itemonfield = 0xFFFFFFFF_FFFFFFFF, u32 cen }   (0x18 bytes)
    p ← 0x1033 NC_CHAR_CENCHANGE_CMD { u64 cen = p.Cen }  (so_ply_ChangeCen vt 0x448, Z05 §1)
    p.inventory lock list.SetDBPending(1)  (InventoryCellLockList vt 0x14, Z05 §1.2)   # inventory requests wait for the answer
```

The DB side (D03 §3.5): `p_Char_MoneyAdd(owner, cen)` adds the amount to `tCharacter` (persistent) and logs GameLog
0x0446 ("Need Cen", lot = (u16) cen); answer 0x3439 NC_ITEMDB_PICKMONEYSUC_ACK, or 0x343A … FAIL_ACK on error.
The zone treats the answers as the end of a pick-up (Z05 §3.2): success clears the DB-pending flag and calls
`so_ply_itempickresult`, which sends the GM 0x300A NC_ITEM_PICK_ACK with the item id and lot of the **last item the
GM picked up** (`p+0x29278` / `p+0x2927c`, not written here), so the client prints "[%s] has been obtained." for an
old item (or for item id 0 when nothing was picked since login *(inferred)*) (original bug) Z11-B32. Failure
disconnects the GM (reason 0x684) after the money was already added in memory.

`&getmoney` cannot take money away: the u32 is added with carry into the u64, so `&getmoney -1` adds 4 294 967 295
Cen (B31). There is no upper bound and no check of a money limit.

```pseudo
&iareset   ac_ItemActionCoolTimeReset                                  @ FUN_00421990
    m = gm.so_GetItemActionObserves() (vt 0x5d0); none: nothing
    ItemActionObserveManager::ResetCoolTime(m)                          @ FUN_005d1a00
        gm ← 0x482C NC_SKILL_ITEMACTIONCOOLTIME_CMD { u16 num, group[num] { u16 ItemActionID, u16 ItemActionGroupID,
                                                     u32 SecondCoolTime = 0 } }   (num·8 + 4 bytes; data socket vt 0x2f8)
            # one entry per element of iaom_CoolTimeList (0x1C-byte elements: ItemActionGroupID at +0x10, ItemActionID at +0x14)
        iaom_CoolTimeList cleared (vector end = begin)
        # assert text on a failed length: "GuildTourmentSystem::PlayerRegiste : Packet Too Long" (copied)
    wall "Item Action CoolTime Reset"
```

Client `On_NC_SKILL_ITEMACTIONCOOLTIME_CMD` FUN_0049c600: `Skill::SetLastCoolTimeByItemActionID(id, SecondCoolTime /
1000)` per entry, i.e. every item-action cool-down display ends. The list is memory only here; the next character save
writes the empty list (0x4023 NC_CHARSAVE_ITEMACTIONCOOLTIME_REQ, Z17) *(inferred)*. The item-action cool-downs
themselves are Z17's.

```pseudo
&ebcu <boundSlot> <cancelSlot>   ac_EquipBelongedCancelUse             @ FUN_00421b00
    pkt = { opcode 0x3048, u8 nCancelItemInvenSlot = ac_Scanf(args[1]), u8 nBelongedItemInvenSlot = ac_Scanf(args[0]) }
    ShinePlayer::sp_NC_ITEM_EQUIP_BELONGED_CANCEL_USE_REQ(gm, pkt, len 4, handle)   @ FUN_0051b9a0 (Z04 §12.6)
```

Runs the client request "use an unbinding item on a bound item" with all its checks (the cancel item is consumed,
DB 0x34A6, answer 0x3049 "Succesfully Unbound %s"); the word only saves the client UI. Persistent through the normal path.

```pseudo
&vanishdropitem   ac_VanishDropItem                                    @ FUN_00422800
    gm has no field: nothing
    so_AllInMap(gm, AxialListVanishDropItem, 0)                         # ctor FUN_004289f0, alvdi_VanishCount = 0
        AxialListVanishDropItem::ali_Work(o)                            @ FUN_00428a00
            o.so_ObjectType() == 1 (dropped item): alvdi_VanishCount += 1; o.so_RetrateFromMap() (vt 0x3f4)
            return 1 (walk every object)
    wall "vanish itme count - %d " (alvdi_VanishCount; read through the folded getter FUN_0045ff90)
```

Every item lying on the GM's map is removed (by its next routine, Z09 §25.1); kind 1 = dropped item is confirmed by
this walker. Nothing is saved: drops are memory objects.

`&mobitemdrop` (ac_MobItemDrop FUN_00421ba0) has an empty body: the word does nothing.

### 7.5 NPC tools: `&fnpc`, `&RegenNPC`, `&ReleaseNPC`

```pseudo
&fnpc <npcIndexName>   ac_FindNPC                                      @ FUN_00421cb0
    id = mobdatabox index of args[0] (MobInfo InxName); unknown / no row: wall "Invalid NPC IndexName"
    npc = ShineObjectManager::som_FindNPC(shineobjmanager, id)          # first NPC of that MobInfo id in this zone
    none: "Not Find NPC";  no field: "NPC Field Data Error";  no location: "NPC Coord Data Error"
    else wall "%s, %s, %d, %d" = MobInfo.Name (+0x22), npc map name, x, y
    # information only: the GM is not moved

&RegenNPC <npcIndexName> [<x> <y>]   ac_RegenNPC                       @ FUN_00421e50
    gm has no field: nothing;  args[0] not a MobInfo index: wall "Invalid NPC IndexName"
    x = atoi(args[1]), y = atoi(args[2]); a value < 1 → the GM's own x / y
    NPCManager::nm_DynamicRegenerateNPC(npcmanager, from = gm field, name = args[0] (32 bytes), map = gm field,
                                        x, y, dir = gm direction × 2)   @ FUN_004c6cd0 (Z09 §5.9)
        # needs a static NPC row (NPC.txt) with that MobName on the GM's map; spawns a dynamic copy with that
        # row's role at (x, y); every failure is only logged by the callee
    false: wall "NPC Regen Fail"

&ReleaseNPC   ac_ReleaseNPC                                            @ FUN_00421fc0
    t = gm.so_CurrentTargetObject() (vt 0x75c); none: wall "Invaild Target Object"
    t.so_ObjectType() ≠ 4 (NPC): wall "Not NPC"
    else t.so_RetrateFromMap() (vt 0x3f4, ShineMobileObject::so_RetrateFromMap FUN_00495d20: smo_Flag.Retrate)
        # the NPC's next routine removes it from the map (Z09 §25.1); no message
```

`&RegenNPC` direction: the GM's direction byte is in 2° units (Z09 §9), so ×2 gives degrees as in the NPC table
*(inferred)*. `&ReleaseNPC` also takes table NPCs off the map; they come back only with a zone restart or `&RegenNPC`
(as a dynamic copy) *(inferred from Z09 §5.9: static entries are never released or re-spawned)*. Both are memory only.

### 7.6 Character and movement: `&godmode`, `&setlp`, `&walkto`, `&castteleport`, `&setobjectdirect`, `&cmt`

```pseudo
&godmode   ac_GodMode                                                  @ FUN_00422350
    gm.smo_admindamage (+0x1e7c) = 1000000;      wall "StaticDamage 1mil true"     # as &staticdamage 1000000 (§5.3)
    ShinePlayer::sp_SetIgnoreCoolTime(gm, 1)  (FUN_00560220: sp_isIgnoreSkillCoolTime = 1)
                                                 wall "IgnoreSkillCoolTime true"   # as &ignoreskillcooltime (part 6)
    ShinePlayer::sp_SetTotalMoveSpeed(gm, 10000); wall "EditSpeed 10x true"        # as &speed 10000 (§6.4)
    sp_MiscFlag.InAdminImmortal = 1; sp_AdminFunction = sp_Immortal;  wall "Immortal Mode true"   # as &immortal (§5.3)
    gm.so_parameter().Item.Plus.MaxHP (Parameter::Container +0x158) = 10000000; sp_MaxHP(gm)
        so_recoverhp(10000000) (vt 0x5b4); so_mobile_NotifyParameterChange(1) (vt 0x34)   wall "MaxHP Plus 10mil true"
    …Item.Plus.MaxSP (+0x160) = 10000000; sp_MaxSP(gm); so_recoversp(10000000) (vt 0x5b8); vt 0x34(1)
                                                 wall "MaxSP Plus 10mil true"
    CurHP = so_MaxHP; CurSP = so_MaxSP
```

All memory only. The +10 000 000 HP / SP sit in the equipment bonus cluster (`Item.Plus`), which the next equipment
change recomputes, so they last until the GM changes gear *(inferred: the Item cluster is rebuilt from the equipped
items)*; damage, speed and immortality last until map login, reconnect or revive (§5.3). `&immortal` afterwards
toggles immortality off, `&staticdamage 0` the fixed damage; nothing undoes the cool-down flag except
`&ignoreskillcooltime` (part 6).

```pseudo
&setlp <n>   ac_Setlp                                                  @ FUN_00422330
    gm.sp_Sen_LP.nCurLP = ac_Scanf(args[0])                             # no MaxLP test, no packet; memory only

&walkto <x> <y>   ac_WalkTo                                            @ FUN_004228c0
    gm.so_mobile_MoveReserve(&{ ac_Scanf(args[0]), ac_Scanf(args[1]) }, speed 1000, kind 1 (walk), backwards 0)   (vt 0x660)
        # as &runto (§6.4) at walking speed; profiler label also "AmpersandCommand::ac_IgnoreSkillCoolTime"

&castteleport <x> <y>   ac_CastTeleport                                @ FUN_004229b0
    gm.so_mobile_Teleport(&{ ac_Scanf(args[0]), ac_Scanf(args[1]) })   (vt 0x6d4, FUN_0057d1d0, Z09 §9.3)
        # immediate jump on the same map: stop, set position, sight re-exchange (sp_ReSetSendMyBriefInfo), old
        # viewers told to drop the GM, move halt, vt 0xa4c (move-fail = position correction to the GM's client)
        # the command tests neither the target cell nor the map size

&setobjectdirect <dir> [<x>]   ac_SetObjectDirect                      @ FUN_00422a90
    dir = ac_Scanf(args[0]); includeSelf = 1
    if argnum == 2 (exactly one argument): includeSelf = (u8) ac_Scanf(args[1])   # args[1] is empty → 0 (original bug) Z11-B33
    *gm.so_LocateInfo.direct = dir (u8, 2° units)
    ShineObject::so_DirectInfoBroadcast(gm, includeSelf)                @ FUN_00553510 (Z09 §17.1)
        sight (and the GM when includeSelf) ← 0xBC1C NC_GAMBLE_ENTER_PLAYER_DIRECT_CMD { u16 nHandle, u8 nDirect }
```

`&setobjectdirect 90` turns the GM for the others but not on the GM's own screen; with any second word the GM's
client is told too (B33). The Lua `cSetObjectDirect` (Z09 §17.1) has the same broadcast.

```pseudo
&cmt <type> [<angleXZ> <angleY> <dist> [<x> <y>]]   ac_CameraMoveTest  @ FUN_004220c0
    gm has no field: nothing
    argnum < 2: wall "&cmt [Type:0~1] [AngleXZ:0~360] [AngleY:0~90] [Dist:0~] [x] [y]"; return
    type = atoi(args[0]); type > 1: wall "Invalid Camera Move Type", "1 : ON, 0 : OFF"; return
        # signed test: a negative type passes (original bug) Z11-B34
    field.fm_CameraState (+0x124) = type                               # CS_NONE 0 / CS_MOVING 1 (Z09 §19.4)
    type 0: wall "Camera Move OFF"; angles and dist 0; (x, y) = GM position
    type 1: argnum < 5: walls "Camera Moving Type Need Default Input", "[AngleXZ:0~360] [AngleY:0~90] [Dist:0~] "; return
            angleXZ = atoi(args[1]), angleY = atoi(args[2]), dist = atoi(args[3]) (all u16);
            argnum > 6: (x, y) = atoi(args[4]), atoi(args[5]), else the GM position
            walls "Camera Move ON", "aXZ:%d aY:%d D:%d x:%d y:%d"
    (negative type: no message, values as for 0)
    whole map (so_AllInMap, flag 1) ← 0x6C14 NC_SCENARIO_CAMERA_MOVE_CMD { u8 MoveType = type, SHINE_XY_TYPE ViewCoord = (x, y),
                                                                         u16 AngleXZ, u16 AngleY, u16 Dist }   (0x11 bytes)
```

The GM version of the Lua `cCameraMove` (Z09 §19.4) without its brief-info exchange around the camera point: with
`fm_CameraState` CS_MOVING the map's sight range becomes unlimited for later exchanges, but nobody is sent the objects
around the new camera point now *(inferred from Z09 §19.4)*. A negative type is stored as the map's camera state and
sent as MoveType 0x80…0xFF, which the client ignores (B34, the same test as Z09-B74). Memory only; the state stays
until the next `&cmt 0` or script camera move.

### 7.7 Chat ban and pets: `&releasechatban`, `&getpetinfo`, `&setpetinfo`

```pseudo
&releasechatban <charName>   ac_ReleaseChatBan                         @ FUN_00421a60
    WM ← 0x0866 NC_MISC_SPAMMER_RELEASE_CHAT_BAN_REQ { u32 nGMCharNo = gm.charNo, Name5 sSpammerName = strncpy(args[0], 20) }   (0x1A bytes)
        # assert text on a failed length: "WholeSaver::ws_save2worldmanager : Packet Too Long" (copied)
```

The WM (W04 §17.4, handler FUN_0042c3b0) checks the GM's own `CHARDATA.adminlevel` 50…100 (silently nothing otherwise,
although the zone word needs only level 50 of the zone's table, §1.4), sends Character DB 0x0868 (nChatBan = 0); the
answer 0x0869 clears the ban in the database (persistent), tells the target's zone (0x0865, which clears
`chatBlockUntil`, Z01 §9) and answers the GM 0x0867 NC_MISC_SPAMMER_RELEASE_CHAT_BAN_ACK { u16 nError } (client
FUN_004b35b0: "Backing out chatting block" on success). A 20-character name is sent without terminator (strncpy);
the WM compares at most 20 bytes *(inferred from Name5)*. The ban itself is set from the client (0x0861, W04), not
by a GM word (`&silence` does nothing, §5.6).

```pseudo
&getpetinfo   ac_PetSystemTest_GetTendency                             @ FUN_00422480
&setpetinfo <mind> <stress>   ac_PetSystemTest_SetTendency             @ FUN_00422590
    pet = gm.so_GetTargetObject() (vt 0xa04: sp_Target.to_Object); none: "Get/SetPetTendency : No Target"
    pet.so_ObjectType() ≠ 12 (pet): "… : Target is not Pet"
    m = ShinePet::spt_FindMaster(pet); none: "… : No Target's Master"; m not a player (kind 2): "… : Target's Master is not Player"
    get: wall "Target Info (PetNo : %d) (Mind : %.1lf) (Stress : %.1lf)" =
         m.sp_PetInfo.nRegNum, nMindMil / 1000, nStressMil / 1000     # the values live in the master's PetInfoPlayer
    set: mind = atoi(args[0]) outside gPetData.m_nMindMinValue…m_nMindMaxValue: "SetPetTendency : Mind Range Over ( %d ~ %d )"
         stress = atoi(args[1]) outside m_nStressMinValue…m_nStressMaxValue: "SetPetTendency : Stress Range Over ( %d ~ %d )"
         wall "Target Info From (PetNo …)" (old values)
         m.sp_PetInfo.nStressMil = stress × 1000; nMindMil = mind × 1000
         ShinePlayer::sp_Send_NC_PET_SET_TENDENCY_DB_REQ(m, mind, stress)   @ FUN_004d1040
             m has a handle and a pet (nRegNum ≠ −1):
             Character DB ← 0xD401 NC_PET_SET_TENDENCY_DB_REQ { u16 nMasterHandle, u32 nPetRegNum, u8 nPetMind, u8 nPetStress }
                 (10 bytes; both clamped again to the gPetData ranges)
         wall "Target Info To   (PetNo …)" (new values)
```

The target is any player's summoned pet; the change is persistent (D03 §13: `usp_Pet_setTendency`, no answer). No packet tells the
owner's client; it learns the new mind / stress with the next pet-state update *(inferred)*. The pet tendency rules
(mind / stress drift, `gPetData` from the pet tables) are Z13's.

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
| Z11-B14 | 0x1068 `zls_NC_CHAR_PLAYERSEARCH_RNG` FUN_0045b870 (`&pfind`) | another zone answers with the player's own map and position | a player in a mini-house elsewhere is reported (and the GM linked) at the house map, while the local path uses the house entrance (`so_LoginLocation`) | substitute the house entrance as `zrpb_Request` does |
| Z11-B15 | `&expbonus` FUN_0041e190 / FUN_005a9100 | writes `fm_FieldBonus.fb_Experience`, which no zone code reads | the EXP event does nothing (only `&itembonus` works) | apply `fb_Experience` in the EXP award (Z03) |
| Z11-B16 | `&expbonus` / `&itembonus` FUN_0041e190 / FUN_0041e2d0 | the usage says `[map]`, but the first word is only tested for 'A'/'a'; anything else means the GM's current map | a GM who names another map changes the one they stand on | look the named map up |
| Z11-B17 | `&silence` FUN_0041e090 → `so_ply_KeepFromChat` FUN_00549f60 | only sends "Success to silence" to the GM | the player is not silenced although the GM is told so | set the chat block (`+0x2aa54`, Z01 §9) |
| Z11-B18 | `&chargeditem` `sp_ChargedItemTest` FUN_00451360 | end time = `tm_min + 5` without carry | minutes 60…64 are stored in the buff's end time (how the expiry check treats them was not read) | normalise the time (add 300 s before `localtime`) |
| Z11-B19 | `&propose`, `&proposeres`, `&reserve`, `&enterready`, `&enter` FUN_0041e9d0 … FUN_0041ef10 | refuse in a mini-house with "fail to 'pfind' : not allowed to do 'pfind' in the MH" | the GM is told about the wrong command | own text per word |
| Z11-B20 | `&proposeres` FUN_0041eb30 | builds 0x2051 without writing `response_word[37]` | the proposer's 0x2052 carries whatever text the previous packet left in `gpp` | clear or copy a third argument |
| Z11-B21 | `&startGT` FUN_0041f850 | takes the guild numbers of the two players unchecked | a player without a guild gives guild 0; one name twice sets a guild against itself | require two different guilds |
| Z11-B22 | `&knockback` FUN_00420350 | sets STA_KNOCKBACK on the GM with the target as setter | the GM is knocked back instead of the target | `t.so_AbnormalState_Set(setter gm, …)` as `&setabstatetarget` *(inferred)* |
| Z11-B23 | `&showid` FUN_0041f4a0 | sends 0x1C16 NC_BRIEFINFO_PLAYER_LIST_INFO_APPEAR_CMD, which the 2016 client does not handle | the command shows nothing | a client handler, or GM notices |
| Z11-B24 | `&pvp` FUN_00420230 | stores any value in `fm_PKField` but announces "on" only for 1 | `&pvp 2` keeps the map's PvP flag set while clients are told it is off | store `v == 1` |
| Z11-B25 | `&invenview` `so_ply_InvenWrite` FUN_0051ad90 | the equipment loop is inside the inventory branch; an item without an ItemInfo row ends everything | empty inventory: equipped items are not listed; a bad item hides the rest | list both independently, skip bad rows |
| Z11-B26 | `&makeraid` FUN_00420ef0 → `rt_CreateRaid(partyNo, NULL)` FUN_005cde10 | builds a raid in the zone's copy only: no WM message, members' raid pointer (vt 0xa88) never set, second member moved to raid party 1 in the zone party table; raid number = first free local slot | the raid is invisible to every raid feature; the zone's party table differs from the WM's; a later WM 0xB004 with the same raid number fails | a test helper that asks the WM (or also links the members) |
| Z11-B27 | `&outraid` FUN_00421040 | `Raid::DeleteMember` / `Raid::Reset` on the zone copy only; the WM is not told | the WM still has the GM (or the dissolved raid) and keeps sending raid packets for slots the zone has emptied; clients still show the raid | send the raid-leave request to the WM |
| Z11-B28 | `&PlayIns` FUN_00421190 | claims the instance with key {CATEGORY_PARTY, GM charNo} | the film runs on an instance owned by "party number = GM charNo", which a real party with that number would then enter | key {CATEGORY_INDIVIDUAL, charNo} or the GM's party number *(intent inferred)* |
| Z11-B29 | `&testlink` FUN_004217e0 | writes opcode 0x7C06 (NC_PRISON_GET_REQ) into the buffer passed to the 0x181F handler | none (the handler reads only the payload) | 0x181F |
| Z11-B30 | `&levelup` `so_AmpersandCommand_LevelUp` FUN_0042fa00 | raises the u8 level without the `levellimit` test of `sp_GainExp` | levels above the server limit (wrapping to 0 after 255) are saved to the DB and the WM; later EXP gains index the per-level table past the limit *(inferred)* | stop at `scp_param.levellimit` |
| Z11-B31 | `&getmoney` FUN_00421bf0 / `so_ply_PickupMoney` FUN_0052fe80 | `atoi` result passed as u32 and added with carry | a negative amount adds 2^32 − \|n\| Cen; there is no way to remove money and no upper bound | refuse n < 1 (or a signed money change, `CenChange`) |
| Z11-B32 | `&getmoney` → 0x3439 handler FUN_00530510 | reuses the pick-up path: the DB answer runs `so_ply_itempickresult` with the last picked item (`p+0x29278` / `p+0x2927c`) | the GM's client prints "[old item] has been obtained." | a money path without the pick message (0x347A INC_DEC_MONEY, Z05 §3.3) |
| Z11-B33 | `&setobjectdirect` FUN_00422a90 | reads the include-self flag from `args[1]` when `argnum == 2` (one argument, `args[1]` empty) | with one argument the GM's own client is not told the new direction; with two it always is, whatever the second word | test `argnum == 3` |
| Z11-B34 | `&cmt` FUN_004220c0 | type test `> 1` on a signed `atoi` value | a negative type is stored as the map's camera state and sent as MoveType 0x80…0xFF (client ignores it) | `0 ≤ type ≤ 1` (same as Z09-B74) |

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
- `&deathaura` with the default `smo_admindamage` −1: what the map's range walker does with a negative radius was not
  read (assumed: nobody in range).
- `FieldMap.fm_Multiflex` first u16 as "no film running" for `mc_FindEmpty` (`&emptymap`) is inferred from the test only.
- The `so_AllInMap` flag (1 for `&mobdist`, 0 elsewhere) is passed through to the map's walker; its meaning was not read.

- §6.1 `&weddingreset`: what happens when the zone ring has a single zone (does `zcs_Send` loop back to itself?) was
  not read; with a broken ring the packet does not return and nothing is reset *(inferred)*.
- §6.4 `&allcritical`: the side effects of a rule set that is neither `roe_normalPY` nor `roe_normalMA` on the
  address tests in `smo_SwingDamage` / `smo_AttackedDamage` were not followed; `&runto`: whether the GM's client learns
  the server-side position (no packet is sent here) was not traced.
- §6.4 `&erasechargebuf`: the expiry of a buff whose end year was set to 1 is assumed from the per-minute check
  (Z09 §2.4); the iterator body was not re-read.
- §6.5 `&ghostremove`: object kind 1 = dropped item is inferred from `som_AllocObject(type 1)` (Z05); kind 9 = effect
  object from Z09's pool list.
- §7.1 `&makeraid`: `Raid::Begin` is assumed to start at {party 0, slot 0} (the iterator constructor was not read); what
  the WM does with the zone's changed party table when it next sends party packets was not followed (W02).
- §7.3 `&levelup`: the effect of a level above `levellimit` on the EXP table lookups and on the client was not traced;
  the vt 0x20 call with the level (slot name `so_GainFame` in the merged vtable) was not opened.
- §7.4 `&getmoney`: item id 0 in the 0x300A message when nothing was picked since login is assumed (the member's
  initial value was not read). `&iareset`: whether the next character save writes the cleared cool-down list was not read.
- §7.6 `&godmode`: how long the `Item.Plus` HP / SP bonus survives (recomputed on equipment change) is inferred;
  `&castteleport`: whether `so_MoveTo` refuses a blocked or off-map target was not read.
- §7.7 `&setpetinfo`: how the owner's client learns the new pet tendency was not traced (Z13).

(Parts 2–6 add their commands as §4–§8; the sweep part adds the coverage boundary.)
