# Game data

**Warning: text columns are raw bytes.** Every text value of a data table (SHN strings, CSV cells) is in the client's legacy code page. It is never converted to UTF-8, it is not valid UTF-8 in general, and printing it or pattern-matching it as an Elixir string looks like corruption. Code that logs or compares such text converts at that point ([ADR 0006](../../../docs/adr/0006-game-data-loaded-once-at-start-up.md)). The import writes the bytes unchanged, so an editor of the CSV files must keep them too.

The boundary `GameData` reads the data directory when a node starts and keeps each table in `persistent_term`. The decisions are in [ADR 0005](../../../docs/adr/0005-server-data-tables-imported-to-csv.md) and ADR 0006; this page describes what is built.

## Data directory

| Path | Content |
|---|---|
| `shn/<Name>.shn`, `shn/View/<Name>.shn` | the SHN tables, byte for byte |
| `tables/…/*.csv` | the server data tables, converted from TXT (below) |
| `LuaScript/`, `Script/`, `ScenarioBookShelf/` | scripts, copied |
| `BlockInfo/`, `AreaBMP/` | geometry, copied; not loaded with the tables, `GameData.BlockData` reads `BlockInfo/` per map |

**File names ignore letter case.** Every file `GameData` opens by a name from a schema, a table or the code goes through `GameData.DataFile.path/2`: per path segment an entry with exactly that name wins, else the first entry of the sorted folder listing that equals it without regard to ASCII letter case, else the name as written (ADR 0006; the data has `linkfield01.shbd`, `linkfield02.shbd` and `wedding.shbd` for the maps `Linkfield01`, `Linkfield02` and `Wedding`). The import does not rename files. Later readers of scripts and other folders must use the same function.

## Geometry files (`BlockInfo/`)

One set of files per map, named after the map. All integers are little-endian `u32`. A cell is 6.25 units wide (8 cells per 50 units); a map is `bytesPerRow × 50` units wide and `rows × 6.25` units high.

| File | Maps (2016 data) | Content | Used by |
|---|---|---|---|
| `<map>.shbd` | 158, every map | Move block bitmap: `bytesPerRow, rows`, then `rows × bytesPerRow` bytes. A set bit is a cell a player cannot stand on. A position outside the map counts as blocked. | The move, stop and pull-back checks of a map instance. Required: a map without it stops the start-up (`Zone.check_maps/1` calls `BlockData.check/2` for every plain field map). |
| `<map>.shab` | 8 | Attack block bitmap, same format. Cells that also block attacks and monster paths. | OR-ed into the move block bitmap at load. Read on its own by monster path finding and fear (milestone 4). |
| `<map>.aid` | 23 | Named areas, no blocking: `n` (at most 256), then per area `char name[32], type`; type 0 is a circle (3 more values), type 1 a rectangle (5 more values, the last an angle in degrees). | Map scripts only. Not read yet. |
| `<map>.sbi` | 32 | Door blocks: `n` (at most 31), then per door `char name[32], x0, y0, x1, y1` (cells; the width is a multiple of 8), `len, offset`; then for every door two images of `len` bytes at `offset`, the closed one first, the open one second. | Closing a door ORs its closed image into that rectangle of the move block bitmap, opening copies the open image over it. Not read yet. |

The shipped `.shbd` files hold every door open: 107 of the 128 door rectangles equal the open image and none equals the closed one. The original server closes all doors when a map loads. Until doors are built, the server leaves them open, because the client is not told about a door either.

### Loader (`GameData.BlockData`)

- `check(data_dir, map_name)`: the `.shbd` exists and its header is well formed (for the node start); the `.shab` is not looked at.
- `load(data_dir, map_name)`: the `.shbd` with the `.shab` OR-ed in; only the merged bitmap is kept (struct `bytes_per_row`, `rows`, `bits`). A missing `.shab` is not an error. `.sbi` and `.aid` are not read. Nothing is cached and nothing logged here; the caller does both.
- A map name is letters, digits, `_` and `-` only (every `MapIDClient` of the 2016 data is); any other name, for example one with `..` or a path separator, is refused before a file is touched, so a name that one day comes from a client cannot leave `BlockInfo/`. `GameData.DataFile.path/2` itself does not check its path; it is called with paths from the code only.
- A header is valid when both numbers are above 0 and the file size is `8 + bytesPerRow × rows`; the `.shab` must have the dimensions of the `.shbd`. Errors are `{:error, message}`; `<file>` is `BlockInfo/` and the name on disk (the asked name when not found):

| Message | When |
|---|---|
| `BlockInfo: <name> is not a map name` | the name has a byte other than a letter, a digit, `_` or `-`, or is empty |
| `<file>: file not found` | the `.shbd` is missing |
| `<file>: <reason>` | another read error |
| `<file>: damaged block data (header <a> x <b>, <size> bytes)` | zero dimension or wrong size |
| `<file>: damaged block data (<size> bytes, no header)` | shorter than 8 bytes |
| `<shab>: damaged block data (header <a> x <b>, <shbd> has <c> x <d>)` | `.shab` of other dimensions |

- Queries (Z02 §2, Z09 §9.2): `blocked?/3` (`mbi_IsMoveBlock`, FUN_0049df70), `free_cell?/3` (`mbi_OccupCellCheck`, FUN_0049e230, radius 1: any of the 3 × 3 cells inside the map and free), `line_blocked?/4` (`sp_MovePathBlockCheck`, FUN_00456a70: `need` consecutive blocked inner steps, default 2, end points never tested). The cell of a coordinate is `div(band(v × 8, 0xFFFFFFFF), 50)` (the `u32` arithmetic of the original), so a negative coordinate is outside the map and outside counts as blocked. The original interpolates with x87 floats; the rebuild uses floats and `round/1`, which differ only on an exact .5 tie, by one unit.
- `Zone.MapInstance` loads the block data of its map at the first entry; `Zone.check_maps/1` checks the header of every plain field map at start-up.

## Import (`mix pinata.import_data <9Data folder> <new data directory>`)

`GameData.Import.run/2` walks every file under `<9Data folder>/Shine` and applies the first rule that matches. Nothing outside `Shine/` is read. All TXT files are converted in memory first; on any error nothing is written. The target must not exist or must be empty (the default database file lives in the data directory, so overwriting is never allowed).

| File | Action |
|---|---|
| `World/ExpRecalculation.txt` | left out (no 2016 binary reads it) |
| `*.shn` in `Shine/`, `View/*.shn` | copied to `shn/` |
| `DefaultCharacterData.txt`, `TutorialCharacterData.txt` | one CSV per `#DEFINE`: `tables/<file>/<DEFINE>.csv` |
| `.txt` under `World/`, `MobRegen/`, `MobRoam/`, `MobAttackSequence/`, `NPCItemList/`, `MobSetting/` | with a `#table`: one table is `tables/<path>.csv`, several are `tables/<path>/<table>.csv`. Without: copied to `tables/<path>` with a warning |
| `LuaScript/`, `ScenarioBookShelf/`, `Script/` (not `.xls`) | copied |
| `BlockInfo/*.shbd,*.aid,*.sbi,*.shab`, `AreaBMP/*.bmp` | copied |
| everything else (`AbState/`, `AIScript/`, `MobBehaviorDescript/`, `*.bdt`, `*.shmd`, `*.shad`, `*.xls`, `*.db`, …) | left out; the task counts them |

### TXT tables (`GameData.Import.Txt`)

The `#`-command format. Lines are split into tokens at bytes below 0x20 and at the bytes a `#delimiter` declared (a space is not one by default). A `;` at the start of a token begins a comment. The first token is the command: `ignore C`, `delimiter C` (from the next line), `exchange FROM TO`, `table NAME`, `columntype T…` (`index`, `string[n]`, `byte`, `word`, `dwrd`, `dword`), `columnname N…`, `record V…`, `recordin TABLE V…`, `end`. A character argument is one byte or `\dNNN`, `\oNNN`, `\xNN`. Values lose the ignore bytes and then go through the exchange map. Number columns are trimmed, must be `-?[0-9]+` or `0x…` (written as decimal). Text values are kept as written (not cut to `n`). Too few values is an error; extra blank values are dropped silently, other extras with a warning. A second table of the same name in one file becomes `NAME.2`, `NAME.3`, …, with a warning.

Table names are limited to `[A-Za-z0-9_][A-Za-z0-9_().-]*` because they become file names; any other name is an error.

Oddities of the 2016 data: `NPCItemList/HednisSkillGrunt.txt` declares `Tab08` twice (so `Tab08.2.csv`); `World/QuestParser.txt` has no `#table` (copied); `World/RecallCoord.txt` line 56 has a blank extra value; the column `TimeLimit(min)` in `World/Quest.txt` has brackets in its name; 8 tables have no rows.

### Character-default scripts (`GameData.Import.Csl`)

`#DEFINE NAME`, one `<INTEGER>` or `<STRING>` line per column, `#ENDDEFINE`, then rows `NAME v v v`. Values are separated by blanks and commas (a trailing comma and a missing comma are both normal), a `"` value runs to the closing quote, `;` starts a comment, `#END` stops. The scripts have no column names; a fixed map supplies them:

| `#DEFINE` | Header |
|---|---|
| `CHARACTER` | `Class,StartMap,StartX,StartY,HP,SP,HPStone,SPStone,Money,InitLV,InitEXP` |
| `TUTORIAL_CHARACTER` | `Class,StartMap,StartX,StartY,HP,SP,HPStone,SPStone,Money` |
| `ITEM`, `DEFAULT_ITEM`, `TUTORIAL_ITEM` | `Class,ItemID,Lot` |
| `SKILL` | `Class,SkillID` |
| `QUEST` | `Class,QuestID` |
| `MAXSHAPE` | `Class,MaxFace,MaxHair,MaxHairColor` |
| `SHORTCUT` | `Class,SlotNo,CodeNo,Value` |

A `#DEFINE` that is not in the map is an error.

### CSV dialect (`GameData.Csv`)

RFC 4180 with a header row: comma separator, `"` quoting with `""`, quoted cells may hold commas, quotes, CR and LF. A cell is quoted only when it needs it. Rows end with LF when written; LF and CRLF are read. Bytes are never interpreted.

## Digest (`GameData.digest/1`)

SHA-256, lower-case hex, over every regular file below the data directory in sorted relative-path order. Per file the hash gets the relative path, a zero byte, the size as 64 bits and the content, so renaming, adding, removing or changing a file changes the digest. Top-level entries whose name starts with `pinata.db` (the default SQLite database and its WAL files) are left out. A symlinked directory is not entered (a link loop would never end), so files behind it are not part of the digest; a symlink to a file is hashed by its content. Only multi-node mode computes it, once at start-up (`Cluster.DataDigest`, see [`cluster.md`](cluster.md)). The imported 2016 `9Data` (222 MB) took 0.4 s on an Apple M1 Pro.

## Import without Mix (`GameData.Release.import_data/2`)

`bin/pinata eval 'GameData.Release.import_data("<9Data folder>", "<new data directory>")'` does what the Mix task does (the task calls it): it runs `GameData.Import.run/2`, prints each warning, the summary line and the `Next:` line with `IO.puts`, and raises `RuntimeError` with the problems joined by newlines, so the exit status is non-zero.

## Schemas

One module per table, `GameData.<Name>`, implementing `GameData.Schema`: a struct with `@enforce_keys` and a `__schema__/0` map with

- `source`: `{:shn | :csv, path in the data directory}`,
- `key`: a field name, or `:row` (the 1-based data row number) for a table without a natural key,
- `columns`: `field: {column name in the file, :integer | :string}`,
- `indexes`: fields with a non-unique index (`GameData.lookup/3`, rows in file order),
- `references`: `field: schema`, the value must be a key of that schema's table.

A schema lists only the columns the server reads. A column of the file that it does not list is ignored; a listed column the file lacks is an error. A table without a schema is not loaded. Built so far (all read by character creation, `docs/pseudocode/db/D02-character.md` §3.3 and `docs/pseudocode/wm/W01-core.md` §4.1): `SingleData`, `MapInfo`, `ItemInfo`, `HairInfo`, `HairColorInfo`, `FaceInfo`, `CharDefault`, `CharDefaultItem`, `CharDefaultSkill`, `CharDefaultQuest`, `CharDefaultShortcut`, and `BadNameFilter` (the name filter of WorldManager, W01 §4.1). The references are `CharDefault.start_map` to `MapInfo` and `CharDefaultItem.item_id` to `ItemInfo`.

Map tables, declared by `Zone` and read by the map instances, NPCs, gates, town portal and chat later:

| Module | File | Key | Index |
|---|---|---|---|
| `FieldList` | `tables/World/Field/FieldList.csv` | row | `map_id_client` |
| `ShineNpc` (`ShineNPC`) | `tables/World/NPC/ShineNPC.csv` | row | `map` |
| `LinkTable` | `tables/World/NPC/LinkTable.csv` | row | `argument` |
| `ChrCommon` (`Common`) | `tables/World/ChrCommon/Common.csv` | `key` | none |
| `MobInfo` | `shn/MobInfo.shn` | `id` | `inx_name` |
| `TownPortal` | `shn/TownPortal.shn` | `index` | none |
| `SpamerPenalty` | `shn/SpamerPenalty.shn` | `penalty_lv` | none |
| `SpamerPenaltyRule` | `shn/SpamerPenaltyRule.shn` | row | none |

`FieldList`, `ShineNPC` and `LinkTable` are keyed by row because no column is unique. None of the eight has references; `ShineNPC.Map` is deliberately not one (rows on maps that do not run exist). `GameData.plain_field_maps/0` returns the `FieldList` rows with `KQ = 0` and no sub-map range (`SubFrom` and `SubTo` are `-`), in file order: 88 of 153 rows in the 2016 data. `GameData.count/1` returns the number of rows of a table.

## Loading

`GameData.load(data_dir, schemas, strict_references: boolean)` is called by `Pinata.Application` after the settings and before any supervisor. A part declares its tables in `game_data/0` (`Login` none, `WorldManager` the twelve above, `Zone` the eight map tables below); the application loads the union and the schemas they refer to. A missing data directory returns the error that names `mix pinata.import_data`. `GameData.Loader.parse/3` (pure) reads every table and returns **all** problems together; any problem stops the start:

| Problem | Message (starts with the file) |
|---|---|
| file missing | `<file>: file not found` |
| column missing | `<file>: column "HP" is missing` |
| SHN column of the wrong type | `<file>: column "HP": expected an integer, the file has a string column` |
| CSV row of the wrong width | `<file> row 3: expected 11 cells, got 10` |
| CSV integer cell | `<file> row 3: column "HP": expected an integer, got "abc"` |
| duplicate key | `<file> row 7: duplicate key 26` |
| dangling reference | `<file> row key 26: column "StartMap" refers to "Nowhere", which is not in <target file>` |

A dangling reference is an error when `data.strict_references` is true (the default) and a logged warning when it is false.

## Storage and look-up

Each table is one `persistent_term` entry `{GameData, schema}` with `%{rows: key => struct, indexes: field => value => [struct]}`; only `GameData.load/3` writes it, and there is no reload (a second load in the same VM stores equal terms, which `persistent_term` ignores). Strings are copied so that no row keeps the whole file binary alive.

- `GameData.fetch(schema, key)` returns `{:ok, row} | :error`.
- `GameData.lookup(schema, field, value)` returns the rows of an index, `[]` for none.
- `GameData.follow(row, field)` returns `{:ok, target_row} | :error`; it can be `:error` in lenient mode.

All three raise when the schema's table was not loaded: the part forgot to declare it.

## Measured

At every start the node logs `GameData: <tables> tables, <rows> rows, <ms> ms, <bytes> bytes`. The three runs of `mix run -e ':ok'` on the imported 2016 data set (2026-11-18, Apple M1 Pro, macOS 27.2.1, Elixir 1.20.5 on OTP 29, `MIX_ENV=dev`), parse of the eleven tables (measured before `BadNameFilter` was added):

```
GameData: 11 tables, 15846 rows, 380 ms, 2796448 bytes
GameData: 11 tables, 15846 rows, 374 ms, 2796448 bytes
GameData: 11 tables, 15846 rows, 385 ms, 2796448 bytes
```

Bytes are `:erts_debug.flat_size/1` times the word size; it leaves out binaries over 64 bytes, which are shared. The import itself (`mix pinata.import_data`, 981 CSV files, 997 copied files, 222 MB) took about 8 s.

## Not built yet

The MD5 of the 49 checksummed client data tables, a map instance that uses the block data (`.shab` on its own, `.sbi` and `.aid` are not read), and tables for everything other than character creation (ADR 0006).
