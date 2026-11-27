# Load run

A [load run](../../GLOSSARY.md) puts many test clients on a running server, local or remote, each playing a fixed
script, to check the capacity figures (packet handling time, tick duration). The method was decided in
[issue 27](https://github.com/wbpascal/pinata/issues/27) (load verification) and
[issue 87](https://github.com/wbpascal/pinata/issues/87) (the hold window). Results go to
[`load-run-results.md`](load-run-results.md).

The load task is a developer task: it lives in `test/support/`, reuses `TestClient` over real sockets and is not
part of the release.

## The command

At the repository root:

```
MIX_ENV=test mix pinata.load --host <Login address> --port <Login port> --scenario world|crowd --players <n> [options]
```

| Option | Default | What |
|---|---|---|
| `--host` | `127.0.0.1` | address of the Login part |
| `--port` | `9010` | port of the Login part |
| `--scenario` | required | `world` or `crowd` (see "Scenarios") |
| `--players` | required | 1 to 9999 |
| `--prefix` | `load` | the account names are `<prefix>0001` … |
| `--password` | `load` | the password of every account; the task sends its lower-case hex MD5, as the 2016 client does |
| `--seed` | `1` | seed of the scripts and of the placement |
| `--hold` | `300` | the hold window in seconds |
| `--stop-after-hold` | off | stop the players after the hold; exit 0 only when every player entered the world and nothing failed, 1 otherwise |
| `--prepare <file>` | off | log every player in, create the missing characters, write the placement list to `<file>`, exit (see "Placement") |
| `--data-dir` | `data` | the data directory: the block data the players check their move targets against, and the placement of `--prepare` |
| `--map` | `Rou` | the map of the Crowd scenario |

A missing or invalid option prints the usage text on standard error and exits with status 2. The task connects to
WorldManager and Zone at the address and port the server sends (`0x0C0C`, `0x1003`), as the client does.

## Script per player

Each player is one process (`Load.Player`). It seeds itself with `Random.seed/1` (seed × 10 000 + its number), draws
only through `Random` and reads time only through `Clock`, so a run with the same seed sends the same moves and lines.
Players start at 50 per second.

1. Login: version check, login with name and MD5 password, world select of world 0.
2. WorldManager: world login; an account without a character creates one in slot 0 with the account's name (Fighter,
   gender 0, hair 1, hair colour 1, face 5); it skips the tutorial question.
3. Zone: map login with the 49 checksums of a 2016 client (from the transcript `26_11_15_idle_in_world.txt`),
   login complete, one heartbeat round trip.
4. Then, until the task ends: run to a point at most 90 units away in x and y every 1 to 2 s; the point is drawn
   until its cell is free and the straight line to it is not blocked in the block data of `--data-dir`, as the server
   checks it ([`movement.md`](movement.md)), so a run has close to no refused moves (a refused move or a pull back
   still puts the player where the server says), one chat line `load run <name>` every 30 s (the first one at a random
   moment), one heartbeat `0x0804` every 10 s. Heartbeats of the server are answered on the Zone and WorldManager
   connections.

## What is reported

The task prints a header line, `in the world: N of M on K maps (…)`, a line `hold started`, after the hold a line
`hold complete` and the report: connect failures, failed logins (count and the first five texts, each naming the step
and what arrived), disconnects, crashes of a player process, round-trip time (time from a `0x0804` the player sends on
its Zone connection to the `0x0805` answer: samples, minimum, median, maximum in ms), moves sent and refused, chat lines
sent. Without `--stop-after-hold` the players play on and the report is printed again every 60 s until Ctrl-C.

The task never computes the capacity figures. They are read on the server: `bin/pinata rpc "Pinata.Figures.reset()"`
at `hold started`, `bin/pinata rpc "Pinata.Figures.print()"` at `hold complete` ([`telemetry.md`](telemetry.md)).

## Scenarios

- **Crowd** ([Crowd scenario](../../GLOSSARY.md)): every player on one map (`--map`, default `Rou`), each on a
  random free cell of the whole map. When the players stand on more than one map the task prints
  `the players stand on K maps: was the placement applied?`.
- **World** ([World scenario](../../GLOSSARY.md)): "in proportion to the original's four-zone split" is read as:
  every plain field map (the `FieldList` rows with `KQ = 0` and no sub-map range, 88 with the 2016 data; the
  original's zones 0 to 3 ran 30 / 28 / 27 / 3 of them) gets the same number of players, so each original zone gets
  players in proportion to its number of maps. Player `i` goes to map `(i - 1) mod 88` in file order, on a random free
  cell. The other reading, a quarter of the players per original zone, was not chosen.

## Placement

A new character stands on the start map. The server has no map change, no GM command and no teleport yet, so players
are placed through the database, by an operator command that exists in the release like the account commands and
reads the list from standard input; it therefore works on a remote server over SSH or `docker compose exec -T`.

The list is computed by the task: `--prepare <file>` logs every player in (creating the missing characters), then
writes one line `name,map,x,y` per player (free cells only, from the block data of `--data-dir`; Crowd: one map,
World: the maps round-robin). Then place it, in one of three forms:

```
mix pinata.character.place < placement.csv                                       # from source
bin/pinata eval "Persistence.Release.place_characters()" < placement.csv          # release
docker compose exec -T login /app/bin/pinata eval 'Persistence.Release.place_characters()' < placement.csv
```

The characters must not be in the world: a character in the world writes its own position when it is saved. The
messages of the command: [`accounts.md`](../user/accounts.md), "Placing characters".

## Procedure

Single-node on SQLite (`login.auto_create_accounts` on, the accounts are created at the first login with `--password`):

```
ulimit -n 4096                     # in the shell of the node and of the task
_build/prod/rel/pinata/bin/pinata start
MIX_ENV=test mix pinata.load --scenario crowd --players 100 --prepare /tmp/placement.csv --data-dir data
_build/prod/rel/pinata/bin/pinata eval "Persistence.Release.place_characters()" < /tmp/placement.csv
MIX_ENV=test mix pinata.load --scenario crowd --players 100 --hold 300
# at "hold started": bin/pinata rpc "Pinata.Figures.reset()"; at "hold complete": bin/pinata rpc "Pinata.Figures.print()"
```

Compose stack with PostgreSQL (auto-create is off in multi-node mode): first the accounts,
`printf 'load\n' | docker compose exec -T login /app/bin/pinata eval 'Persistence.Release.create_accounts("load", 2500)'`,
then `--prepare`, the placement with `docker compose exec -T`, the run and the figures as above.

## Limits

- Every player holds two sockets (three during login), on the machine of the task and on the server: raise
  `ulimit -n` on both.
- Create many hashes every password: 2500 accounts take minutes. Auto-create in single-node mode hashes at the first
  login instead.
- On one machine the task's own load is part of what the server measures.
- The task loads the block data of all plain field maps (about 90 MB) and needs the data directory on its machine; a
  character on another map fails its login with `no block data for map <map>`.

## CI smoke run

The job `load-smoke` of `.github/workflows/server.yml` builds the release, imports the data, starts the release in
single-node mode and runs `mix pinata.load --host 127.0.0.1 --port 9010 --scenario crowd --players 50 --hold 10
--stop-after-hold` (the accounts are created at their first login; without `--prepare` the new characters stand on the
start map). It then prints `Pinata.Figures.print()`, stops the node and fails on a non-zero exit of the task or an
`[error]` line in the node output. It never fails on latency. `test/load_test.exs` runs the same code (`Load.run/1`)
against the test application with 3 players: prepare, place on `Rou` (not the start map), run; it asserts map and
position at entry and that no move is refused.

Locally, after `MIX_ENV=prod mix release`, with the data directory in `data`
(`_build/prod/rel/pinata/bin/pinata eval "GameData.Release.import_data(~S(<repo>/original-data/9Data), ~s(data))"`),
run the commands of the job's steps with `R=_build/prod/rel/pinata` and a temporary directory for `$RUNNER_TEMP`
(macOS: `ulimit -n 4096` first). Afterwards remove `data` and the SQLite files the node made.

## Code layout

| File | What |
|---|---|
| `mix.exs` | the alias `pinata.load` = `run --no-start test/support/load.exs`, preferred environment `test` |
| `test/support/load.exs` | loads the support files it needs and calls `Load.main(System.argv())` |
| `test/support/load.ex` | `Load`: options, ramp, hold, report, `run/1`, `ok?/1` |
| `test/support/load/player.ex` | `Load.Player`: the script of one player |
| `test/support/load/placement.ex` | `Load.Placement`: the plain field maps and the placement list |
