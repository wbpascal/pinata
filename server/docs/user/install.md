# Install

## Prerequisites

Install the tools with `mise install` at the repository root, then `mix deps.get` in `server/`. Building a release is not written yet: the server runs from `server/` with `mix`.

## The data directory

The server reads the game's data tables from one directory, the data directory. You make it once from an original `9Data` folder (the one with the `Shine` folder inside):

```
mix pinata.import_data <9Data folder> <new data directory>
```

The task copies the SHN tables, scripts and map geometry unchanged and converts the TXT tables to CSV files. It prints how many tables it wrote, how many files it copied and how many it left out, and a warning for each file it could not convert as a table. On a problem it prints all of them and writes nothing. The target must not exist or must be empty; to bring an original data set in again, import it into a new directory and point `data_dir` at that.

Then set the directory in `pinata.toml` (default `./data`, see [`settings.md`](settings.md)):

```toml
data_dir = "/srv/pinata/data"
```

`data.strict_references` (default `true`) decides what happens to a table row that refers to a row that does not exist: an error that stops the start, or with `false` a warning in the log.

The text in the CSV files is not UTF-8 but the client's legacy code page. An editor must keep the bytes as they are (open and save without converting the encoding).

## Start-up errors

If the data directory does not exist, the node prints this to standard error and does not start:

```
Invalid game data, the node does not start:
  ./data: data directory not found. Create it from an original 9Data folder with: mix pinata.import_data <9Data folder> ./data
```

If a table is damaged (a missing file or column, a value that is not a number, a duplicate key, a dangling reference), the node prints every problem at once, each starting with the file, and does not start:

```
Invalid game data, the node does not start:
  tables/DefaultCharacterData/CHARACTER.csv row 3: column "HP": expected an integer, got "abc"
  shn/MapInfo.shn: column "MapName" is missing
```

Fix the files, or import again into a new directory. Every node needs the data directory, whichever parts it runs. At every start the node logs the number of tables and rows it loaded and how long it took.
