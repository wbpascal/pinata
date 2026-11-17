# Inventory: client data tables versus server-only files

Research for issue #4. Local sources only. Paths are relative to the repo root; `S/` = `Files/Server/2016/`,
`C/` = `Files/Client/2016/ressystem/`.

Evidence tags: **[tree]** = file listing and SHA-1/MD5 comparison of the two trees (done for this note);
**[str]** = path string in `re-data/exports/<bin>/strings.tsv`; a doc reference (`Z01 §2.3`) = read in the
reconstructed pseudocode / knowledge of that item.

## 1. Answer in short

- The client and the server share **114 SHN table names**; **103 are byte-identical**, 11 differ (§3.3). The
  server has 105 SHN names the client lacks, the client 83 the server lacks. [tree]
- The client is **checksummed on exactly 49 SHN files**: it sends their MD5 (hex text, 32 chars each) in
  `0x1801 NC_MAP_LOGIN_REQ`; the zone compares them with the MD5 of its own copy and answers `0x1804` code
  `0x147` + table index on the first mismatch, then disconnects (Z01 §5.2, W05 §3.4). All 49 exist in both trees
  and are byte-identical. [tree] No other file is checked against the client.
- Besides SHN, the only shared files are the 11 `AbState/*.dat` files (identical in both trees [tree]); no 2016
  server exe names them [str], so the server copy is unused.
- Everything else under `S/` is server-only: the `*ServerInfo.txt` config scripts, `World/*.txt` and the other
  text tables, Lua and `.ps` scripts, block-info and area bitmaps. The client tree here contains only
  `Fiesta.bin` and `ressystem/` (no map resources), so a client counterpart of the collision files cannot be
  checked locally (§6).
- Topology: nearly every entry of `ServerInfo.txt` is derivable in a one-node rebuild; what must stay
  configured is the client-facing listen address and port per part, the world number and name, the database URL,
  and (if more than one zone) the map-to-zone split (§5).

## 2. Files the client reads or has checksummed

### 2.1 The 49 checksummed tables (client data tables in the strict sense)

List and order from `CShnDataFileCheckSum` (W05 §3.4; same list in the zone, `FUN_00631450`); the index is the
position in the client's `shnChecksum[49][32]` array of `0x1801` (Z01 §5.2).

| Idx | Files (`.shn`) | Server dir |
|---|---|---|
| 0–22 | Abstate, ActiveSkill, CharacterTitleData, ChargedEffect, ClassName, Gather, GradeItemOption, ItemDismantle, ItemInfo, MapInfo, MiniHouse, MiniHouseFurniture, MiniHouseObjAni, MobInfo, PassiveSkill, Riding, SubAbstate, UpgradeInfo, WeaponAttrib, WeaponTitleData, MiniHouseFurnitureObjEffect, MiniHouseEndure, DiceDividind | `S/9Data/Shine/` |
| 23–25 | ActionViewInfo, MapLinkPoint, MapWayPoint | `S/9Data/Shine/` (ActionViewInfo also in `View/`, same bytes) |
| 26–39 | AbStateView, ActiveSkillView, CharacterTitleStateView, EffectViewInfo, ItemShopView, ItemViewInfo, MapViewInfo, MobViewInfo, NPCViewInfo, PassiveSkillView, ProduceView, CollectCardView, GTIView, ItemViewEquipTypeInfo | `S/9Data/Shine/View/` |
| 40–48 | SingleData, MarketSearchInfo, ItemMoney, PupMain, ChatColor, TermExtendMatch, MinimonInfo, MinimonAutoUseItem, ChargedDeletableBuff | `S/9Data/Shine/` |

- Format SHN; content: tabular game data. All 49: one client copy in `C/` (flat), MD5 equal to the server copy.
  [tree]
- The 14 `View/` tables of the list are loaded by the zone **only to hash them** (Z01 §2.3 row "checksum only,
  FUN_006311a0"); the server uses none of their content. The zone refuses to start when one of the 49 was not
  loaded (`Fail to read SHN Data File. <name>`, Z10 §7.2 D7).
- The hash is over the whole file as stored (still enciphered), so a rebuild must hash the client's file
  unchanged; it cannot re-serialise these tables *(inferred from MD5 of server file = MD5 of client file being
  the passing condition)*.
- The same list is linked into WM, Account, AccountLog, Character and GameLog as part of the shared SHN reader
  [str], but only the zone compares (W05 §3.4: "What uses it in the WM: nothing").

### 2.2 Other tables both sides hold (not checksummed)

65 more SHN names exist in both trees (114 − 49). 54 are byte-identical, 11 differ (§3.3). They are tables both
programs read independently (e.g. `QuestData`, `FaceInfo`, `HairInfo`, `HairColorInfo`, `ItemMix`, `Produce`,
`MoverMain`, `KQTeam`, `GuildTournamentRequire`, `BadNameFilter`, `AttendReward`, `SetEffect`). The server never
verifies the client's copy, but a divergence changes what the client displays or pre-validates, so they belong
to the "client data table" class as well: source of truth = the client's file.

| Family | Format | Read by (server) | Client counterpart | Content |
|---|---|---|---|---|
| 49 checksummed tables (§2.1) | SHN | Zone (all 49); WM `SingleData`; Character `ItemInfo`, `MapInfo`; GameLog `ItemInfo`, `MapInfo` [str]; D08 §2.2, §4.5 | yes, identical, MD5-checked at map login | tabular game data |
| 65 other shared tables | SHN | Zone mostly (Z01 §2.3); WM: `KingdomQuest`, `KQIsVote`, `KQTeam`, `KQVoteMajorityRate`, `GuildGradeData`, `GuildTournamentRequire`, `GBHouse`, `BadNameFilter`, `AttendReward`, `UseClassTypeInfo` (W05 §3.2); Character: `FaceInfo`, `HairInfo`, `HairColorInfo`, `AttendReward` [str] | yes; 54 identical, 11 differ | tabular game data |
| `AbState/*.dat` (11 files) | binary `.dat` | no 2016 server exe names them [str] | yes, identical [tree]; client reads `%sAction\%s.dat`-style paths [str] | client effect data; dead weight on the server |

Account and AccountLog carry `MapInfo.shn` / `ItemInfo.shn` path strings [str], but only the Character server
loads game data among the DB servers (D08 §2.2 "loaded by the Character server only", §4.5).

## 3. SHN tables: the three sets

Counts from the tree comparison: server 220 files / 219 names (199 in `Shine/`, 21 in `Shine/View/`,
`ActionViewInfo` twice), client 198 files (flat, plus `AmbienceSound/`), 114 names in both.

### 3.1 Server-only SHN (105 names)

Format SHN; tabular game data and tuning values; no client file. Readers: zone unless noted (Z01 §2.3).

| Group | Tables |
|---|---|
| `*Server` halves of client tables | ActiveSkillInfoServer, ItemInfoServer (client has a stale copy, §3.3), MobInfoServer, MobConditionServer, CharacterTitleStateServer, MysteryVaultServer, PupServer, GTIServer, ItemServerEquipTypeInfo |
| Rates and tuning | DamageLvGapEVP/PVE/PVP, PartyBonusByLvDiff/ByMember/Limit, EnchantSocketRate, RandomOptionCount, RareMoverRate/EachRate/SubRate, CollectCardDropRate/MobGroup/StarRate, DiceRate, DiceGame, BelongDice, MultiHitType, ActionRangeFactor, AccUpgrade, AccUpGradeInfo, BRAccUpgrade, LCGroupRate, LCReward, GTIGetRate, GTIGetRateGap, GTIBreedSubject, GTWinScore |
| Mobs and maps | MobAbStateDropSetting, MobAutoAction, MobKillAble, MobKillAnnounce, MobKillLog, MobLifeTime, MobRegenAni, MobResist, MapBuff, StateField, StateItem, StateMob, AreaSkill, BMP, GroupAbState, AbStateSaveTypeInfo, ActionEffectAbState, NpcSchedule |
| Items | ItemDropLog, ItemInvenDel, ItemMerchantInfo, ItemOptions, ItemPackage, ItemSort, JobEquipInfo, KQItem |
| Gambling house | GBBanTime, GBDiceGame, GBDiceRate, GBEventCode, GBExchangeMaxCoin, GBJoinGameMember, GBReward, GBTaxRate, GBSMAll/BetCoin/CardRate/Center/Group/JPRate/Line/NPC |
| Guild (WM reads the first seven, W05 §3.2) | GuildAcademy, GuildAcademyLevelUp, GuildAcademyRank, GuildGradeScoreData, GuildLevelScoreData, GuildTournament, GuildTournamentReward; zone: GuildTournamentLvGap/MasterBuff/Occupy/Score |
| Kingdom quest (WM) | KingdomQuestMap, KingdomQuestRew (zone), MsgWorldManager |
| Operations | AdminLvSet, SpamerPenalty, SpamerPenaltyRule, SpamerReport (WM), AttendSchedule (WM), FriendPointReward, HolyPromiseReward (Character [str]) |
| Pet AI | PupCase, PupCaseDesc, PupFactorCondition, PupMind, PupPriority |
| Quest | QuestScript |

Of these 105 names only `AccUpGradeInfo.shn` appears as a string in the client exe [str]; the client would not
find the file in this install.

### 3.2 Client-only SHN (83 names + `ItemInfo.shn_bad`)

Texts (`TextData`, `TextData2`, `TextData3`, `ScriptMsg`, `NpcDialogData`, `AbStateMsg`, `FaceCutMsg`,
`BasicInfo*`, `*Desc`), presentation (`AmbienceSound/*` 44 files, `DamageEffect`, `DamageSoundInfo`, `UpEffect`,
`FontSet`, `WorldMapAvatarInfo`, `MobCoordinate`, `MobRandomIdleAni`, `MoverSlotCharAni`, `ActionEffectInfo`),
character-creation defaults (`ChrBasicEquip`, `ChrCreateEquip`), filters (`SlanderFilter`, `EmotionFilter`),
and a few others (`ChargedIconItem`, `ChargedMessageItem`, `SetItemName`, `MHEmotion`, `WPConfig`,
`TermExtendMatchGroupDesc`, `KQVoteDesc`, `KingdomQuestDesc`, `GuildTournamentSkillDesc`,
`MobKillAnnounceText`, `ItemActionEffectDesc`). The rebuild needs them only as look-ups for tests and tooling
(error texts: `tools/protocol-re/errcodes.py`). Note `ChrCreateEquip` / `ChrBasicEquip` are the client's view
of what the Character server takes from `DefaultCharacterData.txt` (§4).

### 3.3 Same name, different bytes (11)

| Table | Server / client bytes | Named in zone exe | Named in client exe | Note |
|---|---|---|---|---|
| CollectCardGroupDesc | 13254 / 16054 | no | yes | client text table; server copy unused by the zone |
| ColorInfo | 744 / 771 | no | yes | same |
| MoverSlotView | 17824 / 18112 | no | yes | `View/`, same |
| MoverView | 111336 / 112304 | no | yes | `View/`, same |
| QuestDialog | 1987801 / 2893884 | no | yes | same |
| KingdomQuest | 12386 / 13660 | no (WM reads it, W05 §3.2) | no string found | both sides may use it: the only real divergence risk |
| FieldLvCondition | 3236 / 2676 | yes | no | client copy is a leftover |
| ItemInfoServer | 3358540 / 3334124 | yes | no | client copy is a leftover |
| ItemUpgrade | 1540 / 2692 | yes | no | same |
| ReactionType | 262 / 346 | yes | no | same |
| ShineReward | 30528 / 30528 | yes | no | same size, different content |

"Named in exe" is a plain string search in `strings.tsv`; a table loaded through a built name would be missed.
The pattern is consistent: for 10 of 11 only one side reads the file, so the other side's copy is stale. Rule
for the rebuild: take the **client's** file where the client reads the table, the **server's** where only the
server does; `KingdomQuest.shn` needs a column-level diff before the Kingdom Quest milestone.
`GBHouse.shn` exists twice on the client (`C/GBHouse.shn` identical to the server's, and an unrelated
`C/AmbienceSound/GBHouse.shn`).

## 4. Server-only files (no client counterpart)

Counts from [tree]. "Reader" from the cited doc or, where marked [str], from the path string in the exe.

| File or family | Count | Format | Read by | Content | Evidence |
|---|---|---|---|---|---|
| `S/9Data/ServerInfo/ServerInfo.txt` | 1 | CSL config script (`#DEFINE` + rows) | all seven servers, through `#INCLUDE` from their own file | topology: 22 `SERVER_INFO` listener rows, 5 `ODBC_INFO` connection strings, `NATION_NAME`, `WORLD_NAME` | Z19 §3, §5.4; K01 §4.1 |
| `Login/LoginServerInfo.txt`, `w00_WorldManager/WMServerInfo.txt`, `w00_Zone0n/ZoneServerInfo/ZoneServerInfo.txt`, `*/DataServerInfo_*.txt` | 9 | CSL | the server in whose folder it lies | identity: one `MY_SERVER` row (name, display name, server type, world, zone) | Z19 §5.4 |
| `S/9Data/ServerInfo/_ServerGroup.txt` | 1 | one word (`Fiesta`) | zone only | name of the `Field.txt` column that holds the map's zone number | K01 §5.3; Z19 §8 |
| `Login/ClientVersionKeyInfo.txt` | 1 | one line of text | Login | the client version key Login accepts (`Fiesta20151116141627`); the client sends its own in the version check, so this is the one config value that must match the client | `login-server.md` (`versionKeys[5][64]`) [str] |
| `S/9Data/Shine/DefaultCharacterData.txt`, `TutorialCharacterData.txt` | 2 | CSL | Character server | starting stats, items, skills, quests, shortcuts of a new character | Z19 §5.4; D02 §3.3 |
| `S/9Data/Shine/World/Field.txt` | 1 | TXT table (`#Table` / `#ColumnType` / `#ColumnName`) | zone | map list with per-map rules **and** the map-to-zone column; also the `InstanceDungeon` table with its `ZoneNumber` | K01 §5.3; Z01 §2.3 |
| other `S/9Data/Shine/World/*.txt` | 47 | TXT table | zone | tabular game data and tuning: `ChrCommon`, `NPC`, `NPCAction`, `MobChat`, `ItemDropGroup`, `ItemDropTable` (1.4 MB), `RecallCoord`, `DamageByAngle`, `DamageBySoul`, `SubLayerInteract`, `ItemUseFunction`, `TreasureReward`, `MiscDataTable`, `PineScript`, `QuestParser`, 27 `Param<Class>Server` | Z01 §2.3; `Param*Server` names [str] |
| `S/9Data/Shine/MobRegen/` | 126 | TXT table | zone, per map; `KingdomQuest/`, `Instant/` sub-folders | mob spawn groups per map | Z01 §2.3 |
| `S/9Data/Shine/MobRoam/` | 28 | TXT table | zone, per map | roaming paths | Z01 §2.3 |
| `S/9Data/Shine/MobAttackSequence/` | 297 | TXT table | zone | per-mob skill sequences | Z01 §2.3 |
| `S/9Data/Shine/NPCItemList/` | 71 (+1 `.xls`) | TXT table | zone, per NPC | merchant stock | Z01 §2.3 |
| `S/9Data/Shine/Script/` | 51 (+1 `.xls`) | TXT script | zone (`Script/%s.txt` [str]) | NPC / quest dialogue scripts | Z01 §2.3 ("World/Script/%s.txt") |
| `S/9Data/Shine/MobSetting/` | 56 (+1 `.xls`) | TXT | zone (`MobSetting/Action/*.txt` [str]) | mob action settings | [str] only |
| `S/9Data/Shine/LuaScript/` | 404 `.lua`, 2 `.luac` | Lua 5.1 source | zone (`LuaScript/%s.%s`, `AIScript/%s.lua`, `PetSystem/%s.lua`) | scripts: Kingdom Quests, instance dungeons, promotion, tutorial, mob AI, pets | Z01 §2.3; Z09 (`sb_GetFileName`) |
| `S/9Data/Shine/ScenarioBookShelf/` | 46 `.ps` | text script ("PineScript" scenario) | zone (`ScenarioBookShelf/%s.%s` [str]) | older scenario scripts (KQ, quests) | Z09 (`sb_GetFileName`: extension `lua` → `LuaScript/`, else `ScenarioBookShelf/`) |
| `S/9Data/Shine/BlockInfo/*.shbd` | 158 | SHBD (walk-block bitmap) | zone (`BlockInfo/%s.shbd` [str]) | map geometry: walkable cells | [str] |
| `S/9Data/Shine/BlockInfo/*.aid` | 23 | AID | zone (`%s.aid`) | area geometry, e.g. the server's own re-test of positions | Z09 §15 [str] |
| `S/9Data/Shine/BlockInfo/*.sbi`, `*.shab` | 32 + 8 | binary | zone ([str] for both) | sub-layer / attack-block info | [str] only |
| `S/9Data/Shine/AreaBMP/*.bmp` | 52 (+1 `.db`) | 8-bit BMP | zone (`../9Data/%sAreaBMP/%s.bmp`), indexed by `BMP.shn` | skill area shapes | Z31 knowledge (§8.6) |

Files in the tree that **no 2016 exe names** [str] (candidates to drop, see §6): `BlockInfo/*.bdt` (76),
`*.shmd` (2), `*.shad` (1); `MobBehaviorDescript/*.ps` (8); the top-level `AIScript/` folder (4 `.lua`,
2 `.luac`; the zone reads `LuaScript/AIScript/`); `World/ExpRecalculation.txt` ("read by no 2016 binary",
Z29 knowledge); the `.xls` sources (`Field.xls` appears only in an error text); `AreaBMP/*.db`; `.DS_Store`.

## 5. Topology files: what could be computed at start-up

Source rows: `ServerInfo.txt` (shown in K01 §4.1), the nine `MY_SERVER` files, `_ServerGroup.txt`, the zone
column of `World/Field.txt`. The fixed requirements in issue #1 (three parts, one persistence library, OTP
messages between parts) already remove most of them.

| Entry | Original use | In the rebuild |
|---|---|---|
| `MY_SERVER` (name, type, world, zone) per process | tells a process which rows are its own | **computed**: a part knows its role from its supervision tree / node; zone number assigned at start |
| `SERVER_INFO` rows with peer 5 or 6 (Login←WM 9011, WM←zone 9111, zone ring 9218–9221) | server-to-server listeners | **gone**: replaced by OTP messages and the cluster registry |
| `SERVER_INFO` rows of the four DB servers (9000, 9311, 9411, 9511) | DB-server listeners | **gone**: persistence is a library |
| `SERVER_INFO` rows with peer 8 (OPTool 9015, 9115, 9211…) | operator-tool listeners | open (GM / operator tooling is undecided in #1); not needed for milestone 1 |
| `SERVER_INFO` peer 20, Login (9010) | client listener | **configured**: must equal what the client is started with |
| `SERVER_INFO` peer 20, WM (9110) | client listener; Login sends this address in the world-select answer | **configured** bind port; the advertised address is **computed** from the WM part's registration (public host stays configured) |
| `SERVER_INFO` peer 20, zones (9210…9216) | client listener; the WM sends this address in `0x1003` (K01 §5.2) | **computed**: each zone can bind any free port (or a base + zone number) and register it; only the public host name needs configuring. The shipped `0.0.0.0` rows already cannot be advertised as they are (README §2.7 open question) |
| `nBackLog`, `nMaxAccept` | listen backlog, connection cap (200 / 2500 / 1700) | tuning values with defaults, not topology |
| `ODBC_INFO` (5 connection strings incl. password) | SQL Server per database | **configured**, reduced to one database URL (PostgreSQL / SQLite); a secret, so environment / runtime config |
| `NATION_NAME` | region tag | constant or one config value |
| `WORLD_NAME` (number, name `INITIO`, data path) | world identity; name selects `World/<name>/…` overrides (K01 §5.3) | **configured**: world number and name per world (World is first-class); data path derivable |
| `_ServerGroup.txt` (`Fiesta`) | picks the `Field.txt` column holding the zone number | **gone** once the split is not read from a column |
| `Field.txt` zone column (36 / 33 / 45 / 38 maps on zones 0–3, `MHBasic` = 99 "every zone") | static map-to-zone split; zones tell the WM their maps at start (`0x180F`) | **computable**: the WM already learns map → zone at run time (K01 §5.3), so a rebuild can assign maps to running zone parts at start-up (all on one zone in single-node mode, K01 §8) and keep an optional override. The `99` sentinel and the `MHBasic0…3` naming (K01 §6.2) disappear if a mini-house map is simply local to each zone |
| `InstanceDungeon.ZoneNumber` in `Field.txt` | which zone hosts an instance | computable the same way |
| zone-number limits (0–11, contiguous, K01 §5.4) | ring structure | an artefact of the ring; not client-visible *(inferred: no client packet carries the zone number)* |
| `ClientVersionKeyInfo.txt` | accepted client version key | **configured** (per supported client build); not topology |

The other columns of `Field.txt` (map id, size, recall rules, script name, …) are game data and stay.

## 6. Not verified

- **Client map resources.** `Files/Client/2016/` holds only `Fiesta.bin` and `ressystem/`. Whether the client
  ships its own `.shbd` (or other collision data) and whether it matches the server's `BlockInfo/` cannot be
  checked here. The client exe has no `.shbd` / `.aid` / `.sbi` path string and no block file is in the 49-file
  checksum list, so the server does not verify it either way.
- **"No exe names it"** rests on a string search; a path built from parts (as `%s.%s`) would not show. The
  `.bdt`, `.shmd`, `.shad`, `MobBehaviorDescript/`, `MobSetting/` loaders were not read in the decompilation
  for this note.
- **Per-table readers of the 65 shared, non-checksummed tables** were taken from the loader table in Z01 §2.3 and
  from path strings, not re-derived table by table. `World/Quest.txt`, `Karen.txt`, `ItemOptions.txt` and
  `RandomOptionTable.txt` are assumed to go through the generic `World/%s.txt` loader (only `RandomOptionTable`
  and the `Param*Server` names were found as strings).
- **The MD5 input** (whole file as stored) is inferred from the tree comparison plus Z01 §5.2; the hashing
  function itself (`FUN_006311a0`) was not re-read, and no capture was decoded to compare a real `0x1801`
  payload with the file MD5s.
- **`KingdomQuest.shn`**: which side's copy is right was not determined (no column diff done).
- Whether the rebuild **enforces** the checksum is a decision for the "Client integrity checks" point of #1, not
  answered here.

## 7. Sources

- Trees: `Files/Server/2016/` (1736 files under `9Data`), `Files/Client/2016/ressystem/` (853 files); hashes
  computed for this note.
- `docs/pseudocode/zone/Z01-core.md` §2.3 (zone loader table), §5.2 (`0x1801`, `0x1804` code `0x147`)
- `docs/pseudocode/wm/W05-process.md` §3.2 (WM tables), §3.4 (`CShnDataFileCheckSum`, the 49 names)
- `docs/pseudocode/zone/Z19-config-script.md` §3, §5.4 (config scripts per server)
- `docs/pseudocode/zone/Z10-certification.md` §7.2 (stage dependencies, D7)
- `docs/knowledge/K01.md` §4–§6, §8 (topology, `Field.txt`, zone 99), `docs/knowledge/Z10.md` (server IDs)
- `docs/pseudocode/db/D08-db-process.md` §2.2, §4.5 (game data in the DB servers)
- `docs/pseudocode/README.md` §2.7 (deployment limits), `docs/knowledge/Z29.md`, `docs/knowledge/Z31.md`
- `re-data/exports/{login,wm,zone,account,accountlog,character,gamelog,client}/strings.tsv` (path strings)
