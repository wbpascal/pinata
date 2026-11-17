# Capture coverage per feature area

Research for issue #5 (wayfinder map: issue #1). State of the repository on 2026-11-17, commit `4b077aa`.

**Sources** (local only):

- the 17 captures in `re-data/captures/*.pcapng`, decoded for this note with `tools/protocol-re/pcap_decode.py`
  (opcode sets only; no payload is reproduced here);
- the scenario notes `re-data/captures/*.md`;
- `docs/protocol/capture-validation.md` (P02; cited as CV §n);
- `docs/plan/capture-scenarios.md` (X02; cited as CS §n) and `docs/plan/capture-guide.md`;
- `docs/plan/status/P01.md` … `P05.md`.

"Client-facing" below means the Login, WM and zone client ports. Server-link traffic is counted but not listed: the
rebuild is free to change it (issue #1).

## Answer in short

1. **17 captures exist.** 16 are validated by P02 (CV §1); the 17th, scenario 46 (`s46`), was added on 2026-11-17 and
   no document mentions it yet.
2. **Together they hold 282 client-facing opcode types** (Login 14, WM 61, zone 207), in 21 of the 49 departments
   `opcodes.json` knows.
3. **Well covered:** login, world select, character list / create / delete / rename, map entry, map change, logout
   and session loss, movement, sight, basic combat, death and revive, items (inventory, shop, storage, soul stones),
   skills and stat points.
4. **Not covered at all:** party, raid, guild, guild academy, friends, trade, booth, quests, upgrades, pets, mounts,
   mini-house, wedding, Kingdom Quest play, instance dungeons, dice / gamble / cards, block list and reports, holy
   promise, prison. No capture holds a single client packet of departments 14, 19, 21, 26, 29, 38, 41, 43, 44, 53.
5. **Milestone 1 of issue #1** (login, world, character list / create / delete) is covered, including the refusals.
   One planned gap is left: steps of scenario 37 that the second run did not repeat (CS §2 rank 1).
6. **A byte-for-byte replay is not possible without a mask list.** Seeds, validation keys, tokens, handles, clock
   values, damage rolls and about a dozen fields of uninitialised memory differ from run to run (§4).

## 1. Per capture: flow and opcodes

Scenario text comes from the notes files and CV §1. `sNN` is the short name the other documents use.

| Capture | Short | Flow | Packets | Validated in |
|---|---|---|---|---|
| `26_11_15_login-logout` | – | log in, world select, character list, back to world select, quit | 26 | CV §3, §4 |
| `26_11_15_login-errors` | – | wrong password; same account on a second client, first one kicked | 44 | CV §3, §4 |
| `26_11_15_create-char` | – | create a character, delete it | 30 | CV §4 |
| `26_11_15_idle_in_world` | – | enter the map, stand among mobs, log out to character select, world list | 208 | CV §5, §6 |
| `26_11_15_walk-run-portals` | – | run, walk, town portal several times, link portal to another map | 1 057 | CV §5, §6 |
| `26_11_15_buy item, equip item, …` | shop | buy, equip, storage, unequip, sell, portal, attack, soul stones; `&levelup` | 1 570 | CV §7–§10 |
| `26_11_15_travel portal, attack mob, …` | combat | portal, fight mobs, pick up drops, die, revive, link portal, mover | 1 870 | CV §7–§10 |
| `26_11_15_14_second-client-in-sight` | s14 | second account creates a character, walks into sight; emote, jump, shout, whisper, combat seen by a third player; GM hide / show / dimension / linkto | 13 468 | CV §18 |
| `26_11_15_21_items-drop-split-storage-use-shop` | s21 | split, merge, drop, pick up, destroy, use, rings, storage with money, sell and buy back, soul stones, full inventory | 11 569 | CV §19–§20 |
| `26_11_15_21b_purchase-attr-write-fail` | s21b | DB setup S16: a purchase whose attribute write fails | 397 | CV §21.1 |
| `26_11_15_21c_expired-item` | s21c | DB setup S13: an item past its end time | 606 | CV §21.2 |
| `26_11_15_21d_stack-over-maxlot` | s21d | table experiment X3: a stack over its limit; zone restart | 853 | CV §21.3 |
| `26_11_15_37_login-heartbeat-refusals-delete` | s37 | idle on login screen, world list and character list; create / delete / re-create; world closed; world full; blocked account; account not login-able | 3 583 | CV §16–§17 |
| `26_11_16_37b_char-select-rename-refusals` | s37b | create refused (name taken); free rename; rename right; character login with all zones down | 3 886 | CV §22 |
| `26_11_16_38_session-loss-kicks-char-select` | s38 | back to character select; quit in game; zone connection closed; client killed; zone killed four times | 11 976 | CV §23 |
| `26_11_16_24_skills-abstates-stat-points` | s24 | learn a skill, empower, stat points, reset items, cast abort, ground target, toggle skill, abstate reset conditions, damage over time, death, revive by skill | 14 722 | CV §24–§25 |
| `26_11_16_46_items-merge-buyback-refusals` | s46 | stack onto a fuller stack, storage, sell / buy back onto an empty cell, buy-back refusals (money, level, full inventory), soul stones without money and over the limit | 4 408 | **not validated yet** |

The five captures without a short name are batch 1 and hold client traffic only. All others were recorded on the
server PC and also hold the server links (CV §1).

### Client-facing opcodes per capture

Generated from the decoder's JSON output. Opcode = `dept << 10 | cmd`; names are in `docs/protocol/opcodes.json`.

#### `26_11_15_14_second-client-in-sight`

13468 packets. Opcode types on server links: 140.

- **login C→S** (5): `0x0C04` `0x0C0B` `0x0C1B` `0x0C5A` `0x0C65`
- **login S→C** (6): `0x0807` `0x0C05` `0x0C0A` `0x0C0C` `0x0C1C` `0x0C67`
- **wm C→S** (12): `0x0805` `0x080D` `0x0C0F` `0x1001` `0x10DA` `0x1111` `0x1401` `0x200C` `0x581B` `0x7004` `0x700C` `0x7C06`
- **wm S→C** (24): `0x0804` `0x0807` `0x080E` `0x0849` `0x0C14` `0x1003` `0x1012` `0x1097` `0x10D9` `0x1110` `0x1406` `0x182A` `0x200D` `0x200F` `0x581C` `0x581D` `0x5826` `0x7005` `0x700D` `0x7032` `0x7033` `0x7034` `0x7C07` `0x9414`
- **zone C→S** (20): `0x0805` `0x1801` `0x1803` `0x1C01` `0x2001` `0x2008` `0x200A` `0x200B` `0x2012` `0x2019` `0x201E` `0x2020` `0x2024` `0x2401` `0x2408` `0x242B` `0x2432` `0x2440` `0x3020` `0x302C`
- **zone S→C** (73): `0x0804` `0x0807` `0x1035` `0x1038` `0x1039` `0x103A` `0x103B` `0x103D` `0x103E` `0x1047` `0x1048` `0x1049` `0x104A` `0x105B` `0x10C6` `0x10CE` `0x10D4` `0x10D7` `0x10DE` `0x10E4` `0x10E7` `0x10EA` `0x1123` `0x1802` `0x1805` `0x1809` `0x1827` `0x182B` `0x1C04` `0x1C05` `0x1C06` `0x1C08` `0x1C09` `0x1C0A` `0x1C0E` `0x1C18` `0x1C19` `0x2002` `0x2009` `0x2011` `0x2013` `0x2018` `0x201A` `0x201F` `0x2021` `0x2025` `0x203E` `0x2402` `0x240B` `0x240E` `0x240F` `0x2428` `0x2429` `0x242A` `0x2435` `0x243D` `0x2447` `0x2448` `0x2449` `0x244A` `0x244E` `0x244F` `0x2452` `0x2457` `0x245F` `0x3001` `0x3021` `0x302D` `0x4401` `0x441E` `0x482C` `0x583A` `0x9010`

#### `26_11_15_21_items-drop-split-storage-use-shop`

11569 packets. Opcode types on server links: 192.

- **login C→S** (4): `0x0C04` `0x0C0B` `0x0C5A` `0x0C65`
- **login S→C** (6): `0x0807` `0x0C05` `0x0C09` `0x0C0A` `0x0C0C` `0x0C67`
- **wm C→S** (9): `0x0805` `0x080D` `0x0C0F` `0x1001` `0x10DA` `0x581B` `0x7004` `0x700C` `0x7C06`
- **wm S→C** (24): `0x0804` `0x0807` `0x080E` `0x0849` `0x0C14` `0x1003` `0x1012` `0x1097` `0x10D9` `0x182A` `0x2079` `0x581C` `0x581D` `0x581E` `0x5825` `0x5826` `0x6402` `0x7005` `0x700D` `0x7032` `0x7033` `0x7034` `0x7C07` `0x9414`
- **zone C→S** (34): `0x0805` `0x1801` `0x1803` `0x2001` `0x2008` `0x200A` `0x200B` `0x2012` `0x2019` `0x201D` `0x2401` `0x2408` `0x242B` `0x2432` `0x2440` `0x3006` `0x3007` `0x3009` `0x300B` `0x300D` `0x300F` `0x3012` `0x3015` `0x301C` `0x301E` `0x3020` `0x302C` `0x304D` `0x3059` `0x3C02` `0x5001` `0x5002` `0x5007` `0x5009`
- **zone S→C** (111): `0x0804` `0x0807` `0x1033` `0x1035` `0x1038` `0x1039` `0x103A` `0x103B` `0x103D` `0x103E` `0x1047` `0x1048` `0x1049` `0x104A` `0x105B` `0x106F` `0x10C6` `0x10CE` `0x10D4` `0x10D7` `0x10DE` `0x10E4` `0x10E7` `0x10EA` `0x1123` `0x112C` `0x1802` `0x1805` `0x1827` `0x182B` `0x1C04` `0x1C05` `0x1C06` `0x1C07` `0x1C08` `0x1C09` `0x1C0A` `0x1C0E` `0x1C18` `0x1C19` `0x2002` `0x2009` `0x2011` `0x2013` `0x2018` `0x201A` `0x201B` `0x201C` `0x203E` `0x2402` `0x240B` `0x240C` `0x240D` `0x240E` `0x240F` `0x2427` `0x2428` `0x2429` `0x242A` `0x2435` `0x243D` `0x2446` `0x2447` `0x2448` `0x2449` `0x244A` `0x244E` `0x244F` `0x2452` `0x2457` `0x245F` `0x3001` `0x3002` `0x3004` `0x3005` `0x3008` `0x300A` `0x300C` `0x300E` `0x3011` `0x3013` `0x3014` `0x3016` `0x301A` `0x301D` `0x301F` `0x3021` `0x3024` `0x302D` `0x305A` `0x305C` `0x305D` `0x3C01` `0x3C05` `0x3C08` `0x3C09` `0x3C0B` `0x4401` `0x441E` `0x4810` `0x482C` `0x5003` `0x5004` `0x5008` `0x500A` `0x500B` `0x500C` `0x583A` `0x6004` `0x9010` `0xBC05`

#### `26_11_15_21b_purchase-attr-write-fail`

397 packets. Opcode types on server links: 115.

- **login C→S** (5): `0x0C04` `0x0C0B` `0x0C1B` `0x0C5A` `0x0C65`
- **login S→C** (6): `0x0807` `0x0C05` `0x0C0A` `0x0C0C` `0x0C1C` `0x0C67`
- **wm C→S** (7): `0x080D` `0x0C0F` `0x1001` `0x581B` `0x7004` `0x700C` `0x7C06`
- **wm S→C** (19): `0x0807` `0x080E` `0x0849` `0x0C14` `0x1003` `0x1012` `0x1097` `0x10D9` `0x182A` `0x581C` `0x581D` `0x5826` `0x7005` `0x700D` `0x7032` `0x7033` `0x7034` `0x7C07` `0x9414`
- **zone C→S** (11): `0x1801` `0x1803` `0x2001` `0x200A` `0x200B` `0x2012` `0x201D` `0x2401` `0x3003` `0x3020` `0x302C`
- **zone S→C** (51): `0x0807` `0x1035` `0x1038` `0x1039` `0x103A` `0x103B` `0x103D` `0x103E` `0x1047` `0x1048` `0x1049` `0x104A` `0x105B` `0x10C6` `0x10CE` `0x10D4` `0x10D7` `0x10DE` `0x10E4` `0x10E7` `0x10EA` `0x1123` `0x1802` `0x1827` `0x182B` `0x1C04` `0x1C05` `0x1C09` `0x1C0E` `0x1C18` `0x2011` `0x2018` `0x201A` `0x201C` `0x203E` `0x2402` `0x240E` `0x240F` `0x2428` `0x2429` `0x242A` `0x243D` `0x245F` `0x3004` `0x3021` `0x302D` `0x3C09` `0x441E` `0x482C` `0x583A` `0x9010`

#### `26_11_15_21c_expired-item`

606 packets. Opcode types on server links: 116.

- **login C→S** (5): `0x0C04` `0x0C0B` `0x0C1B` `0x0C5A` `0x0C65`
- **login S→C** (6): `0x0807` `0x0C05` `0x0C0A` `0x0C0C` `0x0C1C` `0x0C67`
- **wm C→S** (8): `0x0805` `0x080D` `0x0C0F` `0x1001` `0x581B` `0x7004` `0x700C` `0x7C06`
- **wm S→C** (22): `0x0804` `0x0807` `0x080E` `0x0849` `0x0C14` `0x1003` `0x1012` `0x1097` `0x10D9` `0x182A` `0x581C` `0x581D` `0x581E` `0x5825` `0x5826` `0x7005` `0x700D` `0x7032` `0x7033` `0x7034` `0x7C07` `0x9414`
- **zone C→S** (9): `0x0805` `0x1801` `0x1803` `0x2001` `0x200B` `0x2012` `0x2019` `0x3020` `0x302C`
- **zone S→C** (49): `0x0804` `0x0807` `0x1035` `0x1038` `0x1039` `0x103A` `0x103B` `0x103D` `0x103E` `0x1047` `0x1048` `0x1049` `0x104A` `0x105B` `0x10C6` `0x10CE` `0x10D4` `0x10D7` `0x10DE` `0x10E4` `0x10E7` `0x10EA` `0x1123` `0x1802` `0x1827` `0x182B` `0x1C04` `0x1C05` `0x1C08` `0x1C09` `0x1C0E` `0x1C18` `0x2011` `0x2018` `0x201A` `0x203E` `0x240E` `0x240F` `0x2428` `0x2429` `0x242A` `0x245F` `0x3001` `0x3021` `0x302D` `0x441E` `0x482C` `0x583A` `0x9010`

#### `26_11_15_21d_stack-over-maxlot`

853 packets. Opcode types on server links: 134.

- **login C→S** (4): `0x0C04` `0x0C0B` `0x0C5A` `0x0C65`
- **login S→C** (5): `0x0807` `0x0C05` `0x0C0A` `0x0C0C` `0x0C67`
- **wm C→S** (8): `0x0805` `0x080D` `0x0C0F` `0x1001` `0x581B` `0x7004` `0x700C` `0x7C06`
- **wm S→C** (22): `0x0804` `0x0807` `0x080E` `0x0849` `0x0C14` `0x1003` `0x1012` `0x1097` `0x10D9` `0x182A` `0x581C` `0x581D` `0x581F` `0x5824` `0x5826` `0x7005` `0x700D` `0x7032` `0x7033` `0x7034` `0x7C07` `0x9414`
- **zone C→S** (9): `0x1801` `0x1803` `0x2001` `0x200B` `0x3007` `0x3009` `0x3020` `0x302C` `0x3C02`
- **zone S→C** (53): `0x0807` `0x1035` `0x1038` `0x1039` `0x103A` `0x103B` `0x103D` `0x103E` `0x1047` `0x1048` `0x1049` `0x104A` `0x105B` `0x10C6` `0x10CE` `0x10D4` `0x10D7` `0x10DE` `0x10E4` `0x10E7` `0x10EA` `0x1123` `0x1802` `0x1805` `0x1827` `0x182B` `0x1C04` `0x1C05` `0x1C08` `0x1C09` `0x1C0A` `0x1C0E` `0x1C18` `0x2011` `0x2018` `0x201A` `0x203E` `0x240E` `0x240F` `0x2428` `0x2429` `0x242A` `0x245F` `0x3001` `0x3008` `0x300A` `0x3021` `0x302D` `0x3C01` `0x441E` `0x482C` `0x583A` `0x9010`

#### `26_11_15_37_login-heartbeat-refusals-delete`

3583 packets. Opcode types on server links: 76.

- **login C→S** (7): `0x0C04` `0x0C0B` `0x0C18` `0x0C1B` `0x0C37` `0x0C5A` `0x0C65`
- **login S→C** (7): `0x0807` `0x0C05` `0x0C09` `0x0C0A` `0x0C0C` `0x0C1C` `0x0C67`
- **wm C→S** (6): `0x0805` `0x080D` `0x0C0F` `0x0C33` `0x1401` `0x1407`
- **wm S→C** (7): `0x0804` `0x0807` `0x080E` `0x0C14` `0x0C34` `0x1406` `0x140C`

#### `26_11_15_buy item, equip item, use storage, unequip, sell item, travel portal, attack, use soulstones`

1570 packets. Opcode types on server links: 179.

- **login C→S** (5): `0x0C04` `0x0C0B` `0x0C1B` `0x0C5A` `0x0C65`
- **login S→C** (6): `0x0807` `0x0C05` `0x0C0A` `0x0C0C` `0x0C1C` `0x0C67`
- **wm C→S** (9): `0x0805` `0x080D` `0x0C0F` `0x1001` `0x10DA` `0x581B` `0x7004` `0x700C` `0x7C06`
- **wm S→C** (22): `0x0804` `0x0807` `0x080E` `0x0849` `0x0C14` `0x1003` `0x1012` `0x1097` `0x10D9` `0x182A` `0x581C` `0x581D` `0x581F` `0x5824` `0x5826` `0x7005` `0x700D` `0x7032` `0x7033` `0x7034` `0x7C07` `0x9414`
- **zone C→S** (27): `0x1801` `0x1803` `0x2001` `0x2008` `0x200A` `0x200B` `0x2012` `0x2019` `0x201D` `0x2401` `0x2408` `0x242B` `0x2432` `0x2440` `0x3003` `0x3006` `0x3009` `0x300B` `0x300F` `0x3012` `0x3020` `0x302C` `0x304D` `0x3C02` `0x4025` `0x5007` `0x5009`
- **zone S→C** (85): `0x0807` `0x1033` `0x1035` `0x1038` `0x1039` `0x103A` `0x103B` `0x103D` `0x103E` `0x1047` `0x1048` `0x1049` `0x104A` `0x105B` `0x106F` `0x10C6` `0x10CE` `0x10D4` `0x10D7` `0x10DE` `0x10E4` `0x10E7` `0x10EA` `0x1123` `0x1802` `0x1805` `0x180A` `0x1827` `0x182B` `0x1C04` `0x1C05` `0x1C08` `0x1C09` `0x1C0A` `0x1C0E` `0x1C18` `0x2011` `0x2013` `0x2018` `0x201A` `0x201C` `0x203E` `0x2402` `0x240B` `0x240C` `0x240E` `0x240F` `0x2428` `0x2429` `0x242A` `0x2435` `0x243D` `0x2446` `0x2447` `0x2448` `0x244A` `0x244E` `0x2452` `0x2457` `0x245F` `0x3001` `0x3002` `0x3004` `0x3005` `0x300A` `0x300C` `0x3011` `0x3021` `0x302D` `0x305C` `0x3C01` `0x3C08` `0x3C09` `0x3C0B` `0x4026` `0x4401` `0x441E` `0x4810` `0x482C` `0x5008` `0x500A` `0x583A` `0x9010` `0xBC04` `0xBC05`

#### `26_11_15_create-char`

30 packets. Opcode types on server links: 0.

- **login C→S** (5): `0x0C04` `0x0C0B` `0x0C1B` `0x0C5A` `0x0C65`
- **login S→C** (6): `0x0807` `0x0C05` `0x0C0A` `0x0C0C` `0x0C1C` `0x0C67`
- **wm C→S** (5): `0x0805` `0x080D` `0x0C0F` `0x1401` `0x1407`
- **wm S→C** (6): `0x0804` `0x0807` `0x080E` `0x0C14` `0x1406` `0x140C`

#### `26_11_15_idle_in_world`

208 packets. Opcode types on server links: 0.

- **login C→S** (6): `0x0C04` `0x0C0B` `0x0C1B` `0x0C37` `0x0C5A` `0x0C65`
- **login S→C** (6): `0x0807` `0x0C05` `0x0C0A` `0x0C0C` `0x0C1C` `0x0C67`
- **wm C→S** (14): `0x0805` `0x080D` `0x0C0F` `0x0C18` `0x0C33` `0x1001` `0x581B` `0x7004` `0x700C` `0x7011` `0x7015` `0x7016` `0x703B` `0x7C06`
- **wm S→C** (23): `0x0804` `0x0807` `0x080E` `0x0849` `0x0C14` `0x0C34` `0x1003` `0x1012` `0x1097` `0x10D9` `0x182A` `0x581C` `0x581D` `0x581F` `0x5824` `0x5826` `0x7005` `0x700D` `0x7032` `0x7033` `0x7034` `0x7C07` `0x9414`
- **zone C→S** (10): `0x0805` `0x0C18` `0x1071` `0x1801` `0x1803` `0x2001` `0x200B` `0x2012` `0x3020` `0x302C`
- **zone S→C** (50): `0x0804` `0x0807` `0x1035` `0x1038` `0x1039` `0x103A` `0x103B` `0x103D` `0x103E` `0x1047` `0x1048` `0x1049` `0x104A` `0x105B` `0x10BD` `0x10C6` `0x10CE` `0x10D4` `0x10D7` `0x10DE` `0x10E4` `0x10E7` `0x10EA` `0x1123` `0x1802` `0x1827` `0x182B` `0x1C02` `0x1C03` `0x1C04` `0x1C05` `0x1C09` `0x1C18` `0x2011` `0x2018` `0x201A` `0x203E` `0x240E` `0x240F` `0x2428` `0x2429` `0x242A` `0x245F` `0x3002` `0x3021` `0x302D` `0x441E` `0x482C` `0x583A` `0x9010`

#### `26_11_15_login-errors`

44 packets. Opcode types on server links: 0.

- **login C→S** (5): `0x0C04` `0x0C0B` `0x0C1B` `0x0C5A` `0x0C65`
- **login S→C** (7): `0x0807` `0x0C05` `0x0C09` `0x0C0A` `0x0C0C` `0x0C1C` `0x0C67`
- **wm C→S** (3): `0x0805` `0x080D` `0x0C0F`
- **wm S→C** (5): `0x0804` `0x0807` `0x080E` `0x0C14` `0x0C17`

#### `26_11_15_login-logout`

26 packets. Opcode types on server links: 0.

- **login C→S** (7): `0x0C04` `0x0C0B` `0x0C18` `0x0C1B` `0x0C37` `0x0C5A` `0x0C65`
- **login S→C** (6): `0x0807` `0x0C05` `0x0C0A` `0x0C0C` `0x0C1C` `0x0C67`
- **wm C→S** (3): `0x080D` `0x0C0F` `0x0C33`
- **wm S→C** (4): `0x0807` `0x080E` `0x0C14` `0x0C34`

#### `26_11_15_travel portal, attack mob, pick-up item, die, revive, linkto`

1870 packets. Opcode types on server links: 160.

- **login C→S** (5): `0x0C04` `0x0C0B` `0x0C1B` `0x0C5A` `0x0C65`
- **login S→C** (6): `0x0807` `0x0C05` `0x0C0A` `0x0C0C` `0x0C1C` `0x0C67`
- **wm C→S** (9): `0x0805` `0x080D` `0x0C0F` `0x1001` `0x581B` `0x7004` `0x700C` `0x7037` `0x7C06`
- **wm S→C** (21): `0x0804` `0x0807` `0x080E` `0x0849` `0x0C14` `0x1003` `0x1012` `0x1097` `0x10D9` `0x182A` `0x581C` `0x581D` `0x5826` `0x7005` `0x700D` `0x7032` `0x7033` `0x7034` `0x7038` `0x7C07` `0x9414`
- **zone C→S** (18): `0x104E` `0x1801` `0x1803` `0x2001` `0x2008` `0x200A` `0x200B` `0x2012` `0x2019` `0x2401` `0x242B` `0x2432` `0x2440` `0x3009` `0x3015` `0x3020` `0x302C` `0x3C02`
- **zone S→C** (79): `0x0807` `0x1035` `0x1038` `0x1039` `0x103A` `0x103B` `0x103D` `0x103E` `0x1047` `0x1048` `0x1049` `0x104A` `0x104D` `0x104F` `0x105B` `0x10C6` `0x10CE` `0x10D4` `0x10D7` `0x10DE` `0x10E4` `0x10E7` `0x10EA` `0x1123` `0x1802` `0x1805` `0x180A` `0x1827` `0x182B` `0x1C04` `0x1C05` `0x1C08` `0x1C09` `0x1C0A` `0x1C0E` `0x1C18` `0x1C19` `0x1C1A` `0x2002` `0x2011` `0x2013` `0x2018` `0x201A` `0x201B` `0x203E` `0x2047` `0x2048` `0x2402` `0x240B` `0x240E` `0x240F` `0x2428` `0x2429` `0x242A` `0x2435` `0x243D` `0x2447` `0x2448` `0x244A` `0x244E` `0x2452` `0x2457` `0x245F` `0x3001` `0x300A` `0x3016` `0x3021` `0x302D` `0x3C01` `0x441E` `0x4821` `0x482C` `0x583A` `0x9010` `0xCC02` `0xCC04` `0xCC06` `0xCC0A` `0xCC0D`

#### `26_11_15_walk-run-portals`

1057 packets. Opcode types on server links: 0.

- **login C→S** (5): `0x0C04` `0x0C0B` `0x0C1B` `0x0C5A` `0x0C65`
- **login S→C** (6): `0x0807` `0x0C05` `0x0C0A` `0x0C0C` `0x0C1C` `0x0C67`
- **wm C→S** (8): `0x0805` `0x080D` `0x0C0F` `0x1001` `0x581B` `0x7004` `0x700C` `0x7C06`
- **wm S→C** (20): `0x0804` `0x0807` `0x080E` `0x0849` `0x0C14` `0x1003` `0x1012` `0x1097` `0x10D9` `0x182A` `0x581C` `0x581D` `0x5826` `0x7005` `0x700D` `0x7032` `0x7033` `0x7034` `0x7C07` `0x9414`
- **zone C→S** (14): `0x0805` `0x1801` `0x1803` `0x181A` `0x2001` `0x200A` `0x200B` `0x2012` `0x2017` `0x2019` `0x2401` `0x3020` `0x302C` `0x3C02`
- **zone S→C** (55): `0x0804` `0x0807` `0x1035` `0x1038` `0x1039` `0x103A` `0x103B` `0x103D` `0x103E` `0x1047` `0x1048` `0x1049` `0x104A` `0x105B` `0x10C6` `0x10CE` `0x10D4` `0x10D7` `0x10DE` `0x10E4` `0x10E7` `0x10EA` `0x1123` `0x1802` `0x180A` `0x181B` `0x1827` `0x182B` `0x1C04` `0x1C05` `0x1C08` `0x1C09` `0x1C0E` `0x1C18` `0x2011` `0x2018` `0x201A` `0x201B` `0x201C` `0x203E` `0x2402` `0x240E` `0x240F` `0x2428` `0x2429` `0x242A` `0x243D` `0x245F` `0x3021` `0x302D` `0x3C01` `0x441E` `0x482C` `0x583A` `0x9010`

#### `26_11_16_24_skills-abstates-stat-points`

14722 packets. Opcode types on server links: 215.

- **login C→S** (5): `0x0C04` `0x0C0B` `0x0C1B` `0x0C5A` `0x0C65`
- **login S→C** (6): `0x0807` `0x0C05` `0x0C0A` `0x0C0C` `0x0C1C` `0x0C67`
- **wm C→S** (15): `0x0805` `0x080D` `0x0C0F` `0x0C18` `0x1001` `0x10DA` `0x581B` `0x7004` `0x700C` `0x7011` `0x7015` `0x7016` `0x7037` `0x703B` `0x7C06`
- **wm S→C** (26): `0x0804` `0x0807` `0x080E` `0x0849` `0x0C14` `0x1003` `0x1012` `0x1097` `0x10D9` `0x182A` `0x2079` `0x581C` `0x581D` `0x581E` `0x581F` `0x5824` `0x5825` `0x5826` `0x7005` `0x700D` `0x7032` `0x7033` `0x7034` `0x7038` `0x7C07` `0x9414`
- **zone C→S** (36): `0x0805` `0x0C18` `0x104E` `0x105C` `0x1062` `0x1071` `0x1801` `0x1803` `0x181A` `0x2001` `0x2008` `0x200A` `0x200B` `0x2012` `0x2017` `0x2019` `0x201D` `0x2401` `0x2408` `0x242B` `0x2432` `0x2440` `0x2441` `0x2444` `0x3003` `0x3009` `0x300F` `0x3012` `0x3015` `0x3020` `0x302C` `0x304A` `0x4025` `0x4811` `0x482A` `0x5007`
- **zone S→C** (117): `0x0804` `0x0807` `0x0842` `0x1033` `0x1035` `0x1038` `0x1039` `0x103A` `0x103B` `0x103D` `0x103E` `0x1047` `0x1048` `0x1049` `0x104A` `0x104D` `0x104F` `0x105B` `0x105F` `0x1065` `0x106F` `0x10C6` `0x10CE` `0x10D4` `0x10D7` `0x10DE` `0x10E4` `0x10E7` `0x10EA` `0x1123` `0x112C` `0x1802` `0x1805` `0x1809` `0x180A` `0x181B` `0x1827` `0x182B` `0x1C03` `0x1C04` `0x1C05` `0x1C06` `0x1C07` `0x1C08` `0x1C09` `0x1C0A` `0x1C0E` `0x1C18` `0x1C19` `0x2002` `0x2009` `0x2011` `0x2013` `0x2018` `0x201A` `0x201B` `0x201C` `0x203E` `0x2402` `0x240B` `0x240E` `0x240F` `0x2427` `0x2428` `0x2429` `0x242A` `0x2434` `0x2435` `0x2438` `0x243C` `0x243D` `0x2445` `0x2447` `0x2448` `0x2449` `0x244A` `0x244E` `0x244F` `0x2450` `0x2451` `0x2452` `0x2457` `0x245A` `0x245C` `0x245D` `0x245F` `0x3001` `0x3002` `0x3004` `0x300A` `0x300C` `0x3011` `0x3014` `0x3016` `0x301A` `0x3021` `0x302D` `0x304B` `0x3C0A` `0x3C0B` `0x4026` `0x4401` `0x441E` `0x4804` `0x4814` `0x481E` `0x481F` `0x4828` `0x4829` `0x482C` `0x5008` `0x500B` `0x583A` `0x900C` `0x900D` `0x9010` `0xBC04`

#### `26_11_16_37b_char-select-rename-refusals`

3886 packets. Opcode types on server links: 157.

- **login C→S** (4): `0x0C04` `0x0C0B` `0x0C5A` `0x0C65`
- **login S→C** (5): `0x0807` `0x0C05` `0x0C0A` `0x0C0C` `0x0C67`
- **wm C→S** (18): `0x0805` `0x080D` `0x0C0F` `0x0C18` `0x0C1F` `0x1001` `0x1111` `0x1401` `0x140F` `0x581B` `0x7004` `0x700C` `0x7011` `0x7015` `0x7016` `0x703B` `0x7C06` `0xB409`
- **wm S→C** (25): `0x0804` `0x0807` `0x080E` `0x0849` `0x0C14` `0x1002` `0x1003` `0x1012` `0x1097` `0x10D9` `0x1110` `0x1404` `0x1410` `0x182A` `0x581C` `0x581D` `0x5826` `0x7005` `0x700D` `0x7032` `0x7033` `0x7034` `0x7C07` `0x9414` `0xB40C`
- **zone C→S** (10): `0x0C18` `0x1071` `0x1801` `0x1803` `0x2001` `0x200B` `0x2012` `0x2019` `0x3020` `0x302C`
- **zone S→C** (45): `0x0807` `0x1035` `0x1038` `0x1039` `0x103A` `0x103B` `0x103D` `0x103E` `0x1047` `0x1048` `0x1049` `0x104A` `0x105B` `0x10C6` `0x10CE` `0x10D4` `0x10D7` `0x10DE` `0x10E4` `0x10E7` `0x10EA` `0x1123` `0x1802` `0x1827` `0x182B` `0x1C04` `0x1C05` `0x1C09` `0x1C0E` `0x1C18` `0x2011` `0x2018` `0x203E` `0x240E` `0x240F` `0x2428` `0x2429` `0x242A` `0x245F` `0x3021` `0x302D` `0x441E` `0x482C` `0x583A` `0x9010`

#### `26_11_16_38_session-loss-kicks-char-select`

11976 packets. Opcode types on server links: 153.

- **login C→S** (7): `0x0C04` `0x0C0B` `0x0C18` `0x0C1B` `0x0C37` `0x0C5A` `0x0C65`
- **login S→C** (6): `0x0807` `0x0C05` `0x0C0A` `0x0C0C` `0x0C1C` `0x0C67`
- **wm C→S** (15): `0x0805` `0x080D` `0x0C0F` `0x0C18` `0x0C1F` `0x0C33` `0x1001` `0x581B` `0x7004` `0x700C` `0x7011` `0x7015` `0x7016` `0x703B` `0x7C06`
- **wm S→C** (24): `0x0804` `0x0807` `0x080E` `0x0849` `0x0C14` `0x0C34` `0x1002` `0x1003` `0x1012` `0x1097` `0x10D9` `0x182A` `0x581C` `0x581D` `0x581F` `0x5824` `0x5826` `0x7005` `0x700D` `0x7032` `0x7033` `0x7034` `0x7C07` `0x9414`
- **zone C→S** (11): `0x0805` `0x0C18` `0x1071` `0x1801` `0x1803` `0x2001` `0x200B` `0x2012` `0x2019` `0x3020` `0x302C`
- **zone S→C** (52): `0x0804` `0x0807` `0x1033` `0x1035` `0x1038` `0x1039` `0x103A` `0x103B` `0x103D` `0x103E` `0x1047` `0x1048` `0x1049` `0x104A` `0x105B` `0x10C6` `0x10CE` `0x10D4` `0x10D7` `0x10DE` `0x10E4` `0x10E7` `0x10EA` `0x1123` `0x1802` `0x1827` `0x182B` `0x1C04` `0x1C05` `0x1C08` `0x1C09` `0x1C0E` `0x1C18` `0x1C19` `0x2002` `0x2011` `0x2018` `0x201A` `0x203E` `0x240E` `0x240F` `0x2428` `0x2429` `0x242A` `0x245F` `0x300A` `0x3021` `0x302D` `0x441E` `0x482C` `0x583A` `0x9010`

#### `26_11_16_46_items-merge-buyback-refusals`

4408 packets. Opcode types on server links: 165.

- **login C→S** (5): `0x0C04` `0x0C0B` `0x0C1B` `0x0C5A` `0x0C65`
- **login S→C** (6): `0x0807` `0x0C05` `0x0C0A` `0x0C0C` `0x0C1C` `0x0C67`
- **wm C→S** (9): `0x0805` `0x080D` `0x0C0F` `0x1001` `0x10DA` `0x581B` `0x7004` `0x700C` `0x7C06`
- **wm S→C** (23): `0x0804` `0x0807` `0x080E` `0x0849` `0x0C14` `0x1003` `0x1012` `0x1097` `0x10D9` `0x182A` `0x2079` `0x581C` `0x581D` `0x581E` `0x5825` `0x5826` `0x7005` `0x700D` `0x7032` `0x7033` `0x7034` `0x7C07` `0x9414`
- **zone C→S** (21): `0x0805` `0x1801` `0x1803` `0x2001` `0x200A` `0x200B` `0x2012` `0x2019` `0x201D` `0x2401` `0x2408` `0x3003` `0x3006` `0x300B` `0x301C` `0x301E` `0x3020` `0x302C` `0x304D` `0x3059` `0x5001`
- **zone S→C** (68): `0x0804` `0x0807` `0x1033` `0x1035` `0x1038` `0x1039` `0x103A` `0x103B` `0x103D` `0x103E` `0x1047` `0x1048` `0x1049` `0x104A` `0x105B` `0x106F` `0x10C6` `0x10CE` `0x10D4` `0x10D7` `0x10DE` `0x10E4` `0x10E7` `0x10EA` `0x1123` `0x1802` `0x1827` `0x182B` `0x1C04` `0x1C08` `0x1C09` `0x1C0E` `0x1C18` `0x2002` `0x2011` `0x2018` `0x201A` `0x201C` `0x203E` `0x2402` `0x240E` `0x240F` `0x2428` `0x2429` `0x242A` `0x243D` `0x245F` `0x3001` `0x3004` `0x3005` `0x300C` `0x301D` `0x301F` `0x3021` `0x302D` `0x305A` `0x305C` `0x305D` `0x3C05` `0x3C08` `0x3C09` `0x4401` `0x441E` `0x482C` `0x5003` `0x583A` `0x9010` `0xBC04`

## 2. Per feature area

"Types" = distinct client-facing opcode types captured in the area's department(s) against all types of that
department in `opcodes.json`. The second number includes server-internal opcodes, so it is an upper bound and not a
target. Scenario numbers refer to CS §3.

| Feature area | Verdict | Evidence | What is missing |
|---|---|---|---|
| Transport: framing, cipher, seed, heartbeat | covered | all captures; CV §2 | – |
| Login: password, version check, world list | covered | `login-logout`, s37; CV §3, §16 | Netmarble / Outspark logins have no sender in the 2016 client (CS §5) |
| Login refusals | covered | wrong password, duplicate login kick, blocked, not login-able, world closed, world full (`login-errors`, s37) | scenario 37 steps 3–6 with setups S10, S11, X6 "where s37 did not reach them" (CS §2 rank 1) |
| World select, token return to the world list | covered | `login-logout`, `idle_in_world`; CV §3.1, §4.1 | "wrong world" of capture-guide scenario 2 |
| Character list | covered | every capture with a WM stream | load blocks of a character with guild, pet or house (CS §2 note on 37) |
| Character create / delete | covered | `create-char`, s37, s37b (refusal: name taken) | – |
| Character rename (free and by right) | partly | s37b; CV §22.3–§22.4 | recorded against the 2018 `p_Char_Rename`, not the 2016 one (setup S20, scenario 52) |
| Map entry (zone login burst) | covered | 13 captures; CV §5 | the tail after the title block for a character with pets, raid, charged effects |
| Map change (town portal, link portal) | covered | `walk-run-portals`, combat, s24; CV §6, §7.5 | – |
| Logout, back to character select, session loss, kicks | covered | `idle_in_world`, s38; CV §5.4, §23 | zone-initiated kick with a real user number, stale tutorial copy (scenario 52) |
| Movement (own) | covered | `walk-run-portals`; CV §6 | – |
| Sight: other players and mobs entering / leaving | covered | s14; CV §18 | walk, sit, emote stop relays (scenario 45) |
| Chat | partly | normal, shout, whisper (s14; CV §10.4, §18.4) | party, guild, megaphone chat (scenarios 15, 18, 36) |
| Combat: basic attack, kills, exp, level-up | covered | shop, combat; CV §9 | – |
| Combat: death and revive | partly | combat, s24 (revive by skill) | death penalty, PK, revive item, knock-back (scenario 39) |
| Skills, abstates, stat points, empower | partly | s24; CV §24–§25 | empower wrap, toggle steps, heals on another player (scenario 51) |
| Items: inventory, drop, pick-up, use, equip | covered | shop, s21, s46; CV §8, §19 | s46 not validated |
| NPC shop, buy-back | covered | shop, s21, s46; CV §20.2 | s46 not validated |
| Storage | covered | shop, s21, s46; CV §20.1 | guild storage (scenario 18) |
| Soul stones | covered | shop, s21, s24, s46: 10 of 12 types of dept 20 | – |
| NPC menus | partly | 7 of 15 types of dept 15; CV §10.5 | – |
| Mover (dept 51) | partly | combat only; CV §10.7 | mounts (scenario 26) |
| GM commands | partly | those used as setup: `&adminlevel`, `&levelup`, `&makeitem`, `&getmoney`, `&cleariv`, `&hide`, `&show`, `&dimension`, `&linkto`, `&sethp`, `&setabstate`, … | a GM session of its own (scenario 32) |
| Quests | not covered | only the login state (`0x4401`, `0x441E`) and one NPC quest dialog (CV §10.5) | scenario 23 |
| Kingdom Quest | not covered | only the schedule pushes at login (9 of 60 types of dept 22; "only the WM minute skips are captured", CS §2) | scenario 30 |
| Upgrade, gems, random options | not covered | – | scenario 22 |
| Party | not covered | no packet of dept 14 | scenario 15 |
| Raid | not covered | no packet of dept 44 | scenario 16 |
| Friends, character titles | not covered | no packet of dept 21 (titles: only the login block, CV §10.3) | scenario 17 |
| Guild, guild storage, guild academy | not covered | no packet of dept 29 / 38 | scenarios 18, 19 |
| Trade, booth | not covered | no packet of dept 19 / 26 | scenario 20 |
| Pet | not covered | no packet of dept 53 | scenario 25 |
| Mounts, minimon | not covered | – | scenario 26 |
| Wing stone, silver wing | not covered | – | scenario 27 |
| Mini-house | not covered | no packet of dept 35 | scenario 28 |
| Wedding | not covered | – | scenario 29 |
| Instance dungeon | not covered | no packet of dept 41 | scenario 31 |
| Prison | not covered | only the login state (2 types of dept 31) | scenario 33 |
| Premium inventory, charged buffs | not covered | only the login state (3 of 17 types of dept 36) | scenario 34 |
| Dice, gamble house, card collection | not covered | no packet of dept 43 / 49; dept 47: 2 types | scenario 35 |
| Block list, reports, options, megaphone | not covered | option pushes at login only | scenario 36 |
| Gathering, production, tutorial, attendance | not covered | tutorial popup seen once (CV §18.7) | scenario 40 |
| Holy promise | not covered | only the login state (1 of 47 types of dept 37) | scenario 44 |
| Guild tournament | not covered | – | no scenario; reachable only by schedule or OPTool (CS §5) |

### Captured client-facing opcode types per department

| Dept | Name prefix | Captured | In `opcodes.json` | Captures |
|---|---|---|---|---|
| 0 | ? | 0 | 21 |  |
| 1 | LOG | 0 | 183 |  |
| 2 | MISC | 7 | 83 | buy create-char idle_in_world login-errors login-logout s14 s21 s21b s21c s21d s24 s37 s37b s38 s46 travel walk-run-portals |
| 3 | USER | 19 | 72 | buy create-char idle_in_world login-errors login-logout s14 s21 s21b s21c s21d s24 s37 s37b s38 s46 travel walk-run-portals |
| 4 | CHAR | 42 | 229 | buy idle_in_world s14 s21 s21b s21c s21d s24 s37b s38 s46 travel walk-run-portals |
| 5 | AVATAR | 7 | 22 | create-char s14 s37 s37b |
| 6 | MAP | 11 | 35 | buy idle_in_world s14 s21 s21b s21c s21d s24 s37b s38 s46 travel walk-run-portals |
| 7 | BRIEFINFO | 14 | 26 | buy idle_in_world s14 s21 s21b s21c s21d s24 s37b s38 s46 travel walk-run-portals |
| 8 | ACT | 29 | 111 | buy idle_in_world s14 s21 s21b s21c s21d s24 s37b s38 s46 travel walk-run-portals |
| 9 | BAT | 38 | 59 | buy idle_in_world s14 s21 s21b s21c s21d s24 s37b s38 s46 travel walk-run-portals |
| 10 | OPTOOL | 0 | 44 |  |
| 12 | ITEM | 38 | 108 | buy idle_in_world s14 s21 s21b s21c s21d s24 s37b s38 s46 travel walk-run-portals |
| 13 | ITEMDB | 0 | 202 |  |
| 14 | PARTY | 0 | 48 |  |
| 15 | MENU | 7 | 15 | buy s21 s21b s21d s24 s46 travel walk-run-portals |
| 16 | CHARSAVE | 2 | 47 | buy s24 |
| 17 | QUEST | 2 | 32 | buy idle_in_world s14 s21 s21b s21c s21d s24 s37b s38 s46 travel walk-run-portals |
| 18 | SKILL | 11 | 32 | buy idle_in_world s14 s21 s21b s21c s21d s24 s37b s38 s46 travel walk-run-portals |
| 19 | TRADE | 0 | 35 |  |
| 20 | SOULSTONE | 10 | 12 | buy s21 s24 s46 |
| 21 | FRIEND | 0 | 31 |  |
| 22 | KQ | 9 | 60 | buy idle_in_world s14 s21 s21b s21c s21d s24 s37b s38 s46 travel walk-run-portals |
| 23 | WT | 0 | 12 |  |
| 24 | CT | 1 | 9 | s21 |
| 25 | ANNOUNCE | 1 | 2 | s21 |
| 26 | BOOTH | 0 | 23 |  |
| 27 | SCENARIO | 0 | 33 |  |
| 28 | CHAR | 13 | 72 | buy idle_in_world s14 s21 s21b s21c s21d s24 s37b s38 s46 travel walk-run-portals |
| 29 | GUILD | 0 | 244 |  |
| 31 | PRISON | 2 | 20 | buy idle_in_world s14 s21 s21b s21c s21d s24 s37b s38 s46 travel walk-run-portals |
| 32 | REPORT | 0 | 13 |  |
| 35 | MINIHOUSE | 0 | 88 |  |
| 36 | CHARGED | 3 | 17 | buy idle_in_world s14 s21 s21b s21c s21d s24 s37b s38 s46 travel walk-run-portals |
| 37 | HOLY | 1 | 47 | buy idle_in_world s14 s21 s21b s21c s21d s24 s37b s38 s46 travel walk-run-portals |
| 38 | GUILD | 0 | 142 |  |
| 40 | PROMOTION | 0 | 6 |  |
| 41 | INSTANCE | 0 | 33 |  |
| 42 | CHAT | 0 | 14 |  |
| 43 | DICE | 0 | 42 |  |
| 44 | RAID | 0 | 67 |  |
| 45 | USER | 2 | 11 | s37b |
| 47 | GAMBLE | 2 | 79 | buy s21 s24 s46 |
| 48 | ? | 0 | 1 |  |
| 49 | COLLECT | 0 | 20 |  |
| 50 | SYSLOG | 0 | 19 |  |
| 51 | MOVER | 5 | 16 | travel |
| 52 | EVENT | 0 | 13 |  |
| 53 | PET | 0 | 19 |  |
| 59 | ? | 0 | 1 |  |
| 63 | ? | 0 | 2 |  |

## 3. Scenarios planned but not captured

From the order table of CS §2 (ranked for the rebuild), minus what is recorded. Scenario 46 is listed there at rank 4
as open, but its capture now exists.

**Recorded:** 14, 21 (with S13, S16, X3), 24, 37 (two runs), 38, 46. Of the first list in `capture-guide.md`, scenarios
1, 3, 4, 5, 7, 8 and 13 are recorded; 2 lacks "wrong world"; 6 lacks party chat.

**Before the rebuild starts** (CS §2 ranks 1–3):

| # | Scenario | Needs |
|---|---|---|
| 37 (rest) | login refusals, steps 3–6 not yet run | DB / config setup S10, S11, X6 |
| 52 | character select and session II | GM, 2 clients, setup S20, zone restart |
| 51 | skills II | GM, 2 clients, setup S21 |

**Early, core gameplay** (ranks 5–12): 39 combat extras, 45 second client II, 36 block list / reports / options /
megaphone, 23 quests and class change, 22 upgrades, 15 party, 17 friends and titles, 20 trade and booth.

**With its feature** (ranks 13–28): 18 guild, 19 guild academy, 16 raid, 25 pet, 26 mounts, 27 wing stone,
34 premium inventory, 40 gathering / production / tutorial / attendance, 32 GM commands, 28 mini-house,
35 dice / gamble / cards, 31 instance dungeon, 30 Kingdom Quest, 29 wedding, 44 holy promise, 33 prison.

**Optional** (ranks 29–33): 41 crafted client packets (test client), 42 races, 43 OPTool, 49 and 47 items with the DB
changed under an online player.

**Dropped** (original processes only): 48 WM stop and start, 50 timing.

Capture-guide scenarios 9 (upgrade), 10 (trade, booth), 11 (party, guild) and 12 (quest) are the same gaps as
22, 20, 15 / 18 and 23.

## 4. Fields that cannot be compared byte for byte

Each row names where the value comes from. "Deterministic if" tells what a replay harness can do instead of masking.

### 4.1 Session values

| Field | Why it differs | Source | Replay |
|---|---|---|---|
| `0x0807` seed, all three servers | Login and WM: counter started at `rand()` after `srand(time)`, +1 per connection, mod 499. Zone: global counter per process, first connection = 1 | CV §2.3 | take the seed from the replayed server, never from the capture; the client → server bytes must be decrypted before comparing |
| `0x0C0C.validate` (32 words), forwarded as `0x0C0D` | 31 words of `rand()`, word 32 = per-world counter XOR all others | CV §3.3 | mask; check only that the client echoes it |
| `0x0C34` token (32 hex characters), echoed in `0x0C37` | one-time token made by the Login | CV §3.1, §3.2 | mask; check the echo |
| WM address in `0x0C0C` | configuration (`ServerInfo.txt`) | CV §16.3 | substitute |
| Player handle (`0x1802.charhandle` and every packet that names the player) | pool 8000…9499, next index, freed ones not reused at once | CV §5.3 | map handles capture → replay, or fix the allocator order |
| Mob, NPC and drop handles | assigned at spawn by the zone process | CV §6.3, §19.4 | map handles; deterministic only with the same spawn order |
| Repurchase `nHandle` in `0x305C` | counter, freed values not reused at once | CV §20.2 | deterministic within one session |
| Item keys in inventory and item packets | assigned when the item is created | CV §19 *(inferred from the DB snapshots next to s21)* | map keys |
| Character and user numbers | database identity | CV §7.5 | fixed by a seeded test database |

### 4.2 Clock values

| Field | Source |
|---|---|
| `0x080E {hour, minute, second}` game time | CV §4.1 |
| `0x441E` quest reset instants (start of the current year, month, week, day in server local time) | CV §5.3 |
| `savetime` of skill saves = wall clock of the send (server link) | CV §24 |
| `0x10D2` `dRestExpLastExecuteTime` and other stored timestamps (KQ date, item end times) | CS §5, CV §21.2 |
| Kingdom Quest schedule pushes (dept 22): depend on the minute of the login | CS §2 rank 25 |
| Heartbeat `0x0804`: 30 s after the last one, so its position between other packets moves | CV §2.4 |
| Packet spacing in general (server ticks of about 15.6 ms, Nagle grouping) | CV §5.3, §7.4 |

A replay needs an injected clock, and it must compare packet order per connection, not timing.

### 4.3 Random game values

| Field | Source |
|---|---|
| Damage, hit / miss and critical flags in the damage packets | CV §9.2 |
| Mob movement: targets and times of `0x2018` / `0x201A` | CV §6.1 |
| Drops and random item options | CV §9.3, §19 |
| Sight order: which objects appear first in the login burst | CV §5.1 |

The s24 capture pins damage with `&staticdamage 1` (notes file). Without such a switch the harness needs a seeded
random source or must compare the packet shape only.

### 4.4 Uninitialised or stale bytes (original bugs)

These bytes are memory content of the original process. No rebuild can reproduce them and the client ignores them
(per the cited rows), so they must be masked.

| Packet | Bytes | Bug ID | Source |
|---|---|---|---|
| Character list entry (`0x0C14`) `delinfo` +0x28…+0x2B | pointer-like values, differ per list | P02-B1 | CV §4.3 |
| `0x1802` and `0x240C` `Wizdom` (+0x30) | stale text bytes | Z07-B7 | CV §5.3, §9.4 |
| `0x302D` | one byte after the records | P02-B3 | CV §5.3 |
| `0x10E4` `chrregnum` | stale, differs per login | Z18-B19 | CV §5.2 |
| `0x1C05` `nSlotNum` | stale | Z18-B10 | CV §5.2 |
| `0x2018` / `0x201A` `moveattr` of mob moves | stale buffer text, bit 0 cleared | Z02-B2 | CV §6.3 |
| `0x2452` (skill damage) second flag byte, bits 3–7 | stack bits | P02-B19 | CV §9.2, §9.7 |
| `0x305C` | 100 of 105 bytes stale | P02-B16 | CV §8.2, §20.2 |
| `0x3C08` | one stale byte at the end | – | CV §8.1 |
| `0x0C0C` with status 0 (world closed) | 64 bytes of `validate` never written | P02-B23 | CV §16.3 |
| `0xB40C` slot byte on every code but success | stack garbage | P02-B34 | CV §22.4 |
| `0x100B`, `0x10EC` | 4 extra bytes; `AttendanceArray` uninitialised | P02-B8, P02-B9 | CV §13 |

The full register is CV §12 and the X01 bug register; this table lists only client-facing packets that a capture
showed.

### 4.5 What stays comparable

Everything else in the Login and WM flows of milestone 1 is a function of the database content and the configuration:
with the same accounts, characters and `ServerInfo` values, the packets match apart from the fields of §4.1 and the
`delinfo` bytes.

## Not verified

- **s46** is decoded here for its opcode set only. No one has checked its fields against the documents.
- **Item keys** (§4.1) and the **sight order** (§4.3) are inferred; the validation document does not state them as
  findings.
- The department totals of §2 include server-internal opcodes. A count of client-facing opcodes per department does
  not exist in the repository.
- The feature verdicts for areas that share a department (mounts, wing stone, wedding, gathering) rest on the
  scenario table of CS §2, not on an opcode count.
- The list of GM commands seen is taken from the notes files, not from a search of the decoded chat packets.
