# Server data tables are imported once to CSV

The original server keeps its server-only tabular data in its own text formats: about 630 TXT table files (`#Table` / `#ColumnType` / `#ColumnName`) and two CSL scripts with the defaults of a new character. The rebuild does not read these formats at run time. A one-time import task reads an original `9Data` folder and writes a complete new data directory: every TXT table becomes one CSV file with a header row under `tables/<family>/<table>.csv` (a file holding several tables becomes a folder), the two character-default scripts are converted the same way, and everything else the server needs is copied unchanged. The server reads only the new directory.

We chose this because the TXT formats are hard to read and edit, the data is purely tabular, and CSV opens in any spreadsheet and diffs line by line; TOML or YAML would be far more verbose at this size (`ItemDropTable` alone is 1.4 MB). Converting in place or reading TXT at run time would keep two formats alive in the server.

Not converted: SHN tables (the client holds the checked ones byte-identical, and the server-only ones share the same reader and existing editors), Lua scripts, the `Script/` and `ScenarioBookShelf/` script families (programs, not tables; decided with the milestones that run them), and the binary geometry (`BlockInfo/`, `AreaBMP/`).

## Consequences

- The data directory of the rebuild differs from every other Fiesta server; community tools that edit the TXT tables do not work on it. An original data set is brought in by running the import task again.
- The import task converts all TXT tables generically. Column types live in a schema in the server code, written in the milestone that first loads a table and checked at load; until then a table's CSV is unvalidated.
- The per-world override folders of the original (`World/<world name>/…`) are not carried over while only one world exists.
- Files no 2016 binary names (listed in the [data file inventory](https://github.com/wbpascal/pinata/blob/research/data-file-inventory/docs/research/data-file-inventory.md)) are left out by the import.
- `MobSetting/` is known from path strings only; if it is not a TXT table it needs its own converter.
