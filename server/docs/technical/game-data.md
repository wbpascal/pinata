# Game data

**Warning: text columns are raw bytes.** Every text value of a data table (SHN strings, CSV cells) is in the client's legacy code page. It is never converted to UTF-8, it is not valid UTF-8 in general, and printing it or pattern-matching it as an Elixir string looks like corruption. Code that logs or compares such text converts at that point ([ADR 0006](../../../docs/adr/0006-game-data-loaded-once-at-start-up.md)). The import writes the bytes unchanged, so an editor of the CSV files must keep them too.

The boundary `GameData` reads the data directory when a node starts and keeps each table in `persistent_term`. The decisions are in [ADR 0005](../../../docs/adr/0005-server-data-tables-imported-to-csv.md) and ADR 0006; this page describes what is built.

## Data directory

| Path | Content |
|---|---|
| `shn/<Name>.shn`, `shn/View/<Name>.shn` | the SHN tables, byte for byte |
| `tables/…/*.csv` | the server data tables, converted from TXT (below) |
| `LuaScript/`, `Script/`, `ScenarioBookShelf/` | scripts, copied |
| `BlockInfo/`, `AreaBMP/` | geometry, copied (not loaded with the tables) |

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

## Schemas

One module per table, `GameData.<Name>`, implementing `GameData.Schema`: a struct with `@enforce_keys` and a `__schema__/0` map with

- `source`: `{:shn | :csv, path in the data directory}`,
- `key`: a field name, or `:row` (the 1-based data row number) for a table without a natural key,
- `columns`: `field: {column name in the file, :integer | :string}`,
- `indexes`: fields with a non-unique index (`GameData.lookup/3`, rows in file order),
- `references`: `field: schema`, the value must be a key of that schema's table.

A schema lists only the columns the server reads. A column of the file that it does not list is ignored; a listed column the file lacks is an error. A table without a schema is not loaded. Built so far (all read by character creation, `docs/pseudocode/db/D02-character.md` §3.3 and `docs/pseudocode/wm/W01-core.md` §4.1): `SingleData`, `MapInfo`, `ItemInfo`, `HairInfo`, `HairColorInfo`, `FaceInfo`, `CharDefault`, `CharDefaultItem`, `CharDefaultSkill`, `CharDefaultQuest`, `CharDefaultShortcut`, and `BadNameFilter` (the name filter of WorldManager, W01 §4.1). The references are `CharDefault.start_map` to `MapInfo` and `CharDefaultItem.item_id` to `ItemInfo`.

## Loading

`GameData.load(data_dir, schemas, strict_references: boolean)` is called by `Pinata.Application` after the settings and before any supervisor. A part declares its tables in `game_data/0` (`Login` and `Zone` none, `WorldManager` the twelve above); the application loads the union and the schemas they refer to. A missing data directory returns the error that names `mix pinata.import_data`. `GameData.Loader.parse/3` (pure) reads every table and returns **all** problems together; any problem stops the start:

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

The MD5 of the 49 checksummed client data tables, the per-node data digest for multi-node mode, loading of the geometry, and tables for everything other than character creation (ADR 0006).
