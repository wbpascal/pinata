# Install

Every version is published in two forms: a release archive per platform on the [releases page](https://github.com/wbpascal/pinata/releases), and the container image `ghcr.io/wbpascal/pinata`. Neither needs Erlang, Elixir or a clone of this repository. To build them yourself, see [`from-source.md`](from-source.md).

While the repository is private, the releases page opens only for accounts with access to the repository, and `docker pull` needs a login first: `docker login ghcr.io` with your GitHub name and a token that may read packages.

## The release archive

| Platform | Archive | Needs |
|---|---|---|
| Linux x86_64 | `pinata-<version>-linux-x86_64.tar.gz` | glibc 2.39 or newer, for example Ubuntu 24.04 or Debian 13. On an older distribution use the container image |
| Linux arm64 | `pinata-<version>-linux-arm64.tar.gz` | as Linux x86_64 |
| macOS arm64 (Apple silicon) | `pinata-<version>-macos-arm64.tar.gz` | unpack it with `tar` in a terminal, not by double-clicking it |
| Windows x86_64 | `pinata-<version>-windows-x86_64.zip` | single-node mode with SQLite only (see [Windows](#windows)) |

`tar -xzf pinata-<version>-<platform>.tar.gz` (on Windows `Expand-Archive pinata-<version>-windows-x86_64.zip .` in PowerShell) makes the directory `pinata-<version>`: the release. It holds its own Erlang runtime and the compiled server; copy the whole directory if you move it. The commands are `bin/pinata start`, `daemon`, `stop`, `remote` and `eval` in that directory (see [`operation.md`](operation.md)). The release holds no settings file and no data directory: keep them outside it, in the directory you start the node in, so that a new version can be unpacked beside the old one (see [`operation.md`](operation.md), "Moving to a new version").

## The container image

`docker pull ghcr.io/wbpascal/pinata:<version>` fetches the image of a version (`latest` is the newest), for linux/amd64 and linux/arm64. It holds the Linux release, started with `bin/pinata start` as an unprivileged user; on Windows and macOS it runs with Docker Desktop and Linux containers. It holds no data directory: mount one (for example at `/data`) and tell the node with `PINATA_CONFIG` or `data_dir`. [`multi-node.md`](multi-node.md) uses it in a Docker Compose example.

## The data directory

The server reads the game's data tables from one directory, the data directory. You make it once from an original `9Data` folder (the one with the `Shine` folder inside):

```
bin/pinata eval "GameData.Release.import_data(~s(<9Data folder>), ~s(<new data directory>))"
```

With only the container image, run the same import in a container, from the directory the data directory is to be made in:

```
docker run --rm --user "$(id -u):$(id -g)" -v <9Data folder>:/9data:ro -v "$PWD":/out ghcr.io/wbpascal/pinata:<version> eval "GameData.Release.import_data(~s(/9data), ~s(/out/data))"
```

This makes `data` in the current directory, owned by you (`--user`); the paths the command prints are those inside the container. It was tried on macOS arm64 with Docker Desktop (981 tables written); on a Linux host it was not tried.

On Windows write the path inside `eval` with forward slashes or as `~S(...)` (see [Windows](#windows)). From a source checkout the same import is `mix pinata.import_data` (see [`from-source.md`](from-source.md)).

The command copies the SHN tables, scripts and map geometry unchanged and converts the TXT tables to CSV files. It prints how many tables it wrote, how many files it copied and how many it left out, and a warning for each file it could not convert as a table. On a problem it prints all of them, writes nothing and exits with a non-zero status. A folder with nothing the server uses (no table and no file to copy) is such a problem: `<9Data folder>: nothing to import, no table or file of the Shine folder is one the server uses`. The target must not exist or must be empty; to bring an original data set in again, import it into a new directory and point `data_dir` at that.

Then set the directory in `pinata.toml` (default `./data`, see [`settings.md`](settings.md)):

```toml
data_dir = "/srv/pinata/data"
```

`data.strict_references` (default `true`) decides what happens to a table row that refers to a row that does not exist: an error that stops the start, or with `false` a warning in the log.

The text in the CSV files is not UTF-8 but the client's legacy code page. An editor must keep the bytes as they are (open and save without converting the encoding).

## Windows

The Windows release was tried on Windows 11 with PowerShell 7 and `cmd` (2026-11-20). CI smoke-tests it at every change, and the release workflow smoke-tests the Windows archive before it is published.

Supported on Windows is **single-node mode with SQLite**. PostgreSQL, multi-node mode and `bin\pinata install` (a Windows service) are not supported there; nothing stops them from starting, but they are not tested. For multi-node mode run Linux containers, for example with Docker Desktop: [`multi-node.md`](multi-node.md) has a Docker Compose example.

What differs from the other pages:

| Topic | On Windows |
|---|---|
| the command | The file is `bin\pinata.bat`. PowerShell accepts `bin/pinata` as written on the other pages; `cmd` needs backslashes: `bin\pinata`. |
| strings in `eval` and `rpc` | Keep the form of these pages: the expression in double quotes, every string inside it as `~s(...)`. Double quotes inside the expression are lost on the way to the node, so `eval 'f("<name>")'` fails with a syntax error. |
| paths in `eval` | Write them with forward slashes: `~s(C:/Fiesta/9Data)`. With backslashes use `~S(C:\pinata\data)` (capital `S`). |
| paths in `pinata.toml` | Forward slashes (`data_dir = "C:/pinata/data"`) or a TOML literal string (`data_dir = 'C:\pinata\data'`). `database.url` takes either: `sqlite:C:/pinata/data/pinata.db`. |
| environment variables | PowerShell: `$env:PINATA_CONFIG = "C:\pinata\pinata.toml"`; `cmd`: `set PINATA_CONFIG=C:\pinata\pinata.toml`. They hold for that window. |
| background start | There is no `daemon`. `bin\pinata start` runs in the foreground of its window. `bin\pinata install` (a Windows service) is not supported. |
| time zone | The node uses the time zone of Windows. Of the `TZ` values only `UTC` has an effect. |
| piped password | `'my-password' \| bin\pinata eval "Persistence.Release.create_account(~s(<name>))"` in PowerShell |

The import, in the directory that holds the unpacked release:

```
pinata-<version>\bin\pinata eval "GameData.Release.import_data(~s(C:/Fiesta/9Data), ~s(./data))"
```

## Start-up errors

If the data directory does not exist, the node prints this to standard error and does not start:

```
Invalid game data, the node does not start:
  ./data: data directory not found. Create it from an original 9Data folder with the release command bin/pinata eval "GameData.Release.import_data(~s(<9Data folder>), ~s(./data))" or, from a source checkout, with mix pinata.import_data <9Data folder> ./data
```

If a table is damaged (a missing file or column, a value that is not a number, a duplicate key, a dangling reference), the node prints every problem at once, each starting with the file, and does not start:

```
Invalid game data, the node does not start:
  tables/DefaultCharacterData/CHARACTER.csv row 3: column "HP": expected an integer, got "abc"
  shn/MapInfo.shn: column "MapName" is missing
```

Fix the files, or import again into a new directory. Every node needs the data directory, whichever parts it runs, and in multi-node mode all nodes need the same one (see [`multi-node.md`](multi-node.md)). At every start the node logs the number of tables and rows it loaded and how long it took.

A node with the Zone part also reads the map and NPC tables (`tables/World/Field/FieldList.csv`, `tables/World/NPC/*.csv`, `tables/World/ChrCommon/Common.csv`, `shn/MobInfo.shn`, `shn/TownPortal.shn`, `shn/SpamerPenalty.shn`, `shn/SpamerPenaltyRule.shn`) and reports a missing or damaged one the same way. File names in the data directory are matched without regard to letter case, so files need not and should not be renamed.
