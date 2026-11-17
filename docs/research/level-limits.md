# Character level limits in the 2016 client and data tables

Research for issue #6. Local sources only (2016 binaries' Ghidra exports, NA2016 PDBs of the same builds,
2016 data tables, existing reconstruction docs). No capture exists with a level above 150, so nothing here is
runtime-verified; every claim below is read from code or data and cites where.

## Answer

- **Hard ceiling: 255.** The character level is one unsigned byte in every in-game packet the client receives.
  Level 999 is not reachable with the unmodified client; nothing short of a client patch changes that.
- **151 to 255 looks safe for the client.** The client holds no per-level table (experience, stats and
  stat points all arrive from the server as numbers) and contains no check of a level against 150. The only
  `150` constants near a level in the whole client are a level-gap filter in the quest windows.
- **What breaks first above 150 is the original server, not the client**: the zone clamps the level to 150,
  disconnects at login above 150, and sizes its per-level tables at 151 entries. The rebuild is free of all of
  that; it only needs its own per-level data for the new levels.
- **Data-table changes needed: none on the client side.** The per-level tables are server-only text files.
  Client tables only matter for content aimed at the new levels (items, mobs, quests, map gates), and two of
  those (`ItemInfo`, `MobInfo`) are in the 49-file checksum list.
- The 2016 data actually caps play at **125** (`LevelLimit` in `ChrCommon.txt`), with tables filled to 150.

## 1. Level field widths on the wire

Source: structs of the 2016 server PDBs (`Files/Server/NA2016/Zone00/Zone.pdb`,
`WorldManager/WorldManager.pdb`, read with `tools/protocol-re/pdb.py`), evidence level *(pdb2016)*. All
members whose name contains level / lv / lev: 59 are `uchar`, 5 are `ushort`.

| Packet / struct | Field | Type |
|---|---|---|
| `PROTO_NC_CHAR_BASE_CMD` (0x1038, own character at map login) | `Level` @0x19 | u8 |
| `PROTO_NC_BAT_LEVELUP_CMD` | `level` @0 | u8 |
| `PROTO_NC_BRIEFINFO_LOGINCHARACTER_CMD` (other players) | `Level` | u8 |
| `PROTO_NC_BAT_TARGETINFO_CMD` | `targetlevel` @0x1b | u8 |
| `PROTO_PARTY_MEMBER`, `PROTO_PARTY_MEMBER_CLASS`, raid member | `level` | u8 |
| `PROTO_FRIEND_INFO`, `PROTO_NC_FRIEND_LEVEL_CMD` | `level` | u8 |
| `GUILD_MEMBER_CLIENT`, guild academy member, `GUILD_MEMBER_LEVEL_CMD` | `nLevel` / `Level` | u8 |
| `PROTO_HOLY_PROMISE_INFO`, wedding partner info, mini-house visitor | `Level` / `level` | u8 |
| `PROTO_KQ_INFO_CLIENT` | `MinLevel`, `MaxLevel` | u8 |
| `PROTO_NC_ITEM_MAPLINK_SCROLL_ACK` | `lvFrom`, `lvto` | u8 |
| `PROTO_NC_CHAR_LEVEL_CHANGED_CMD` (server-internal) | `CharNewLevel` | u8 |
| `PROTO_AVATARINFORMATION` (character select list) | `level` @0x18 | **u16** |

The other four `ushort` hits are not character levels (`nStoneLevel` of guilds, `nUseMinLv` of the dice game).
So only the character-select entry could carry more than 255; once in game everything is a byte.

Related widths that grow with level:

- Experience: `CHAR_BASE_CMD.Experience` u64; `CHAR_PARAMETER_DATA.PrevExp` / `NextExp` u64 (the client gets
  both bounds of the exp bar from the server); `BAT_EXPGAIN_CMD.expgain` u32 per gain.
- Stats: `SHINE_CHAR_STATVAR {u32 base, u32 change}`; `MaxHp` / `MaxSp` u32.
- Free stat points: `PROTO_NC_CHAR_STAT_REMAINPOINT_CMD.remain` u8, and the spent points per stat are bytes
  (`CHARSTATDISTSTR`, 6 bytes in `CHAR_BASE_CMD`). At most 255 unspent and 255 per stat. The 2016 data gives
  at most 180 points in total at level 150 (StatTable, Gladiator / Knight; per-stat cap `MaxFreeStat` 180,
  `docs/pseudocode/zone/Z12-stats.md` §5.1), so the point curve must stay under 255 per stat above 150.

## 2. Client (`re-data/exports/client`)

- The own level is the byte at `User + 0x47e` (`PROTO_NC_CHAR_BASE_CMD` copied to `User + 0x465` by
  `User::SetMainCharBaseData` FUN_006631f0). Getter `User::Lv` FUN_00661600 returns a byte, setter
  `User::SetLv` FUN_00661610; level-up sets it from the packet (`CharDeadEvent_LevelUp::OnDead` FUN_00610e00).
- No clamp and no comparison of the level against 150. A scan of the whole client decompilation for
  comparisons with 0x95 / 0x96 / 0x97 finds 7 functions, all quest windows (FUN_005fc720, FUN_005fc980,
  FUN_005fcb90, FUN_00603870, FUN_00605a50, `EpicQuestWin::UpDateViewQuestList` FUN_006065e0, FUN_00608810).
  Each tests `playerLevel - questRow[+0x1b] < 151`. The meaning of byte +0x1b (presumably the quest's
  starting level) was not verified. Effect *(inferred)*: for a player above 150, quests whose value is more
  than 150 below the player's level drop out of the available-quest lists (a level 151 player loses the
  level-0 ones, a level 255 player everything below 105). Display only.
- 54 functions call `User::Lv`. None contains a 150 constant other than the quest ones above. They were not
  each read, so an array indexed by level without a constant bound cannot be ruled out.
- No per-level table in `Files/Client/2016/ressystem/`: there is no `ChrCommon`, `Param*` or `StatTable`
  there. Experience bounds and all stats come in `CHAR_PARAMETER_DATA` (0xe8 bytes, also embedded in
  `BAT_LEVELUP_CMD`).
- UI: the level is printed with `%d` (`"%s (Lv %d)"` FUN_004de4e0, `"Level : %d"` FUN_005ff600 / FUN_00603870 /
  FUN_00605100, `Num_Level` text windows FUN_0055fc80 / FUN_00595720). Levels 100 to 150 already use three
  digits and 255 is still three, so no widget needs a fourth digit.

## 3. Original zone server (`re-data/exports/zone-pdb`)

What would break first on the original server. None of it binds the rebuild.

| Where | Behaviour |
|---|---|
| `ShinePlayer::so_GetLevel` FUN_005598a0 | returns the stored level clamped to 1…150 |
| `sp_NC_MAP_LOGINCOMPLETE_CMD` FUN_00443390 | level 0 or above 150 → disconnect (`docs/pseudocode/zone/Z01-core.md` §6) |
| `sp_GainExp` FUN_0042d830 | no experience at or above `levellimit` (`docs/pseudocode/zone/Z03-combat.md` §8.3) |
| `CharClass::cc_Load` FUN_0044a3d0 | loads exactly levels 1…150 of each `Param<Class>Server.txt`, exits if one is missing |
| `ShineCommonParameter::scp_Load` FUN_004c9be0 | `nextexp[151]`, `commonparam[151]` (`docs/pseudocode/zone/Z12-stats.md` §5.1) |
| `MaxExpGainAtGroup::megag_Load` FUN_00481980, `lh4ed_Load` FUN_00481a80 | 151-entry and 301-entry tables (level, level difference ±150) |
| `c_Storepure` FUN_00517b60, `so_fill_CHAR_PARAMETER_DATA` FUN_005a2e00, soul-stone handlers FUN_00588a40 / FUN_00588d20 / FUN_00588e90 / FUN_00589180, `so_charbasedata` FUN_0044d890 | `level < 151` guards before indexing the class table |
| `LevelGap_Player_to_Player::GetLevelCapRate` FUN_005c81c0 | defender level ≥ 150 → rate 1000 |

The Character server and the WorldManager contain no comparison with 150 (same scan over
`re-data/exports/character` and `wm-pdb`: 0 hits). The database column type of the level was not checked; the
rebuild uses a fresh schema.

## 4. Data tables

Server, `Files/Server/2016/9Data/Shine/` (all server-only unless noted):

| Table | Rows / range | Note |
|---|---|---|
| `World/ChrCommon.txt` `Common` | `LevelLimit 125` | the configured cap of the 2016 data |
| `World/ChrCommon.txt` `StatTable` | levels 1…150 | `NextExp` (level 150: 1 469 080 243 062), stat points per class, `ExpLostAtPvP` |
| `World/Param<Class>Server.txt` (27 files) | 150 records each | base stats, HP / SP, stone data per level |
| `PartyBonusLimit.shn` | 151 rows, level 0…150 | exp limit in a party |
| `DamageLvGapPVP.shn` | 151 rows × 150 target columns | all 1000 in 2016 |
| `DamageLvGapPVE.shn`, `DamageLvGapEVP.shn` | 24 rows, gap −150…150 | by level difference |
| `PartyBonusByLvDiff.shn` | 31 rows, gap −150…150 | by level difference |
| `FieldLvCondition.shn` | 74 rows, highest `LvTo` 150 | also in the client's `ressystem`, not checksummed |
| `MobInfo.shn` | 2853 rows, highest `Level` 150 (u32 column) | client copy identical in range; checksummed |
| `ItemInfo.shn` | 15009 rows, highest `DemandLv` 215 (u32 column), `BuyDemandLv` u8 max 117 | client copy same; checksummed |

Client: no per-level table (see §2).

Checksums: the client sends the MD5 of 49 files in 0x1801 `NC_MAP_LOGIN_REQ` and the original zone compares
them with its own copies (mismatch → 0x1804 code 0x147). The list (`CShnDataFileCheckSum` constructor,
`docs/pseudocode/wm/W05-process.md` §3.4): Abstate, ActiveSkill, CharacterTitleData, ChargedEffect, ClassName,
Gather, GradeItemOption, ItemDismantle, ItemInfo, MapInfo, MiniHouse, MiniHouseFurniture, MiniHouseObjAni,
MobInfo, PassiveSkill, Riding, SubAbstate, UpgradeInfo, WeaponAttrib, WeaponTitleData,
MiniHouseFurnitureObjEffect, MiniHouseEndure, DiceDividind, ActionViewInfo, MapLinkPoint, MapWayPoint,
AbStateView, ActiveSkillView, CharacterTitleStateView, EffectViewInfo, ItemShopView, ItemViewInfo, MapViewInfo,
MobViewInfo, NPCViewInfo, PassiveSkillView, ProduceView, CollectCardView, GTIView, ItemViewEquipTypeInfo,
SingleData, MarketSearchInfo, ItemMoney, PupMain, ChatColor, TermExtendMatch, MinimonInfo, MinimonAutoUseItem,
ChargedDeletableBuff. Not in the list: `FieldLvCondition`, `QuestData`, the `TextData` files. The check is
purely server-side (the client only reports hashes), so an edited client table works as long as the server's
expected hash matches it.

## 5. What a level cap above 150 needs

1. Server data for the new levels, in whatever format the rebuild chooses: next-level experience, per-class
   base stats / HP / SP / stones, stat points (within the u8 limits of §1), party exp limit, PvP level-gap
   rows, and level-difference tables that cover gaps beyond ±150.
2. No client file change for the level itself.
3. Optional content for the new levels touches client tables: `ItemInfo` and `MobInfo` (checksummed),
   `FieldLvCondition` and `QuestData` (not checksummed).
4. Cap at 255. Sending a level above 255 is impossible in game; the u16 in the character list would only make
   the select screen disagree with the game.

## Not determined

- Runtime behaviour of the client above 150: no capture, nothing was run.
- Whether any of the 54 `User::Lv` callers indexes a fixed-size array by level without a constant bound.
- The meaning of quest row byte +0x1b in the quest-window gap check, and so the exact quests that disappear.
- Client handling of other players' levels above 150 (name plates, party and guild windows) was checked only
  through the field widths and the 150-constant scan, not function by function.
- Whether skills, titles or other client tables assume a top level through their data rather than code.
