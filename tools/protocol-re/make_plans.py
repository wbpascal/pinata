"""Generate docs/plan/items/<ID>.md (one self-contained plan per work item) from the definitions below.

usage: python3 -I tools/protocol-re/make_plans.py      (run from repo root after re-data/exports exist)
Scope tables are computed from re-data/exports/<bin>/handlers.json, so they list the exact handlers.
"""
import json, os, re

R = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
E = f"{R}/re-data/exports"
cat = {c["op"]: c for c in json.load(open(f"{R}/docs/protocol/opcodes.json"))}

DEPT = {2: "MISC", 3: "USER", 4: "CHAR", 5: "AVATAR", 6: "MAP", 7: "BRIEFINFO", 8: "ACT", 9: "BAT", 10: "OPTOOL",
        12: "ITEM", 13: "ITEMDB", 14: "PARTY", 15: "MENU", 16: "CHARSAVE", 17: "QUEST", 18: "SKILL", 19: "TRADE",
        20: "SOULSTONE", 21: "FRIEND", 22: "KQ", 23: "WT", 24: "CT", 25: "ANNOUNCE", 26: "BOOTH", 27: "SCENARIO",
        28: "CHAR_OPTION?", 29: "GUILD", 31: "ZONE?", 32: "DATA", 35: "MINIHOUSE", 36: "CHARGED", 37: "HOLY",
        38: "GUILD_ACADEMY", 40: "PROMOTION", 41: "INSTANCE", 42: "?", 43: "DICE", 44: "RAID", 45: "USER2",
        47: "GAMBLE", 49: "COLLECT", 51: "MOVER", 52: "EVENT", 53: "PET"}

ALL = None
# Shared first step of the DB items (D01-D05); details and the match table are in docs/plan/db-backups.md.
DB_STEP = ("**Database backups:** read `docs/plan/db-backups.md` first (which backup is which, which version to trust). "
           "Start with `python3 -I tools/protocol-re/bak.py cover <bin>`: it lists every procedure your server calls, the "
           "backups and `Fixes/` scripts that have it, and whether the parameter count matches. For every procedure you "
           "document, print its source (`bak.py Files/Server/2016/_Database/<file>.bak proc <name>`; compare the versions "
           "when several backups have it) and use it for the tables and columns touched, the result-set column order and "
           "the meaning of each return code (the Korean header comments list them). The backups come from private servers "
           "and are not the 2016 build: confirm against the binary (parameter count of the `{CALL …}` string, "
           "`SQLGetData` order and C types, result codes checked) and mark facts only a backup shows *(db-backup)*. Say "
           "which version you used, and flag procedures that exist only as private-server work. Name tables and columns "
           "only as the procedure source spells them.")
# (bin, parser substring, depts or ALL)
ITEMS = [
 dict(id="C01", phase=1, title="Client packet-handler inventory", out="docs/knowledge/C01.md + re-data/client-handlers.json",
      scope=[], deps=[],
      goal="Map every packet the 2016 client accepts: for each client scene/state (login, world/char select, in-game, …) "
           "find its dispatcher, list (opcode → client function), and describe briefly what the client does with each "
           "packet (fields read, UI text shown, state changed). This names most server→client opcodes and is the "
           "cross-reference every other item uses.",
      steps=["Start from the known login-scene dispatcher `FUN_0046f4d0` (switch on dept, cmd). Find sibling dispatchers "
             "with the same shape (callers of the same network-receive path, switches on `>> 10` / `& 0x3ff`, "
             "functions `FUN_004aaa40`, `FUN_00665920`, `FUN_00666ce0`, `FUN_00546270` are candidates for the game scene).",
             "Write `re-data/client-handlers.json`: `{\"0xOPCODE\": {\"scene\": …, \"func\": \"FUN_…\", \"summary\": …, "
             "\"fields\": [[off, type, name, note]], \"texts\": [text ids → strings]}}`.",
             "Use the 16 `On_NC_*` debug strings and client RTTI `ProtoStruct<PROTO_NC_…>` names to name opcodes "
             "(`grep -n 'NC_' re-data/exports/client/strings.tsv`).",
             "Resolve text ids with `tools/protocol-re/shn.py` on `TextData*.shn`, and error codes with `client-error-codes.json`.",
             "Extend `tools/protocol-re/catalog.py` (or add a small script) so names from `client-handlers.json` flow into "
             "`opcodes.json` with source `client`, then run `regen.sh`.",
             "Summarise per scene in `docs/knowledge/C01.md` (dispatcher address, opcode list, notable behaviour)."],
      done="Every client dispatcher found; ≥90 % of opcodes the zone/WM send to clients mapped to a client function; "
           "names fed back into the generated docs."),
 dict(id="C02", phase=1, title="2017 client PDB: official opcode names, packet structs, types, client function names",
      out="docs/knowledge/C02.md + docs/protocol/pdb-layouts.json + names/client/C02.json", scope=[], deps=["C01 (soft)"],
      goal="`Files/Client/2017/Fiesta.pdb` is the full private PDB of a slightly newer client (`patch_2017_08_p01`; GUID "
           "matches `Files/Client/2017/Fiesta.bin`). It holds the official protocol enums (`PROTOCOL_COMMAND` = dept, "
           "`PROTOCOL_COMMAND_<DEPT>` = cmd → 2600 opcode names), 2718 `PROTO_NC_*` packet structs with field names, "
           "offsets and sizes (538 of them DB/server-internal), shared types (`SHINE_ITEM_ATTRIBUTE` + 38 `ShineItemAttr_*`, "
           "`CHAR_PARAMETER_DATA`, `PROTO_AVATARINFORMATION`, enum `ABSTATEINDEX` (823 abstates), `ChrClassType`, 134 SHN "
           "row structs `<Table>::DataVersion`) and 30909 client function names. Turn it into evidence every item can use, "
           "without letting 2017 facts overwrite verified 2016 facts.",
      steps=["Reader: `python3 -I tools/protocol-re/pdb.py Files/Client/2017/Fiesta.pdb types|publics|json …` (stdlib, ~1 s). "
             "Opcode table = for each `NC_<X>` in enum `PROTOCOL_COMMAND`, the members of `PROTOCOL_COMMAND_<X>`; "
             "opcode = dept<<10 | cmd. 11 depts have no cmd enum (KQ, WT, CT, HOLY_PROMISE, AUCTION, …).",
             "Opcode names: feed them into `catalog.py` as name source `pdb2017`, ranked below `handler`/`client` and above "
             "`inferred(REQ+1)` and log literals. Measured against `opcodes.json` (2016 binaries): 1347 unnamed opcodes get a "
             "name, 933 agree, 110 conflict (51 `handler`, 41 `inferred(REQ+1)`, 18 log literals), 182 2016 opcodes are not in "
             "the 2017 enums, 210 2017 opcodes are not in the 2016 binaries. Conflicts are scattered, not a per-dept shift, so "
             "check each one in the 2016 code: several `handler` names come from one handler registered for two opcodes "
             "(e.g. zone `0x9884`/`0x9885` both named `…_DEPOSIT_RNG`), where the PDB name is the better one. Record the "
             "verdict per conflict in `docs/knowledge/C02.md`.",
             "Layouts: write `docs/protocol/pdb-layouts.json` (opcode → struct name, size, flattened fields "
             "`[offset, type, name]`, nested structs and arrays expanded one level) and make `packets.py`, `pcap_decode.py` and "
             "`make_dissector.py` use it as a source between hand annotations and generated `layouts.json` (label it "
             "`pdb2017`). Compare each struct size with the 2016 handler's length check / send size (`layouts.json`) and "
             "list mismatches (version drift) in the knowledge file. Server-internal packets about a player carry a 6-byte "
             "`ref` prefix that is **not** part of the PROTO struct (`docs/knowledge/Z01.md`): PDB offset = 2016 payload offset − 6.",
             "Hand annotations already made (L00 `annotations.json`, C01, W01, Z01): 96 of 112 with a PDB struct match the flattened PDB "
             "offsets; the rest are the `ref` prefix (W01/Z01 S2S packets), the 2-byte prefix in W01 `0x0c13`, `0x0C5A` "
             "(`sUserName` is 260 bytes, so our `unused` at 256 is the name's tail) and `0x0C66` (1-byte struct). Report per "
             "owning item; do not edit their files.",
             "Types catalogue in `docs/knowledge/C02.md`: which PDB types matter to which item (Z03 `ABSTATEINDEX`, Z04/Z05 "
             "`ShineItemAttr_*` and `SHINE_ITEM_STRUCT`, Z07 `CHAR_PARAMETER_DATA`, W01/D02 `PROTO_AVATARINFORMATION`, SHN "
             "row structs vs `shn.py` column names, enums such as `ITEM_LOOT_TYPE`, `PLAYER_QUEST_STATUS`, `GUILD_HISTORY_MSG_TYPE`). "
             "Point to the `pdb.py types REGEX` command instead of copying large dumps.",
             "Client function names: import `Files/Client/2017/Fiesta.bin` into `re-data/ghidra` as project `client2017` with "
             "the PDB applied (headless, PDB Universal analyzer, PDB next to the exe) and export it to "
             "`re-data/exports/client2017/` like the others. Port names to the 2016 client: first the `On_NC_*` handlers "
             "by opcode (same opcode → same handler in the scene dispatchers of both versions; 838 of C01's 901 handled opcodes "
             "have a 2017 name, 645 of them unnamed today), then callees and classes by call-graph / byte matching. Write "
             "`tools/protocol-re/names/client/C02.json`; mark ported names as `pdb2017` in the knowledge file.",
             "Evidence: a PDB fact applies to 2016 only after a 2016 binary agrees (same opcode in a handler table, same "
             "size check, same field use). Until then mark it *(pdb2017)* (see `CLAUDE.md` evidence levels)."],
      done="PDB opcode names in `opcodes.json` with conflicts resolved; `pdb-layouts.json` used by the generated docs, decoder "
           "and dissector; 2016 client handlers named from the PDB; per-item follow-up list in `docs/knowledge/C02.md`."),
 dict(id="W01", phase=1, title="World manager core: sessions, world login, characters, zone handoff",
      out="docs/pseudocode/wm/W01-core.md", deps=[],
      scope=[("wm", "CParserClient", [2, 3, 4, 5, 45]), ("wm", "CParserLogin", ALL), ("wm", "CParserAccountDB", ALL),
             ("wm", "CParserAccountLogDB", ALL), ("wm", "CParserGameLogDB", ALL), ("wm", "CParserOPTool", ALL),
             ("wm", "CParserCharDB", [2, 3, 4, 5, 40, 45]), ("wm", "CParserZone", [2, 3, 4, 6, 16, 25, 31, 51, 52])],
      goal="Reconstruct the WM process: startup/config, all link types (Login, Zone servers, AccountDB, AccountLogDB, CharDB, "
           "GameLogDB, OPTool), session lifecycle, world login (0x0C0F validate key), avatar list/create/delete/select, "
           "zone assignment and handoff (0x1003, 0x1036 to zone), map changes between zones, logout, kick (0x0C16 → 0x0C17), "
           "return-to-world-select token (0x0C35/0x0C36), character data relay between CharDB and zones.",
      steps=["Use `docs/pseudocode/login-server.md` §5.3 (Login↔WM messages) as the counterpart.",
             "Identify WM global objects (session managers, zone table, user/char registries) and name them in `names/wm/W01.json`.",
             "Character create (0x1401) and the 130-byte AVATAR struct: confirm fields with the client char-select scene."]),
 dict(id="Z01", phase=1, title="Zone core: process, maps, objects, player session, map login/logout",
      out="docs/pseudocode/zone/Z01-core.md", deps=[],
      scope=[("zone", "ShinePlayer", [2, 3, 6, 45]), ("zone", "WorldManagerSession", [2, 3, 6]), ("zone", "ZoneListenSession", ALL),
             ("zone", "OPToolSession", ALL), ("zone", "GameLogSession", ALL), ("zone", "GameDBSession", [2, 16])],
      goal="Reconstruct the zone process skeleton that all other zone items build on: startup, SHN data loading (list every "
           "table and its loader), map/field instances, object handles and the object class hierarchy (RTTI), the "
           "ShinePlayer lifecycle, the send/broadcast primitives (who receives a packet: self, sight range, map, party), "
           "map login (0x1801 → WM → DB → 0x1802), the login-complete burst (0x1803), map links (moving between maps/zones), "
           "logout and character save (CHARSAVE 16 to GameDB), zone↔zone links (ZoneListenSession).",
      steps=["List object classes from RTTI (`python3 tools/protocol-re/rtti.py Files/Server/2016/w00_Zone00/5ZoneServer2.exe`) and document "
             "the hierarchy in `docs/knowledge/Z01.md`. Other zone items depend on it.",
             "Document ShinePlayer member offsets you identify (position at this+0x66, handle at this+4, …) in `docs/knowledge/Z01.md`.",
             "Name the broadcast helpers (e.g. `FUN_00428a40`, `FUN_00434ae0`) in `names/zone/Z01.json`."]),
 dict(id="W02", phase=2, title="World manager: party and raid", out="docs/pseudocode/wm/W02-party-raid.md", deps=["W01"],
      scope=[("wm", "CParserClient", [14, 44]), ("wm", "CParserZone", [14]), ("wm", "CParserOPTool", [14])]),
 dict(id="W03", phase=2, title="World manager: guild and guild academy", out="docs/pseudocode/wm/W03-guild.md", deps=["W01"],
      scope=[("wm", "CParserClient", [29, 38]), ("wm", "CParserCharDB", [29, 38]), ("wm", "CParserZone", [29, 38])],
      steps=["Open from C01 (`docs/knowledge/C01.md` §5): `0x742a`, `0x982e`, `0x985e` are counted as client-bound only "
             "*(inferred)* (guild / academy member broadcast). Settle who actually receives each (client, zone, CharDB) and "
             "record it in `docs/knowledge/W03.md`.",
             "C01 found no client handler for `0x980a`, `0x982a`, `0x982b`, `0x982d` although the WM sends them to a client: "
             "document them as ignored by the 2016 client, not as missing.",
             "Client guild packets are handled in `GuildTask_OnPacket` FUN_006b7e70, a byte-table switch Ghidra did not "
             "decompile; use the case list in `re-data/client-handlers.json` (C01 §2), not the decompiled switch."]),
 dict(id="W04", phase=2, title="World manager: friends, chat routing, KQ, holy promise, instances, misc",
      out="docs/pseudocode/wm/W04-social-misc.md", deps=["W01"],
      scope=[("wm", "CParserClient", [8, 21, 22, 28, 31, 32, 37, 41, 42]),
             ("wm", "CParserCharDB", [21, 28, 31, 37, 41, 42]),
             ("wm", "CParserZone", [8, 9, 18, 21, 22, 24, 36, 37, 41, 47]),
             ("wm", "CParserOPTool", [8, 10, 37, 52]), ("wm", "CParserAccountLogDB", [32])],
      steps=["Open from C01 (`docs/knowledge/C01.md` §5): `0x083a` (13 bytes, sent by `FUN_00408050`, which sends to "
             "in-game clients and to a zone). Settle which send carries 0x083a and who receives it; the client has no handler "
             "for it.",
             "Open from C01: `0x7c07`. Its catalog name NC_PRISON_ADD_GM_ACK † is borrowed from the log string of the "
             "`0x7c0f` handler `FUN_0040c350` and is probably wrong. 0x7c07 is sent by `FUN_00415530` (the `0x7c06` "
             "handler) and by `FUN_0040c350`. The client reads it in the character-select scene as {u16 code, u16 value} "
             "(code 0xDB0 → keeps the value, `FUN_00475fb0`). Give it a layout and a meaning, and a name only if a string "
             "supports one.",
             "C01 found no client handler for `0x5802`, `0x7038`, `0x703a`, `0xa415` although the WM sends them to a "
             "client: document them as ignored by the 2016 client, not as missing."]),
 dict(id="Z02", phase=2, title="Zone: movement, chat, emotes, sight/briefinfo, NPC menus, scenario",
      out="docs/pseudocode/zone/Z02-actions.md", deps=["Z01"],
      scope=[("zone", "ShinePlayer", [7, 8, 15, 27]), ("zone", "WorldManagerSession", [8])],
      goal="Movement validation and broadcast, speed, collision/map checks, chat types (normal, shout, whisper path to WM), "
           "emotes, object appear/disappear (BRIEFINFO: what other players see), NPC click/menu flow, scenario/cutscenes."),
 dict(id="Z03", phase=2, title="Zone: combat, skills, abstates, damage", out="docs/pseudocode/zone/Z03-combat.md", deps=["Z01"],
      scope=[("zone", "ShinePlayer", [9, 18]), ("zone", "GameDBSession", [18])],
      goal="Attack flow (basic attack, skill cast/bash, cast abort), target validation, hit/miss/crit/block, damage formulas "
           "(use SHN tables ActiveSkill, PassiveSkill, DamageLvGapEVP, WeaponAttrib…), abstates (buffs/debuffs, AbState.shn, "
           "SubAbState.shn), death, experience and level-up, PvP rules."),
 dict(id="Z04", phase=2, title="Zone: items, inventory, equipment, upgrades (client side)",
      out="docs/pseudocode/zone/Z04-items.md", deps=["Z01"], scope=[("zone", "ShinePlayer", [12, 20])],
      goal="Inventory model (bags, slots, stacking), equip/unequip, use item, drop/pickup, enchant/upgrade/sockets, "
           "dismantle, soul stones, item info packets. Use ItemInfo/ItemInfoServer/ItemUpgrade/RandomOption SHN tables."),
 dict(id="Z05", phase=2, title="Zone: item database protocol (ITEMDB, zone↔Character server)",
      out="docs/pseudocode/zone/Z05-itemdb.md", deps=["Z04"], scope=[("zone", "GameDBSession", [13])],
      goal="The 108 ITEMDB replies: how item changes are persisted and confirmed, item creation (item keys), "
           "consistency/rollback behaviour. Pair each with the request the zone sends and the client-facing result."),
 dict(id="Z06", phase=2, title="Zone: trade, booths, gambling, dice", out="docs/pseudocode/zone/Z06-economy.md", deps=["Z04"],
      scope=[("zone", "ShinePlayer", [19, 26, 43, 47]), ("zone", "GameDBSession", [43, 47]), ("zone", "WorldManagerSession", [47])]),
 dict(id="Z07", phase=2, title="Zone: character stats, progression, pets, mounts, mini-house, collection cards",
      out="docs/pseudocode/zone/Z07-character.md", deps=["Z01"],
      scope=[("zone", "ShinePlayer", [4, 35, 49, 51, 53]), ("zone", "GameDBSession", [4, 35, 49, 53]),
             ("zone", "WorldManagerSession", [4, 51, 53])],
      goal="Stat model (base/derived, the stat pairs in 0x1802), stat points, level/exp tables, revive, titles, "
           "pets (PET), mounts (MOVER), mini-house, collection cards."),
 dict(id="Z08", phase=2, title="Zone: quests, kingdom quests, instances, guild/party/friend zone side, holy promise",
      out="docs/pseudocode/zone/Z08-content.md", deps=["Z01"],
      scope=[("zone", "ShinePlayer", [14, 17, 21, 22, 23, 24, 29, 37, 38, 41]),
             ("zone", "GameDBSession", [17, 22, 23, 29, 36, 37, 38]),
             ("zone", "WorldManagerSession", [14, 17, 22, 24, 29, 31, 37, 38, 41, 44, 52])]),
 dict(id="Z09", phase=2, title="Zone: world simulation (mobs, NPCs, AI, spawns, drops, scripts, timers)",
      out="docs/pseudocode/zone/Z09-world.md", deps=["Z01", "Z03"], scope=[],
      goal="Everything not driven by a client packet: mob spawning (MobRegen/MobSetting data), AI and behaviours "
           "(MobBehaviorDescript), aggro, movement, drops (MobInfoServer, ItemDrop tables), NPC objects, Lua scripts "
           "(9Data/Shine/LuaScript), map events, the main tick and timers.",
      steps=["Find subsystems via class names (RTTI) and profiler strings (`grep -n '::' re-data/exports/zone/strings.tsv`).",
             "Start from the main loop / tick functions found in Z01's knowledge file."]),
 dict(id="Z10", phase=2, title="Zone: certification and the downloaded start script",
      out="docs/pseudocode/zone/Z10-certification.md", deps=["Z01"], scope=[],
      goal="The zone does not start on its own: it downloads an encrypted Lua script from a certification server "
           "(127.0.0.1:58492, fallback cert1.fo.gamigo:80), decrypts it with registry keys HKLM\\SOFTWARE\\GBO "
           "`Natural`/`Desert` and runs it; the script calls the registered `zs_service_*` / `zs_start_*` stages "
           "(Z01-core §2). Only the zone uses this (no other server binary has these strings). The script itself is "
           "not recoverable. Reconstruct the mechanism around it and infer what the script must do, so a rebuilt "
           "server knows which stage order and which values to use, and whether the certification can stop the server.",
      steps=["Read `docs/pseudocode/zone/Z01-core.md` §2 and `docs/knowledge/Z01.md` §1/§7 first. The stage functions and "
             "several entry points are not in `decomp.c`; decompile them against the persistent Ghidra project with a "
             "headless script (`analyzeHeadless re-data/ghidra zone -process -noanalysis -readOnly`, `createFunction` + "
             "`DecompInterface`), as Z01 did.",
             "Request/response: `FetchStartScript` FUN_005b07a0 and its callees FUN_00613440 (request build/send), "
             "FUN_00613750 (key setup from the two registry int64s), FUN_00613950 (decrypt), FUN_005d6d40 (Lua dostring). "
             "Document the wire format, what the request carries (world/zone numbers, version?), the `[a][b]` header "
             "checks (1 ≤ a ≤ 0x2760, b < 11) and the cipher as pseudocode with test vectors if possible.",
             "Threads: `zs_service_certification` (thread FUN_005ab9c0) and `zs_service_stackchecker` (thread "
             "FUN_005a9f10). What do they check, how often, against what, and what happens on failure (log, shutdown, "
             "silent misbehaviour)? Look for time/expiry checks (`dhsmfskfWk` date helper, DAT_00aa43b8).",
             "The Lua surface: list every C function the script can call (FUN_005d7ca0 and any other `lua_setglobal` "
             "registrations), with arguments and effects. In particular the run/walk factors (`ekfflrlthreh` / "
             "`rjerlthreh` → 0x203E move speed) and any writer of the 0x0830 server parameters (DAT_0da5047c / "
             "DAT_0da50480). Check whether the script can read or set other globals.",
             "Infer the stage order from data dependencies between the stages (e.g. Field.txt before NPCs, packet "
             "tables before listeners, `zs_start_open` last) and from the Message.txt labels. Give one recommended order "
             "with the reason for each constraint, marked *(inferred)*.",
             "Diff with the 2015 zone (`Files/Server/2015/w00_Zone00`) only to see whether the mechanism changed; do "
             "not document 2015 otherwise.",
             "If a capture of a live zone start ever appears in `re-data/captures/`, it overrides inference.",
             "End with a recommendation for a rebuild: which values to hard-code, what to leave out."],
      done="Request/response and cipher documented; both threads explained with their failure behaviour; Lua surface "
           "listed; a recommended stage order with reasons; rebuild recommendation written."),
 dict(id="D01", phase=2, title="Account and AccountLog servers", out="docs/pseudocode/db/D01-account.md", deps=[],
      scope=[("account", "", ALL), ("accountlog", "", ALL)],
      goal="Every request, the SQL/stored procedure it calls (strings like `{CALL usp_…(?,?)}`), parameters/columns, "
           "and the reply. **Resolve the open question from the Login docs:** which conditions produce result -1/-2, "
           "the blocked flag (0x47), the flag behind 0x48, and AccountLog's region flag (0x51).",
      steps=[DB_STEP,
             "Account server: `Account.bak` has 7 of its 15 procedures. Start the Login open question from "
             "`usp_User_loginGame` (6 parameters, matches the binary): it returns `@userNo` (-1 when ID/password are wrong "
             "or the account is deleted), `@authID`, `@block` (re-checked through `usp_User_chkBlock`) and `@isLoginable` "
             "(group policy, `tUserAuth.bIsLoginAble`), which are likely the sources of the 0x47/0x48 flags *(db-backup)*; "
             "confirm in the binary. The binary also calls `usp_User_LoginGame` with 5 parameters; SQL Server names are not "
             "case-sensitive, so against this DB that call would fail: find which code path uses it. Missing: "
             "`usp_User_LoginNetmarble`, `usp_JPUser_insert`, `usp_TWUser_insert`, `usp_Pcbang_chkIP`, `usp_Event_addCash`, "
             "`p_UserKey_Get_FromAccount`, `p_UserPlayRemainTime_Get_FromAccount`, `p_UserPlayRemainTime_Set_FromAccount`.",
             "AccountLog server: `AccountLog.bak` and `StatisticsData.bak` (ODBC `Statistics`) have 8 of its 12 procedures, "
             "all with the same parameter count. `Fixes/IP Block/p_IPBlock_IsBlock.sql` is a private-server edit; the "
             "`AccountLog.bak` copy is the one to use. Missing: `p_Event_L20_Get`, `p_Event_L20_Set`, "
             "`p_SameTimeCharClass_Add`, `usp_AccountLog_GetDateDiffLastlogout`. `OperatorTool.bak` belongs to the separate "
             "operator tool, not to these servers."]),
 dict(id="D02", phase=2, title="Character server: characters, avatars, save/load", out="docs/pseudocode/db/D02-character.md",
      deps=[], scope=[("character", "", [2, 3, 4, 5, 10, 16, 40, 45])],
      goal="Character/avatar create/delete/list, full character load (NC_CHAR_CHARDATA) and save (CHARSAVE). "
           "Document each stored procedure and the column order (SQLGetData C types: -28 u8, -17 i16, -16 i32, -18 u32, 11 timestamp, 1 string). "
           "The 130-byte AVATAR record builder `FUN_0046bff0` is already decoded (annotations.json).",
      steps=[DB_STEP,
             "Character server: `Character.bak` (older, 2008 R2) and `w00_Character.bak` (newer, 2017, private-server fixes "
             "applied) together have 296 of the 311 procedures it calls, 294 with the same parameter count. In your area: "
             "`usp_CharacterLoading` takes 11 parameters in the binary but 6 in both backups; missing are "
             "`usp_CharacterLoadingDetailInfo`, `p_Promotion_Get`, `p_Promotion_Set`, `p_IsPromotionUser`. Key map, game "
             "option, shortcut, chat colour, tutorial and attendance procedures exist only in `w00_Character`. `Fixes/` "
             "changed `p_Char_Create` (duplicate names), `p_Char_Rename`, `usp_Character_setChangeID` and "
             "`usp_Tutorial_setCharInfo`: use the `Character.bak` copy or note the difference.",
             "Write the table list you meet (table → columns as the procedures use them) into `docs/knowledge/D02.md`; "
             "D03 and D04 build on it."]),
 dict(id="D03", phase=2, title="Character server: items (ITEMDB), economy, pets, house", out="docs/pseudocode/db/D03-character-items.md",
      deps=["D02"], scope=[("character", "", [13, 35, 36, 43, 47, 49, 53])],
      steps=[DB_STEP,
             "Missing in every backup: pets (`usp_Pet_*`, 5), `usp_LinkScroll_SetDestMap`, "
             "`p_Item_MiniHouse_Effect_Resource_Del`, `p_MiniHouseURL_Get`, `p_MiniHouseURL_Set`. Gamble/slot machine, card "
             "collection, safe trade, auto-mon and belonged items exist only in `w00_Character`. The gem enchant procedures "
             "(`usp_Item_*Enchant*`, author `<KHRISMIZER>`) may be private-server work. `p_Item_BuyAll` and `p_Item_BuyLot` "
             "match the binary only in `w00_Character` (the older copy has one parameter fewer). `Fixes/` changed "
             "`usp_ChargeItem_Draw` and `usp_ChargeItem_GetList` (premium inventory slots): compare with `Character.bak`."]),
 dict(id="D04", phase=2, title="Character server: social, guild, quests, skills", out="docs/pseudocode/db/D04-character-social.md",
      deps=["D02"], scope=[("character", "", [17, 18, 21, 22, 23, 24, 28, 29, 31, 37, 38, 42])],
      steps=[DB_STEP,
             "The two Character backups cover almost all of your scope. Missing in every backup: `p_Guild_SetMoney`, "
             "`usp_GuildTournament_setRefundNotice`. Private-server reconstructions, not original: `usp_GuildEmblem_*` (3) "
             "and `usp_GuildAcademy_setHistory` (header copied from `usp_Guild_SetToken`; `usp_GuildEmblem_SetInfo` has a parameter named `@nUnk`), and "
             "`usp_Guild_getHistoryList` / `usp_Guild_setHistory` (only in `Fixes/`). `usp_Character_setFriendpoint` takes 2 "
             "parameters in the binary but 3 in `w00_Character`."]),
 dict(id="D05", phase=2, title="GameLog server", out="docs/pseudocode/db/D05-gamelog.md", deps=[], scope=[("gamelog", "", ALL)],
      goal="What is logged (all ~200 log messages), table/procedure per message. Can be summarised in tables rather than "
           "full pseudocode where handlers are uniform.",
      steps=[DB_STEP,
             "`GameLog.bak` (older) and `w00_GameLog.bak` (newer) match well: 22 of the 23 procedures the GameLog server "
             "calls have source with the same parameter count; only `usp_Login_setChannel` is missing, and "
             "`p_GameLog_Add_TypeL` exists only in `w00_GameLog`. The `p_GameLog_Add_Type1…L` sources show which "
             "`tGameLog` column each parameter fills, which gives the meaning of the generic log fields. Eight of them "
             "differ between the two backups (Type1, 4, 5, 6, D, E, H, J): compare both."]),
 dict(id="P01", phase=1, title="Packet capture decoder", out="tools/protocol-re/pcap_decode.py + docs/knowledge/P01.md",
      scope=[], deps=[],
      goal="A pure-Python (stdlib only: no scapy/dpkt/tshark on this machine) tool that turns a capture of real "
           "client↔server traffic into a decoded, annotated packet log, and checks it against our documentation. "
           "It must work before any capture exists: test it on synthetic captures it generates itself.",
      steps=["Captures are recorded with Wireshark on the (Windows) PC running the game and copied here. tshark is NOT available on "
             "this machine, so parse the files directly.",
             "Input: `.pcapng` (primary, Wireshark default) and `.pcap`; link types Ethernet, Npcap loopback (DLT_NULL/LOOP) and raw IP; IPv4 TCP. "
             "Read pcapng **packet comments** (EPB `opt_comment`) and show them in the decoded log as markers. P02 uses them to tie "
             "packets to the user's actions. Reassemble each TCP "
             "stream by sequence number (handle retransmits and out-of-order data, report gaps).",
             "Classify streams by server port from `Files/Server/2016/9Data/ServerInfo/ServerInfo.txt` (type-20 client ports: Login 9010, "
             "WM 9110, zones 9210/9212/9214/9216). Make the port map overridable on the command line (a live server may use other ports).",
             "De-frame per `docs/protocol/README.md` §1.1. Decrypt client→server bodies with the XOR-499 table (Appendix A) starting at "
             "`seed % 499` from the stream's first server→client `0x0807`. The index runs on across packets. If the seed was not "
             "captured, brute-force the start index (499 candidates) by checking that decrypted opcodes are known.",
             "Decode each packet using `docs/protocol/opcodes.json` (name), `annotations.json` + `annotations/*.json` (verified "
             "fields, preferred), and `re-data/exports/<bin>/layouts.json` (generated fields, marked as such). Unknown regions → hex.",
             "Validation report per packet type: count, observed payload sizes vs documented size, fields whose observed "
             "values contradict documented constants or ranges, opcodes never documented, documented C→S checks violated "
             "(e.g. length checks), and bytes the docs leave undocumented that are not always zero.",
             "Outputs: `<capture>.decoded.txt` (time, direction, server, opcode, name, fields), `<capture>.report.md`, and "
             "`<capture>.json` (machine-readable for P02). Mask the password field of `0x0C5A` by default (`--show-secrets` to keep it).",
             "Self-test: `pcap_decode.py --selftest` builds a synthetic pcap (seed, encrypted 0x0C65/0x0C5A, server 0x0C0A, "
             "a long-form packet ≥256 bytes, a TCP segment split across two frames) and asserts that decoding round-trips.",
             "Document usage and limits in `docs/knowledge/P01.md` and add a short section to `docs/protocol/README.md`."],
      done="`--selftest` passes; decoding a synthetic capture yields correct opcodes, decrypted payloads and a report; "
           "usage documented."),
 dict(id="P02", phase=2, title="Capture validation (run once per batch of captures)", out="docs/protocol/capture-validation.md",
      scope=[], deps=["P01", "captures in re-data/captures/"],
      goal="Use real captures to confirm or correct the documented packet layouts, value ranges, error codes and message "
           "order. Re-run this item whenever new captures are added or a phase of items finishes.",
      steps=["Run `tools/protocol-re/pcap_decode.py` on every capture in `re-data/captures/` that has not yet been processed "
             "(keep a list in `docs/plan/status/P02.md`). Use the packet comments inside each capture (shown as markers by the decoder) and the scenario notes next to it (see "
             "`docs/plan/capture-guide.md`).",
             "For each opcode seen: compare with annotations and generated layouts. Confirmed fields → add `\"evidence\": "
             "\"capture:<file>\"` to the field note in `docs/protocol/annotations/P02.json`. Name fields from what changes "
             "between scenarios (e.g. level, coordinates, item ids against the SHN tables).",
             "Message order: check the sequences in `docs/protocol/README.md` §2 and the pseudocode (e.g. login burst after 0x1803) "
             "against the captured order. Record differences.",
             "Write `docs/protocol/capture-validation.md`: per opcode the status (confirmed / corrected / contradicted / never seen), "
             "and a list of discrepancies addressed to the owning work item (look up the opcode in `docs/plan/items/*.md`).",
             "Do not edit other items' pseudocode. Report contradictions in `capture-validation.md` and in `docs/knowledge/P02.md`."],
      done="All captures processed; every observed opcode has a status; discrepancies listed per work item."),
 dict(id="P03", phase=1, title="Wireshark dissector (Lua plugin, generated from the docs)",
      out="tools/protocol-re/make_dissector.py → tools/wireshark/fiesta.lua + docs/knowledge/P03.md", scope=[], deps=["P01 (soft: its synthetic capture is a handy test file)"],
      goal="Let the user see decrypted, named, field-decoded Fiesta packets live in Wireshark on the PC that runs the game, "
           "so they can comment packets accurately while recording. The plugin is generated from our docs and rebuilt by "
           "`regen.sh`, so it improves as other items add names and layouts.",
      steps=["Wireshark is not installed on this machine; the user installs the plugin on the capture PC (Windows): copy `fiesta.lua` "
             "to `%APPDATA%\\Wireshark\\plugins\\` (or the global plugins folder) and restart Wireshark / Ctrl+Shift+L. Document this.",
             "Register on the type-20 client ports from `Files/Server/2016/9Data/ServerInfo/ServerInfo.txt` (9010, 9110, 9210/9212/9214/9216) and "
             "expose the port list as a protocol preference.",
             "Framing via `dissect_tcp_pdus` (handles TCP segmentation): length = 1-byte form, or 0x00 + u16 long form "
             "(`docs/protocol/README.md` §1.1). One Fiesta packet per subtree; several per TCP segment.",
             "Decryption of client→server bodies: XOR-499 table (README Appendix A), start index = `seed % 499` from the server's "
             "`0x0807` on the same conversation, advancing across packets. Wireshark re-dissects packets in any order, so compute "
             "the index **once** on the first pass (`not pinfo.visited`) and cache it per frame + PDU offset (and the running index "
             "per conversation). Show both raw and decrypted bytes (new data source tab).",
             "Opcode → name from `docs/protocol/opcodes.json` (dept/cmd shown too); fields from `annotations.json` + "
             "`annotations/*.json` (verified, preferred) and `re-data/exports/<bin>/layouts.json` (generated, labelled \"guess\"). "
             "Field types u8/u16/u32/i16/i32/char[n]/bytes; structs like AVATAR/WORLD as repeated subtrees with count fields.",
             "Expert info for: unknown opcode, payload shorter/longer than documented, packet before seed (cannot decrypt).",
             "Mask the `0x0C5A` password field by default (preference to show it).",
             "Make `make_dissector.py` part of `tools/protocol-re/regen.sh`.",
             "Testing without Wireshark here: keep framing/decrypt logic in pure Lua functions and test them with a standalone `lua` "
             "interpreter if one is installed (`which lua`). Otherwise port the same test vectors from P01's self-test into a Python "
             "check of the generated tables. Ask the user to confirm the plugin on their PC with P01's synthetic capture and a real one."],
      done="`fiesta.lua` generated by `regen.sh`; decryption and framing logic tested; installation and usage documented in "
           "`docs/plan/capture-guide.md` (section \"Live decoding in Wireshark\") and `docs/knowledge/P03.md`."),
 dict(id="X01", phase=3, title="Integration and review", out="docs/pseudocode/README.md", deps=["all"], scope=[],
      goal="Read all item outputs, fix contradictions, write the architecture overview (processes, links, data flow), "
           "a cross-server sequence index (feature → messages → handlers in each server), a glossary, and regenerate all docs. "
           "List remaining gaps."),
]


def entries(bin_, parser, depts):
    H = json.load(open(f"{E}/{bin_}/handlers.json"))
    src = open(f"{E}/{bin_}/decomp.c", encoding="utf-8", errors="replace").read()
    sizes = {m.group(1): m.group(2).count("\n") for m in
             re.finditer(r"^//==== FUNC ([0-9a-f]{8}) \S+\n(.*?)(?=^//==== FUNC |\Z)", src, re.S | re.M)}
    out = []
    for t in H["tables"]:
        if parser not in t["parser"]: continue
        for e in sorted(t["entries"], key=lambda e: e["op"]):
            if depts is not ALL and e["dept"] not in depts: continue
            c = cat.get(f"0x{e['op']:04x}", {})
            out.append((t["parser"], e, c.get("name"), sizes.get(e["handler"][-8:], 0)))
    return out


GENERIC = """## How to work

1. Read `CLAUDE.md` (shared conventions, tools, established facts) and `docs/plan/00-master-plan.md`.
2. Read `docs/pseudocode/login-server.md`: it is the format and depth to match.
3. Read what exists for your area: `docs/knowledge/*.md` of the items you depend on, `docs/plan/status/{id}.md`
   (resume from it if present), the generated `docs/protocol/opcodes-*.md` / `packets-*.md` rows for your opcodes.
   For each packet, also look up the official name and struct in the 2017 client PDB:
   `python3 -I tools/protocol-re/pdb.py Files/Client/2017/Fiesta.pdb types '^PROTO_NC_<NAME>$'` (field names, offsets,
   sizes; also server-internal packets and shared enums/structs). It is a newer build: confirm against the 2016 code
   and mark unconfirmed PDB facts *(pdb2017)*. Read `docs/knowledge/C02.md` if it exists.
4. For each handler in the scope table, in order:
   - read it: `python3 -I tools/protocol-re/clean.py re-data/exports/<bin> tools/protocol-re/names/<bin> <addr>`
   - follow the callees that carry the logic (skip logging/profiling/container boilerplate)
   - write its pseudocode block (`@ FUN_…`), with field names, checks, state changes, replies, error codes
   - for client-facing packets, check the client handler (C01's `re-data/client-handlers.json` / `docs/knowledge/C01.md`
     if available; otherwise search the client export) and resolve codes via `docs/protocol/client-error-codes.json`
   - record new names (`names/<bin>/{id}.json`) and verified layouts (`docs/protocol/annotations/{id}.json`)
5. Beyond the handlers, document the subsystem itself: data structures, tables loaded, timers, invariants.
6. Every ~10 handlers, update `docs/plan/status/{id}.md` (done / remaining). Before you run low on context,
   write the status so a fresh session can continue.
7. At the end: run `tools/protocol-re/regen.sh`, write `docs/knowledge/{id}.md` (facts others need), add an
   "uncertain / not reconstructed" section to your output, and mark the item done in the status file.

## Rules

- Only write your own files: `{out}`, `docs/knowledge/{id}.md`, `docs/plan/status/{id}.md`,
  `tools/protocol-re/names/<bin>/{id}.json`, `docs/protocol/annotations/{id}.json`.
- Mark deductions *(inferred)*. Never invent names; derive them from strings, client texts, or label them as ours.
- If the scope is too large for one session, finish complete handlers. Never leave a half-documented one.
  List the rest in the status file.
"""


def render(it):
    lines = [f"# {it['id']}: {it['title']}\n",
             f"**Phase:** {it['phase']} · **Depends on:** {', '.join(it['deps']) or 'nothing (can start immediately)'} · "
             f"**Output:** `{it['out']}`\n"]
    if it.get("goal"): lines += ["## Goal\n", it["goal"] + "\n"]
    if it.get("steps"):
        lines += ["## Item-specific guidance\n"] + [f"- {s}" for s in it["steps"]] + [""]
    if it.get("done"): lines += ["## Done when\n", it["done"] + "\n"]
    if it["scope"]:
        lines.append("## Scope: registered handlers\n")
        total, tl = 0, 0
        for bin_, parser, depts in it["scope"]:
            rows = entries(bin_, parser, depts)
            if not rows: continue
            dlabel = "all depts" if depts is ALL else ", ".join(f"{d} {DEPT.get(d, '?')}" for d in depts)
            lines.append(f"### `{bin_}` · {parser or 'all parsers'} · {dlabel}\n")
            lines.append("| Opcode | Dept/Cmd | Name (from binaries) | Handler | Lines | Parser |\n|---|---|---|---|---|---|")
            for p, e, n, sz in rows:
                lines.append(f"| `0x{e['op']:04x}` | {e['dept']}/{e['cmd']} | {n or '?'} | `{e['handler']}` | {sz} | {p.split('::')[-1]} |")
                total += 1; tl += sz
            lines.append("")
        lines.insert(2, f"**Size:** {total} handlers, ~{tl} decompiled lines in handler bodies (callees add more)\n")
    lines.append(GENERIC.format(id=it["id"], out=it["out"]))
    return "\n".join(lines)


os.makedirs(f"{R}/docs/plan/items", exist_ok=True)
os.makedirs(f"{R}/docs/plan/status", exist_ok=True)
summary = []
for it in ITEMS:
    txt = render(it)
    open(f"{R}/docs/plan/items/{it['id']}.md", "w").write(txt)
    m = re.search(r"\*\*Size:\*\* (\d+) handlers, ~(\d+)", txt)
    summary.append((it["id"], it["phase"], it["title"], ", ".join(it["deps"]) or "–", m.group(1) if m else "–", m.group(2) if m else "–"))
json.dump(summary, open(f"{R}/docs/plan/items/_summary.json", "w"), indent=1)
for s in summary: print(*s, sep=" | ")
