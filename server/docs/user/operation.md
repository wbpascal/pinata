# Operation

## Start, stop, logs

From the release (see [`install.md`](install.md)), with the path to its `bin/pinata`:

| Action | Command |
|---|---|
| start in the foreground | `bin/pinata start` |
| start in the background | `bin/pinata daemon` |
| stop | `bin/pinata stop` |
| OS process id | `bin/pinata pid` |
| shell into the running node | `bin/pinata remote` |
| run a command | `bin/pinata eval "<expression>"` |

A string inside an expression is written `~s(...)`, not in double quotes. On Windows there is no `daemon`: `bin/pinata start` stays in the foreground of its window; stop it with `bin/pinata stop` from another window; that is the recommended way. `Ctrl-C` twice in its window was not tried on Windows. See [`install.md`](install.md), section "Windows", for the other differences.

The settings file defaults to `./pinata.toml` and the data directory to `./data`, both relative to the working directory the command starts in, so start from the directory that holds them or set `PINATA_CONFIG` (path of the settings file) and `data_dir`. `PINATA_PARTS` chooses the parts of the node (see [`multi-node.md`](multi-node.md) and [`settings.md`](settings.md)). To start a node from a source checkout, see [`from-source.md`](from-source.md).

Logs go to standard output; under Docker Compose read them with `docker compose logs`. Start-up failures are printed to standard error. A node logs at start-up the number of game tables and rows it loaded and how long it took. What the server log holds, and how to read it, is in "Server log" below.

## Start-up failures

| Message | Meaning |
|---|---|
| `Invalid settings, the node does not start:` followed by one line per problem | the settings file or an environment variable is wrong; every problem is listed (see [`settings.md`](settings.md)) |
| `Invalid game data, the node does not start:` followed by one line per problem | the data directory is missing or a table is damaged (see [`install.md`](install.md)) |
| the database messages in the next section | `database.url` is unusable or migrations are pending |
| `Data directory digest mismatch, the node stops:` | multi-node mode: this node's data directory differs from that of the WorldManager node; the node stops with exit status 1 (see [`multi-node.md`](multi-node.md)) |
| `<Part>: cannot listen on port <port>: address already in use. The node does not start.` (`<Part>` is `Login`, `WorldManager` or `Zone`) | the listener port of that part is already in use, for example by a node that is still running; stop it or change `login.port`, `world_manager.port` or `zone.port`. Other reasons (`permission denied`) use the same form. The OTP reports that follow it are not part of the message |
| no message: the node starts and logs that it listens, but the client cannot connect or its connection hangs | Windows: another program listens on the same port on the loopback address `127.0.0.1`. Windows lets the node listen on `0.0.0.0` on that port without an error, and connections to `127.0.0.1` reach the other program (seen with Logitech G HUB on 9010). Check with `netstat -ano` (look for `127.0.0.1:<port>` in state `LISTENING` and the process id in the last column) and change `login.port`, `world_manager.port` or `zone.port` |

## Server log

Every line is `date time [level] Part: message`, for example

```
2026-11-20 14:03:11.482 [info] Login: listening on 0.0.0.0:9010
```

Timestamps are UTC whatever the machine's time zone. `Part` is `Login`, `WorldManager`, `Zone`, `Pinata`, `Cluster`, `Persistence` or `GameData`. The setting `log.level` (`debug`, `info`, `warning` or `error`, default `info`; see [`settings.md`](settings.md)) is the lowest level that is printed.

| Level | Meaning | Examples |
|---|---|---|
| `error` | the server failed, an administrator must act | database failure, digest mismatch |
| `warning` | the server is degraded or defended itself | limit exceeded, send failed, node lost, world unavailable |
| `info` | normal events worth a line | node started, listening, login accepted or refused, client protocol violations (unknown opcode, wrong first packet, wrong version key) |
| `debug` | per-packet and per-connection detail | dropped wrong-size packet, connection accepted, close initiated by the client |

A password, a login token, a world key or the database URL is never printed. An account name is printed in double quotes, as it was typed. A peer is the address and port of the client, for example `127.0.0.1:51234`.

Lines an administrator acts on:

| Line | Level | Meaning / what to do |
|---|---|---|
| `<Part>: listening on <address>:<port>` | info | the listener is bound; the address is the one the socket reports |
| `Pinata: node started, parts <parts>, <single-node or multi-node> mode, database <sqlite or postgres>` | info | the node is up; this is the last start-up line |
| `<Part>: connection closed: oversized frame, peer <peer>` | info | the client sent a frame larger than the protocol allows; the server cut it off |
| `<Part>: connection closed: unknown opcode 0x<opcode>, peer <peer>` | info | the client sent a packet the server does not know; it was cut off |
| `<Part>: connection closed: wrong first packet, peer <peer>` | info | the first packet was not the one the part expects (`0x0C65` at Login, `0x0C0F` at WorldManager) |
| `Login: connection closed: unexpected packet instead of the login, peer <peer>` | info | after the version check the client did not send a login |
| `Login: connection closed: wrong version key, peer <peer>` | info | the client's version key differs from `client_version_key`; the client needs the other build or the setting needs changing |
| `<Part>: connection closed: session replaced, peer <peer>` | info | the same account logged in again; the older connection was cut off |
| `<Part>: connection closed: heartbeat timeout, peer <peer>` | info | the client was silent for 210 s |
| `<Part>: connection closed: packet rate exceeded, peer <peer>` | warning | the client sent more than `connection.max_packets_per_second` packets in one second |
| `<Part>: connection closed: unsent bytes exceeded, peer <peer>` | warning | the client does not read what the server sends (`connection.max_unsent_bytes`) |
| `<Part>: connection closed: send failed, peer <peer>` | warning | a send to the client failed, usually because the client had already gone |
| `WorldManager: connection closed: world login refused, no matching reservation, peer <peer>` | info | the client came to WorldManager with a key Login never gave it, or with an old one |
| `WorldManager: connection closed: character list failed, database failure, peer <peer>` | warning | the database failed; look for the `Persistence` line before it |
| `Login: login accepted, account "<name>", peer <peer>` | info | the login succeeded |
| `Login: login accepted with a login token, account "<name>", peer <peer>` | info | a client came back from WorldManager to the world list |
| `Login: connection closed: login refused, account "<name>", unknown account, peer <peer>` | info | no such account (and `login.auto_create_accounts` is off); the name is as typed |
| `Login: connection closed: login refused, account "<name>", wrong password, peer <peer>` | info | the password did not match |
| `Login: connection closed: login refused, account "<name>", blocked, peer <peer>` | info | the account is blocked |
| `Login: connection closed: login refused, account "<name>", not login-able, peer <peer>` | info | the account may not log in |
| `Login: connection closed: login refused, account "<name>", database failure, peer <peer>` | info | the database failed; look for the `Persistence` line before it. The client is told "unknown account" |
| `Login: connection closed: login refused, unknown or expired login token, peer <peer>` | info | the client used a login token that does not exist, was used or is older than 10 s |
| `Cluster: node <node> connected` | info | multi-node mode: another node joined |
| `Cluster: node <node> lost` | warning | multi-node mode: a node went away |
| `Login: world <number> (<name>) is available` | info | multi-node mode: the WorldManager of the world is reachable from Login |
| `Login: world <number> (<name>) is unavailable` | warning | multi-node mode: the world was available and is not any more |

The four cluster lines appear in multi-node mode only. Login looks the worlds up once a second; a world is reported unavailable only after it was available, so a Login node that starts before the WorldManager node logs nothing until the world appears. A close by the client is logged at `debug` only.

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

A rename on the character list follows the same rules with at most 16 bytes, and a name already used in the world is refused whatever the letter case; the rename right (rename by item) is always refused in this version.

A database created by an earlier build must be deleted: the initial migration gained columns and tables.

## Database and migrations

`database.url` (or the environment variable `DATABASE_URL`) has two forms:

- `sqlite:<path>`: the default is `sqlite:./data/pinata.db`. The file and its directory are created and migrated at every start. Nothing to do.
- `postgres://user:password@host/database`: the node refuses to start while migrations are pending. Run them once before you start the nodes of a new version:
  `bin/pinata eval "Persistence.Release.migrate()"` (from a source checkout `mix pinata.migrate`, see [`from-source.md`](from-source.md)).

On Windows a SQLite path may use either slash: `sqlite:C:/pinata/data/pinata.db` or `sqlite:C:\pinata\data\pinata.db` (in the settings file, backslashes need a TOML literal string in single quotes).

Start-up errors from the database:

| Message | Meaning |
|---|---|
| `database.url: unknown scheme: "...", expected sqlite:<path> or postgres://user:password@host/database` | the URL form is not one of the two |
| `database.url: unknown scheme: a URL without scheme, expected ...` | the URL has no `scheme:` part at all (for example a bare file path) |
| `database.url: cannot create the directory of <path> (...)` | the directory of the SQLite file cannot be created |
| `database.url: SQLite works only in single-node mode ...` | the node runs only some parts or has `cluster.nodes` set, and the URL is `sqlite:` (also the default); set a `postgres://` URL (see [`multi-node.md`](multi-node.md)) |
| `The database has N pending migration(s): ...` | PostgreSQL only; run the migrate command named in the message |

## Moving to a new version

1. Stop the node (every node, in multi-node mode).
2. Unpack the release archive of the new version beside the old release (see [`install.md`](install.md)). It makes its own directory `pinata-<version>`, so the old release stays as it is.
3. Keep `pinata.toml` and the data directory where they are; the new release reads them as the old one did.
4. Run the migrations. SQLite: nothing to do, the node migrates the database at start-up. PostgreSQL: `pinata-<version>/bin/pinata eval "Persistence.Release.migrate()"` with the new release, once, before the nodes start.
5. Start the node with the new release: `pinata-<version>/bin/pinata start`.

A database of any version reaches every later one, so a version may be skipped. The changelog section of each version (`CHANGELOG.md` at the repository root, and the text of the release on the releases page) says under "Moving from the previous version" what else is needed, for example importing the data directory again; when you skip versions, read that heading of every version you skip.

With the container image, the new version is a new image tag; for the Docker Compose example see [`multi-node.md`](multi-node.md).
