# Hand ratings of X02 (read by X02-rate.py; plain Python, executed in its namespace).
# OVERRIDE[(item, § number or heading text)] = (rating, reason, what would raise it)
# CAPS: (item, regex on the § number, highest rating allowed, reason, what would raise it)
# Part 2: Login, WM, shared library, DB servers. Part 3: zone documents and the knowledge files (item key 'K:<ID>').

OVERRIDE.update({
    # capture-validation §2.1: 1 365 packets (batch 1) parsed with no resync; the long form appears exactly for
    # bodies >= 256 bytes; batch 2 decodes all seven captures with 0 issues, links included (§7.1).
    ('S02', '1.7'): ('high', 'receive framing: every captured stream (client and server links) parses with no resync '
                     '(capture-validation §2.1, §7.1); buffer growth and error paths are code only', ''),
    ('S02', '1.8'): ('high', 'frame builder: short / long header of every captured Login and WM send matches '
                     '(capture-validation §2.1); pool exhaustion paths are code only', ''),
    # capture-validation §2.4: Login sent no heartbeat in any capture (the client polls 0x0C1B every 10 s).
    ('L01', '1.6'): ('medium', 'the 30 s / close rule is read in code and seen on the WM and the zone only; the Login '
                     'copy never fired in a capture (capture-validation §2.4)', 'scenario: sit on the login screen '
                     'before the world list (no 0x0C1B poll) for 60 s'),
})

CAPS += [
    # Procedures without source in any backup: the capture of the caller's packet does not show the body.
    ('D06', r'^[2-7](\.|$)', 'medium', 'procedure body inferred from the binds and the caller (no source in a backup); '
     'a captured request shows the call, not what the database does', 'DB setup + capture of the answer (part 9), or the '
     'original procedure source'),
]

# ---- part 3: zone documents ---------------------------------------------------------------------------------
# Baseline limit 1 (confidence.md §2.2): a section got "high" from opcodes it only mentions. Capture set: login,
# idle, walk / portals, shop (buy, equip, storage, sell, soulstones), combat (swing, Bash [01], pick-up, death,
# revive, &levelup, &linkto, Wooden Horse). No silver wing, pet, party, guild, KQ play, scripted map, second player.
OVERRIDE.update({
    ('Z02', '5.1'): ('medium', 'the captured opcodes are only mentioned here (0x1C19 abstate batch); the subject of the section (client 0x1C01 NC_BRIEFINFO_INFORM_CMD) is in no capture', 'capture 0x1C01 (scenario: a second client in sight)'),
    ('Z02', '11'): ('medium', 'the captured opcodes are only mentioned here (0x2401 / 0x2402 targeting); the subject of the section (0x2070 / 0x2071 auto way-finding gate use) is in no capture', 'capture 0x2070, 0x2071'),
    ('Z04', '5.2'): ('medium', 'the captured opcodes are only mentioned here (0x3011 / 0x3410 of the normal equip, §5.1); the subject of the section (0x3010 ring equip) is in no capture', 'capture 0x3010 (equip a ring)'),
    ('Z04', '5.3'): ('medium', 'the captured opcodes are only mentioned here (0x3011 / 0x3410 of the normal equip, §5.1); the subject of the section (0x3050 mini-monster equip) is in no capture', 'capture 0x3050'),
    ('Z04', '8.2'): ('medium', 'the captured opcodes are only mentioned here (0x1047 / 0x104B / 0x104C of the login); the subject of the section (0x3022 / 0x3023 / 0x3465 premium withdraw) is in no capture', 'capture 0x3022, 0x3023 (DB setup: a charged item row, part 9)'),
    ('Z05', '2.5'): ('medium', 'the captured opcodes are only mentioned here (the shared buy answer 0x3004); the subject of the section (0x34A1 capsule buy) is in no capture', 'capture 0x34A1'),
    ('Z05', '2.6'): ('medium', 'the captured opcodes are only mentioned here (the shared buy answer 0x3004); the subject of the section (0x34B2 item-money buy) is in no capture', 'capture 0x34B2'),
    ('Z05', '6.1'): ('medium', 'the captured opcodes are only mentioned here (0x3016 of the ride item, which saves with 0x3449); the subject of the section (0x3440 item use with a DB commit) is in no capture', 'capture 0x3440 (use a stackable consumable)'),
    ('Z07', '6.2'): ('medium', 'the captured opcodes are only mentioned here (WM character-list opcodes); the subject of the section (0x8C01 mini-house activation) is in no capture', 'capture 0x8C01'),
    ('Z09', '5.9'): ('medium', 'the captured opcodes are only mentioned here (0x244A, 0x3004); the subject of the section (NPC object internals and the scheduled NPCs of 0x086A) is in no capture', 'capture 0x086A (event NPC schedule)'),
    ('Z09', '13.3'): ('medium', 'the captured opcodes are only mentioned here (0x1805 object removal); the subject of the section (servants / summoned mobs) is in no capture', 'capture a summoning mob (0x243C)'),
    ('Z09', '14.3'): ('medium', 'the captured opcodes are only mentioned here (0x1803, 0x200A); the subject of the section (Lua object and map events) is in no capture', 'a scripted map (KQ or instance) in a capture'),
    ('Z09', '16.5'): ('medium', 'the captured opcodes are only mentioned here (0x2011 / 0x2013 / 0x201C); the subject of the section (script actions of an NPC role) is in no capture', 'a scripted NPC in a capture'),
    ('Z09', '17.1'): ('medium', 'the captured opcodes are only mentioned here (0x2018 / 0x201A mob moves); the subject of the section (Lua move functions) is in no capture', 'a scripted map in a capture'),
    ('Z09', '24.2'): ('medium', 'the captured opcodes are only mentioned here (0x3449 / 0x344A of the ride item save); the subject of the section (Lua `itemcreate` / `itemerase`) is in no capture', 'a script that gives an item, in a capture'),
    ('Z09', '25.2'): ('medium', 'the captured opcodes are only mentioned here (0x2018 / 0x201A / 0x203E); the subject of the section (Lua mob settings) is in no capture', 'a scripted map in a capture'),
    ('Z09', '27.6'): ('medium', 'the captured opcodes are only mentioned here (0x0821, 0x3016); the subject of the section (boss-field tables) is in no capture', 'a boss field in a capture'),
    ('Z10', '5.4'): ('medium', 'the captured opcodes are only mentioned here (0x203E speed); the subject of the section (the 0x0830 speed-hack check) is in no capture', 'capture 0x0830 (custom client or a lagging one)'),
    ('Z11', '3.5'): ('medium', 'the captured opcodes are only mentioned here (0x1030 / 0x2002 of a normal chat); the subject of the section (the GM colour request 0x083D) is in no capture', 'capture 0x083D (GM command, part 8)'),
    ('Z11', '8.5'): ('medium', 'the captured opcodes are only mentioned here (0x2452 / 0x4821); the subject of the section (`&HP`, `&SP`, `&gmtestmode`) is in no capture', 'capture the commands (part 8)'),
    ('Z13', '6.4'): ('medium', 'the captured opcodes are only mentioned here (0x1805 / 0x244A); the subject of the section (the pet routine) is in no capture', 'capture with a pet summoned'),
    ('Z17', '4.5'): ('medium', 'the captured opcodes are only mentioned here (login and item-move packets); the subject of the section (the action-item box (premium emotes)) is in no capture', 'capture 0x2067, 0x3428 ff.'),
    ('Z23', '2.4'): ('medium', 'the captured opcodes are only mentioned here (0x2047, 0xC809); the subject of the section (automatic switch-off of a toggle skill) is in no capture', 'capture 0x245D, 0x4007 (toggle skill, then map link)'),
    ('Z25', '6.8'): ('medium', 'the captured opcodes are only mentioned here (0x2452 / 0x2457 of Bash [01]); the subject of the section (chain blasts) is in no capture', 'capture a chain skill (0x245E)'),
    ('Z26', '2'): ('medium', 'silver wing used in no capture: the captured opcodes are the NPC server menu (0x3C01 / 0x3C02), the ride item (0x3015 / 0x3016 / 0x3449) and `&linkto` (0x180D)', 'scenario: save a location and fly with a silver wing (part 8)'),
    ('Z26', '3'): ('medium', 'silver wing used in no capture: the captured opcodes are the NPC server menu (0x3C01 / 0x3C02), the ride item (0x3015 / 0x3016 / 0x3449) and `&linkto` (0x180D)', 'scenario: save a location and fly with a silver wing (part 8)'),
    ('Z26', '3.1'): ('medium', 'silver wing used in no capture: the captured opcodes are the NPC server menu (0x3C01 / 0x3C02), the ride item (0x3015 / 0x3016 / 0x3449) and `&linkto` (0x180D)', 'scenario: save a location and fly with a silver wing (part 8)'),
    ('Z26', '3.2'): ('medium', 'silver wing used in no capture: the captured opcodes are the NPC server menu (0x3C01 / 0x3C02), the ride item (0x3015 / 0x3016 / 0x3449) and `&linkto` (0x180D)', 'scenario: save a location and fly with a silver wing (part 8)'),
    ('Z26', '4'): ('medium', 'silver wing used in no capture: the captured opcodes are the NPC server menu (0x3C01 / 0x3C02), the ride item (0x3015 / 0x3016 / 0x3449) and `&linkto` (0x180D)', 'scenario: save a location and fly with a silver wing (part 8)'),
    ('Z26', '4.1'): ('medium', 'silver wing used in no capture: the captured opcodes are the NPC server menu (0x3C01 / 0x3C02), the ride item (0x3015 / 0x3016 / 0x3449) and `&linkto` (0x180D)', 'scenario: save a location and fly with a silver wing (part 8)'),
    ('Z26', '4.2'): ('medium', 'silver wing used in no capture: the captured opcodes are the NPC server menu (0x3C01 / 0x3C02), the ride item (0x3015 / 0x3016 / 0x3449) and `&linkto` (0x180D)', 'scenario: save a location and fly with a silver wing (part 8)'),
    ('Z26', '4.4'): ('medium', 'silver wing used in no capture: the captured opcodes are the NPC server menu (0x3C01 / 0x3C02), the ride item (0x3015 / 0x3016 / 0x3449) and `&linkto` (0x180D)', 'scenario: save a location and fly with a silver wing (part 8)'),
    ('Z26', '5.2'): ('medium', 'silver wing used in no capture: the captured opcodes are the NPC server menu (0x3C01 / 0x3C02), the ride item (0x3015 / 0x3016 / 0x3449) and `&linkto` (0x180D)', 'scenario: save a location and fly with a silver wing (part 8)'),
    ('Z26', '5.4'): ('medium', 'silver wing used in no capture: the captured opcodes are the NPC server menu (0x3C01 / 0x3C02), the ride item (0x3015 / 0x3016 / 0x3449) and `&linkto` (0x180D)', 'scenario: save a location and fly with a silver wing (part 8)'),
    ('Z26', '6'): ('medium', 'silver wing used in no capture: the captured opcodes are the NPC server menu (0x3C01 / 0x3C02), the ride item (0x3015 / 0x3016 / 0x3449) and `&linkto` (0x180D)', 'scenario: save a location and fly with a silver wing (part 8)'),
    ('Z15', '1.1'): ('medium', 'the only client citation says the client shares the `CQuest` / `CQuestData` library code; nothing on the wire and no capture of a quest step', 'capture: accept, progress and finish one quest'),
    ('Z15', '4'): ('medium', 'the only client citation says the client shares the `CQuest` / `CQuestData` library code; nothing on the wire and no capture of a quest step', 'capture: accept, progress and finish one quest'),
    ('Z15', '4.1'): ('medium', 'the only client citation says the client shares the `CQuest` / `CQuestData` library code; nothing on the wire and no capture of a quest step', 'capture: accept, progress and finish one quest'),
    ('Z15', '4.5'): ('medium', 'the only client citation says the client shares the `CQuest` / `CQuestData` library code; nothing on the wire and no capture of a quest step', 'capture: accept, progress and finish one quest'),
    ('Z09', '10.1'): ('medium', 'one client citation (`MobNoFadeInTab`) in a list of server data files', 'second reading'),
    ('Z13', '5.8'): ('medium', 'captured only with no pet (0x4033 / 0xD412 `bDoResummon 0`, ids -1): the re-summon branch never ran', 'capture a map link with a pet out'),
    ('Z17', '3.4.1'): ('medium', 'capture credit comes from the shared 0x3016 / 0x482C; no capture is known to contain an item with an action set', 'capture: equip an item with an `ItemAction` row and kill a mob'),
    ('Z18', '3.8'): ('medium', 'table of 22 helpers; the captures touch the attack-timing rows only (0x242B, 0x2440, moves), not polymorph, skill teach, empower', 'per row: Z03 §3 for the timing, scenarios for the rest'),
})

# ---- part 3: knowledge files -----------------------------------------------------------------------------------
OVERRIDE.update({
    ('K:P02', 'Corrections'): ('high', 'every row is a capture finding with its packet count and the code place', ''),
    ('K:P02', 'Facts'): ('high', 'capture facts (orders, timings, field values) with the code place; *(inferred)* marks the 8 deductions', ''),
    ('K:C01', 'AccountFrameWork'): ('high', 'dispatch table of the login scene: 11 of 12 opcodes captured and handled as listed', ''),
    ('K:C01', 'LoginWorldNetFrameWork'): ('high', 'dispatch table: 5 of 6 opcodes captured', ''),
    ('K:C01', 'ZoneLoginNetFrameWork'): ('high', 'dispatch table: 18 of 24 opcodes captured (the character-load burst)', ''),
    ('K:C01', 'LinkFrameWork'): ('high', 'dispatch table: 15 of 22 opcodes captured (map links)', ''),
})

# ---- part 4: after the re-check of confidence.md §3.2 ----------------------------------------------------------
OVERRIDE.update({
    ('K:Z01', '3'): ('high', 're-checked (§3.2.2 H1–H3): every range bound re-read in sohu_HandleSplit FUN_00633650, all 13 '
                     'object sizes are the class sizes of the 2016 Zone.pdb', ''),
    ('K:Z01', '4'): ('medium', 're-checked (§3.2.3): all 36 offsets are 2016 PDB members; 2 meanings corrected (+0x29638 = '
                     'character title, +0x2a800 = sp_isPossibleNewConnect, cleared by 0x0806 / 0x1801 only), 1 refined '
                     '(+0x1c00 = total, not base); read with docs/knowledge/X02.md §0', 'capture of a field per member '
                     '(0x1038 login burst for basedata)'),
    ('K:Z01', '6'): ('medium', 're-checked (§3.2.1): lookup pattern confirmed with counts over 307 handlers; the "PDB offset '
                     '= 2016 − 6" rule corrected (211 structs carry the header as a member) and "starts with" narrowed '
                     '(R2–R4, R6); read with docs/knowledge/X02.md §0', 'a captured DB→zone answer per header form'),
    ('K:Z03', '2'): ('medium', 're-checked (§3.2.4): every offset is a 2016 PDB member; names of 4 smo_Flag bits, the '
                     'EngageArgument fields and the abstate element +0x70 corrected, stat matrix and battle statistics '
                     'superseded by Z12 §1.1 / Z16 §3.1; read with docs/knowledge/X02.md §0', 'combat capture with an '
                     'abstate set and removed by walking (aeo_MiscData reset condition)'),
})
