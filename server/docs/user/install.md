# Install

## Prerequisites

Install the tools with `mise install` at the repository root (Erlang and Elixir, versions in `mise.toml`), then `mix deps.get` in `server/`. For the container image you need Docker instead (or as well).

On Windows, install mise first (for example `winget install jdx.mise`) and activate it in your shell as its documentation describes; then the same two commands apply. No C compiler is needed: the SQLite library is downloaded prebuilt. The commands of these pages work in PowerShell and in `cmd` with the differences listed under [Windows](#windows).

## The release

`MIX_ENV=prod mix release` in `server/` builds `_build/prod/rel/pinata` (add `--overwrite` to build again over an existing one). In PowerShell that is `$env:MIX_ENV = "prod"; mix release`, in `cmd` `set MIX_ENV=prod` and then `mix release`. The release holds its own Erlang runtime and the compiled server, so the target machine needs no Erlang or Elixir, but it must run the same operating system and CPU architecture as the build machine. Copy the whole directory. The commands are `bin/pinata start`, `daemon`, `stop`, `remote` and `eval` (see [`operation.md`](operation.md)). The data directory is not part of the release.

## Windows

A release built on Windows runs on Windows. It was tried on Windows 11 with PowerShell 7 and `cmd` (2026-11-20), and CI builds, tests and smoke-tests it on Windows at every change.

Supported on Windows is **single-node mode with SQLite**. PostgreSQL, multi-node mode and `bin\pinata install` (a Windows service) are not supported there; nothing stops them from starting, but they are not tested. For multi-node mode run Linux containers, for example with Docker Desktop: [`multi-node.md`](multi-node.md) has a Docker Compose example.

Before you clone, allow long paths in Git: some files under `Files/` have paths longer than Windows allows by default, and the checkout fails with `Filename too long`. The setting must be in place before the files are written, so it cannot come with the repository:

```
git config --global core.longpaths true
```

The repository's `.gitattributes` makes every text file LF on every platform, whatever `core.autocrlf` says; `mix format --check-formatted` and some tests depend on it. A clone made before that rule came in still has CRLF files; check them out again once, in the repository root, with no changes of your own in it: `git rm -r --cached -q .` and then `git reset --hard`.

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

The import from a release, in `server\`:

```
_build\prod\rel\pinata\bin\pinata eval "GameData.Release.import_data(~s(C:/Fiesta/9Data), ~s(./data))"
```

`mix pinata.import_data C:\Fiesta\9Data data` takes the path with backslashes too.

## The container image

`docker build -t pinata server/` builds an image with the release, started with `bin/pinata start` as an unprivileged user. On Windows the same command works with Docker Desktop and Linux containers; the image holds the Linux release whatever the host. It holds no data directory: mount one (for example at `/data`) and tell the node with `PINATA_CONFIG` or `data_dir`. Every version is also published as `ghcr.io/wbpascal/pinata:<version>` (and `latest`) for linux/amd64 and linux/arm64, built from the same `Dockerfile`; [`multi-node.md`](multi-node.md) uses it in a Docker Compose example.

## The data directory

The server reads the game's data tables from one directory, the data directory. You make it once from an original `9Data` folder (the one with the `Shine` folder inside):

```
mix pinata.import_data <9Data folder> <new data directory>
```

From a release, which has no `mix`, the same import is `bin/pinata eval "GameData.Release.import_data(~s(<9Data folder>), ~s(<new data directory>))"`. On Windows write the path inside `eval` with forward slashes or as `~S(...)` (see [Windows](#windows)).

The command copies the SHN tables, scripts and map geometry unchanged and converts the TXT tables to CSV files. It prints how many tables it wrote, how many files it copied and how many it left out, and a warning for each file it could not convert as a table. On a problem it prints all of them, writes nothing and exits with a non-zero status. A folder with nothing the server uses (no table and no file to copy) is such a problem: `<9Data folder>: nothing to import, no table or file of the Shine folder is one the server uses`. The target must not exist or must be empty; to bring an original data set in again, import it into a new directory and point `data_dir` at that.

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

Fix the files, or import again into a new directory. Every node needs the data directory, whichever parts it runs, and in multi-node mode all nodes need the same one (see [`multi-node.md`](multi-node.md)). At every start the node logs the number of tables and rows it loaded and how long it took.
