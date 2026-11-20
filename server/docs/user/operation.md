# Operation

## Start, stop, logs

From a release (`MIX_ENV=prod mix release`, see [`install.md`](install.md)), in the release directory or with the path to `bin/pinata`:

| Action | Command |
|---|---|
| start in the foreground | `bin/pinata start` |
| start in the background | `bin/pinata daemon` |
| stop | `bin/pinata stop` |
| OS process id | `bin/pinata pid` |
| shell into the running node | `bin/pinata remote` |
| run a command | `bin/pinata eval "<expression>"` |

A string inside an expression is written `~s(...)`, not in double quotes. On Windows there is no `daemon`: `bin/pinata start` stays in the foreground of its window; stop it with `bin/pinata stop` from another window or with `Ctrl-C` twice. See [`install.md`](install.md), section "Windows", for the other differences.

The settings file defaults to `./pinata.toml` and the data directory to `./data`, both relative to the working directory the command starts in, so start from the directory that holds them or set `PINATA_CONFIG` (path of the settings file) and `data_dir`. `PINATA_PARTS` chooses the parts of the node (see [`multi-node.md`](multi-node.md) and [`settings.md`](settings.md)). From a source checkout, `iex -S mix` in `server/` starts the same node.

Logs go to standard output; under Docker Compose read them with `docker compose logs`. Start-up failures are printed to standard error. A node logs at start-up the number of game tables and rows it loaded and how long it took.

## Start-up failures

| Message | Meaning |
|---|---|
| `Invalid settings, the node does not start:` followed by one line per problem | the settings file or an environment variable is wrong; every problem is listed (see [`settings.md`](settings.md)) |
| `Invalid game data, the node does not start:` followed by one line per problem | the data directory is missing or a table is damaged (see [`install.md`](install.md)) |
| the database messages in the next section | `database.url` is unusable or migrations are pending |
| `Data directory digest mismatch, the node stops:` | multi-node mode: this node's data directory differs from that of the WorldManager node; the node stops with exit status 1 (see [`multi-node.md`](multi-node.md)) |
| `Application pinata exited: ... failed to start child: Login.Supervisor ... :eaddrinuse` (also `WorldManager.Supervisor`, `Zone.Supervisor`) | the listener port of that part is already in use, for example by a node that is still running; stop it or change `login.port`, `world_manager.port` or `zone.port` |

## Memory

Measured on 2026-11-19: the single-node release (all three parts, SQLite, 2016 `9Data` data directory, no client connected, idle for about one minute after `bin/pinata daemon`) on macOS 27.2.1, Apple M1 Pro (arm64), Erlang/OTP 29, Elixir 1.20.5:

| Measure | Value | Command |
|---|---|---|
| resident set size of the OS process | 202384 kB (198 MB) | `ps -o rss= -p $(bin/pinata pid)` |
| memory the Erlang VM reports | 144122129 bytes (137 MB) | `bin/pinata rpc 'IO.inspect(:erlang.memory(:total))'` |

The game data is held in memory, so the size follows the data directory.

On Windows the two commands are `(Get-Process -Id (bin\pinata pid)).WorkingSet64` (PowerShell, bytes) and `bin\pinata rpc "IO.inspect(:erlang.memory(:total))"`.

## Time zone

The in-game clock and the stored dates shown to the client (for example the Kingdom Quest date in the character list) use the time zone of the node's operating system. Set the `TZ` environment variable to change it. On Windows change the time zone of Windows instead: of the `TZ` values only `UTC` has an effect there.

## Character creation

A character name has 1 to 20 bytes, no space, and must pass `shn/BadNameFilter.shn` of the data directory. The Sentinel class needs a character of the level in the row `ChrLevel_CanCreateSen` of `shn/SingleData.shn` on the same account and world. The starting values (map, position, level, items, skills, shortcuts) come from `tables/DefaultCharacterData/*.csv` of the data directory. A change to these files needs a restart.

A database created by an earlier build must be deleted: the initial migration gained columns and tables.

## Database and migrations

`database.url` (or the environment variable `DATABASE_URL`) has two forms:

- `sqlite:<path>`: the default is `sqlite:./data/pinata.db`. The file and its directory are created and migrated at every start. Nothing to do.
- `postgres://user:password@host/database`: the node refuses to start while migrations are pending. Run them once before you start the nodes of a new version:
  `bin/pinata eval "Persistence.Release.migrate()"` from a release, or `mix pinata.migrate` in `server/`.

On Windows a SQLite path may use either slash: `sqlite:C:/pinata/data/pinata.db` or `sqlite:C:\pinata\data\pinata.db` (in the settings file, backslashes need a TOML literal string in single quotes).

Start-up errors from the database:

| Message | Meaning |
|---|---|
| `database.url: unknown scheme: "...", expected sqlite:<path> or postgres://user:password@host/database` | the URL form is not one of the two |
| `database.url: unknown scheme: a URL without scheme, expected ...` | the URL has no `scheme:` part at all (for example a bare file path) |
| `database.url: cannot create the directory of <path> (...)` | the directory of the SQLite file cannot be created |
| `database.url: SQLite works only in single-node mode ...` | the node runs only some parts or has `cluster.nodes` set, and the URL is `sqlite:` (also the default); set a `postgres://` URL (see [`multi-node.md`](multi-node.md)) |
| `The database has N pending migration(s): ...` | PostgreSQL only; run the migrate command named in the message |
