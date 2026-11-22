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
| run a command on the running node | `bin/pinata rpc "<expression>"` |

A string inside an expression is written `~s(...)`, not in double quotes. On Windows there is no `daemon`: `bin/pinata start` stays in the foreground of its window; stop it with `bin/pinata stop` from another window; that is the recommended way. `Ctrl-C` twice in its window was not tried on Windows. See [`install.md`](install.md), section "Windows", for the other differences.

The settings file defaults to `./pinata.toml` and the data directory to `./data`, both relative to the working directory the command starts in, so start from the directory that holds them or set `PINATA_CONFIG` (path of the settings file) and `data_dir`. `PINATA_PARTS` chooses the parts of the node (see [`multi-node.md`](multi-node.md) and [`settings.md`](settings.md)). To start a node from a source checkout, see [`from-source.md`](from-source.md).

Logs go to standard output; under Docker Compose read them with `docker compose logs`. Start-up failures are printed to standard error. A node logs at start-up the number of game tables and rows it loaded and how long it took. What the server log holds, and how to read it, is in "Server log" below.

## Start-up failures

| Message | Meaning |
|---|---|
| `Invalid settings, the node does not start:` followed by one line per problem | the settings file or an environment variable is wrong; every problem is listed (see [`settings.md`](settings.md)) |
| `Invalid game data, the node does not start:` followed by one line per problem | the data directory is missing or a table is damaged (see [`install.md`](install.md)) |
| `map <name>: BlockInfo/<name>.shbd: file not found` or `map <name>: BlockInfo/<name>.shbd: damaged block data ...` under `Invalid game data` | a node with the Zone part needs the block data file of every field map; import the data directory again |
| `shn/<file>: file not found (needed for the Client data check)` under `Invalid game data` | a node with the Zone part needs the 49 client tables of the Client data check (below); import the data directory again |
| `public_host: a node with the Zone part needs an IPv4 address in text form ...` under `Invalid settings` | `public_host` is a host name; use an IPv4 address such as `203.0.113.7` |
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
| `Zone: <n> of <total> NPC rows skipped: their map does not run` | info | the NPC rows of maps that are not field maps are not placed (12 of 537 in the original data) |
| `WorldManager: Zone node <node> joined world <n> at <host>:<port>, <m> maps` | info | a Zone node joined; `<m>` maps are assigned to it |
| `Zone: world <n>: <m> map instances started` | info | the Zone node runs its maps |
| `Zone: world <n>: <m> map instances taken over from a lost Zone node` | info | this Zone node got the maps of a lost one |
| `WorldManager: Zone node <node> of world <n> lost, <a> maps reassigned, <b> not running` | warning | a Zone node is gone; `<b>` maps run nowhere until a Zone node offering them joins |
| `Zone: WorldManager of world <n> lost, joining again when it returns` | warning | the Zone node joins again once a second |
| `Zone: map <name>: block data loaded, <n> bytes` | info | the first player entered the map |
| `Zone: map <name>: <file>: <reason>` | error | the block data of a map could not be read at the first entry; the entry is refused. Restore the file |
| `Zone: map instance <name> of world <n> crashed (<reason>), started again empty` | error | a map process crashed; it runs again with nobody on it. Report the reason |
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
| `GameData: Client data check: 49 tables hashed, <n> ms` | info | a node with the Zone part hashed the client tables at start |
| `WorldManager: character login refused: map <map> is not running, peer <peer>` | info | a character's stored map runs on no Zone node; the client is told "The Map is under maintenance" |
| `WorldManager: character login failed, database failure, peer <peer>` / `WorldManager: tutorial skip failed, database failure, peer <peer>` | warning | the database failed; look for the `Persistence` line before it |
| `Zone: connection closed: Client data check failed: character "<name>", table <table>, server <hash>, client "<hash>", peer <peer>` | warning | the client's copy of a table differs from the server's (see "Client data check" below) |
| `Zone: map login accepted: character <id>, map <map>, peer <peer>` | info | the client entered the Zone node |
| `Zone: connection closed: map login refused: <reason>, peer <peer>` | info | `no session for the handle`, `no map-login ticket`, `reserved for another Zone node` or `not the reserved character`: the client came to the Zone without a fresh character login |
| `Zone: connection closed: session ended, peer <peer>` | info | the WorldManager connection of the player ended, so the Zone connection was closed |
| `Cluster: node <node> connected` | info | multi-node mode: another node joined |
| `Cluster: node <node> lost` | warning | multi-node mode: a node went away |
| `Login: world <number> (<name>) is available` | info | multi-node mode: the WorldManager of the world is reachable from Login |
| `Login: world <number> (<name>) is unavailable` | warning | multi-node mode: the world was available and is not any more |
| `Pinata: OpenTelemetry export on, trace ratio <ratio>` | info | `telemetry.otlp_enabled` is true; traces and metrics go to the OTLP endpoint (see "OpenTelemetry" below) |
| `Pinata: OpenTelemetry did not start (<reason>), nothing is exported` | warning | the OpenTelemetry libraries failed to start; the node runs on without export. Report the reason |

The four cluster lines appear in multi-node mode only. Login looks the worlds up once a second; a world is reported unavailable only after it was available, so a Login node that starts before the WorldManager node logs nothing until the world appears. A close by the client is logged at `debug` only.

With export on, the OpenTelemetry libraries write lines of their own without a part, for example `OTLP exporter successfully initialized`, and a line for a failed export when the Collector is unreachable.

## Client data check

Always on, with no setting. On `0x1801` the client sends a checksum of each of 49 of its tables (`ItemInfo.shn`, `MapViewInfo.shn`, ...; the list is in the technical documentation, `flows/enter-world.md`). A node with the Zone part hashes its own copies at start. A client whose copy of one of them differs is refused and sees "The client has been illegally manipulated…"; the server writes one `warning` line with the table and both hashes. So a changed table must be shipped to the clients, and the Zone nodes must be started again, since they hash the tables only at start.

## Capacity figures

A node counts two capacity figures, always, from its start (the counts start at 0 at every node start):

- **packet handling time**: from a decoded client packet to its answers handed to the socket, every packet of every part;
- **tick duration**: the work of one 100 ms tick of a map instance.

`bin/pinata rpc "Pinata.Figures.print()"` prints them:

```
Packet handling time (ms)
  buckets <=: 0.1 0.25 0.5 1 2.5 5 10 25 50 75 100 250 500 1000 +Inf
  all nodes: count 1200, p50 <= 0.25, p99 <= 5, buckets 700 300 150 40 8 2 0 0 0 0 0 0 0 0 0
  pinata@host: count 1200, p50 <= 0.25, p99 <= 5, buckets 700 300 150 40 8 2 0 0 0 0 0 0 0 0 0
Tick duration (ms)
  buckets <=: 0.1 0.25 0.5 1 2.5 5 10 25 50 75 100 250 500 1000 +Inf
  all nodes: count 24, p50 <= 0.1, p99 <= 0.1, buckets 24 0 0 0 0 0 0 0 0 0 0 0 0 0 0
  pinata@host: count 24, p50 <= 0.1, p99 <= 0.1, buckets 24 0 0 0 0 0 0 0 0 0 0 0 0 0 0
```

Each figure is a histogram: `buckets <=` are the upper bounds of the buckets in milliseconds (a duration equal to a bound counts in that bucket; `+Inf` is everything above 1000 ms), `buckets` the counts in the same order. `p50` and `p99` are the bucket bounds that 50 % and 99 % of the counts do not exceed: "p99 <= 50" means at least 99 % of the packets took at most 50 ms; `-` means nothing was counted yet, `> 1000` that the percentile lies in the last bucket. The targets are packet handling time p99 <= 50 ms and tick duration p99 <= 100 ms. In multi-node mode the command asks every connected node: `all nodes` is the sum, then one line per node (`no answer` when a node did not answer within 5 s). `bin/pinata rpc "Pinata.Figures.reset()"` sets the counts of every connected node to 0.

## OpenTelemetry

The node can export traces and metrics over OTLP (HTTP) to an OpenTelemetry Collector or a compatible backend. It is off by default: then nothing is exported and no connection is opened, whatever the `OTEL_*` environment variables say. Three settings control it (see [`settings.md`](settings.md)):

```toml
[telemetry]
otlp_enabled = true
otlp_endpoint = "http://collector:4318"
trace_ratio = 0.01
```

What is exported:

- the spans `pinata.packet` (attributes `part`, `opcode`) and `pinata.tick` (attributes `world`, `map`), a share `telemetry.trace_ratio` of them (default 1 %);
- the histograms `pinata.packet.duration` (attribute `part`) and `pinata.tick.duration`, in milliseconds with the bucket bounds of the capacity figures, every packet and tick counted, sent every 60 s.

The server log is not exported. The metrics part of the OpenTelemetry library for Erlang is experimental. The standard `OTEL_*` variables are described in [`settings.md`](settings.md), section "OpenTelemetry variables".

## Memory

Measured on 2026-11-22: the single-node release (all three parts, SQLite, 2016 `9Data` data directory, no settings file, so OpenTelemetry export off; the release includes the OpenTelemetry libraries) on macOS 27.2.1, Apple M1 Pro (arm64), Erlang/OTP 29, Elixir 1.20.5. Idle, no client connected, about one minute after `bin/pinata daemon`, the 88 map processes running and no block data loaded:

| Measure | Value | Command |
|---|---|---|
| resident set size of the OS process | 195360 kB (191 MB) | `ps -o rss= -p $(bin/pinata pid)` |
| memory the Erlang VM reports | 128152735 bytes (122 MB) | `bin/pinata rpc 'IO.inspect(:erlang.memory(:total))'` |

The game data is held in memory, so the size follows the data directory. A node with the Zone part runs one process per field map (88); the block data of a map is read at its first player and never unloaded. The same node with the block data of all 88 field maps loaded (`Zone.MapInstance.enter/2` once on every map), after about one minute more:

| Measure | Value | Command |
|---|---|---|
| resident set size of the OS process | 292848 kB (286 MB) | `ps -o rss= -p $(bin/pinata pid)` |
| memory the Erlang VM reports | 219610335 bytes (209 MB) | `bin/pinata rpc 'IO.inspect(:erlang.memory(:total))'` |

The load command was `bin/pinata rpc 'for %{map_id_client: m} <- GameData.plain_field_maps() do {:ok, p} = Zone.MapInstance.whereis(0, m); :ok = Zone.MapInstance.enter(p, :memory_check) end'`. The budget is 512 MB.

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
