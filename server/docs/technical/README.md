# Technical documentation

How the server is built now. The reasons are in the ADRs (`docs/adr/`), the behaviour of the original server in `docs/protocol/` and `docs/pseudocode/`.

## Parts and boundaries

The server is one Mix project, application `:pinata` ([ADR 0001](../../../docs/adr/0001-single-mix-project-with-checked-boundaries.md)). Each top-level namespace is a boundary, and the `boundary` compiler fails the build on a reference that the table does not allow.

| Boundary | Kind | What | May use |
|---|---|---|---|
| `Login` | part | the Login part | all libraries |
| `WorldManager` | part | the WorldManager part | all libraries |
| `Zone` | part | the Zone part | all libraries |
| `Net` | library | client listener and connection process | `Proto`, `Settings`, `Clock`, `Random` |
| `Proto` | library | framing, cipher, packet definitions | `Clock`, `Random` |
| `Persistence` | library | database access ([`persistence.md`](persistence.md)) | `Settings`, `Clock`, `Random` |
| `Cluster` | library | registry and the facades between parts | `Settings`, `Clock`, `Random` |
| `GameData` | library | client and server data tables, their import | `Clock`, `Random` |
| `Settings` | library | the settings of the node, read once at start-up | nothing |
| `Clock` | library | the only reader of system time | nothing |
| `Random` | library | the only caller of `:rand` | nothing |
| `Pinata.Application` | application | starts the supervision tree | the parts, `Persistence`, `Cluster`, `Settings`, `GameData` |

A part never uses another part. `Proto` and `Net` are built; each part starts a client listener. Login handles the login path and the world select (see [`flows/login.md`](flows/login.md), [`flows/world-select.md`](flows/world-select.md)); WorldManager handles the hand-over login `0x0C0F`, sends the character list ([`flows/character-list.md`](flows/character-list.md)) and handles `0x0C33` and `0x0C18` (see [`flows/return-to-world-list.md`](flows/return-to-world-list.md)); Zone has a stub packet handler. `Persistence` has the tables `accounts`, `characters` and `items`; the other libraries are almost empty.

ADR 0001 calls the protocol library `Protocol`. Elixir already has a core module of that name, so the module is `Proto`.

```mermaid
flowchart TD
    App[Pinata.Application] --> Login & WorldManager & Zone
    Login & WorldManager & Zone --> Net & Proto & Persistence & Cluster & GameData
    Net --> Proto
    Net & Proto & Persistence & Cluster & GameData --> Clock & Random
```

The diagram leaves out three sets of arrows that the table has: the parts also use `Clock` and `Random`, the application uses `Persistence`, `Cluster` and `GameData`, and `Net` uses `Settings`. Every part, `Persistence`, `Cluster` and the application also use `Settings`.

## Start-up

`Pinata.Application.start/2` calls `Settings.load(System.get_env())`. On problems it prints them all to standard error and returns `{:error, :invalid_settings}`. Then it calls `GameData.load/3` with the tables of the parts in `PINATA_PARTS` (`game_data/0` of each part); on problems it prints them all and returns `{:error, :invalid_game_data}`. Otherwise, in multi-node mode only (not all parts on the node, or `cluster.nodes` not empty; `Settings.single_node?/1`), it computes `GameData.digest/1` of the data directory, logs it and adds `Cluster.DataDigest` (see [`cluster.md`](cluster.md)); single-node mode hashes nothing. Then `Pinata.Supervisor` (`:one_for_one`) starts `Persistence.Supervisor`, `Cluster.Root`, `Cluster.DataDigest` (multi-node only), then one supervisor per part in `PINATA_PARTS`, each with the settings as its argument. `Persistence.Supervisor` starts the repo chosen by `database.url` and the migration step. Two start failures come from it: an unusable `database.url` (`{:error, :invalid_database_url}`) and, on PostgreSQL, pending migrations (`{:error, :pending_migrations}`); both print their message to standard error. Each part supervisor starts its client listener; the WorldManager supervisor first starts one `WorldManager.World` process per world.

```mermaid
flowchart TD
    S[Pinata.Supervisor] --> P[Persistence.Supervisor] & C[Cluster.Root] & L[Login.Supervisor] & W[WorldManager.Supervisor] & Z[Zone.Supervisor]
```

## Release, image and compose

`mix.exs` defines one release, `pinata` (`releases: [pinata: [include_executables_for: [:unix]]]`); `MIX_ENV=prod mix release` builds `_build/prod/rel/pinata`. A release has no `mix`, so the operator commands are plain functions called with `bin/pinata eval`: `Persistence.Release` (migrations, accounts) and `GameData.Release.import_data/2`. `server/Dockerfile` builds the release in a `hexpm/elixir` stage and copies it into a plain Debian stage; its image tags must follow `mise.toml` (Erlang and Elixir versions). `server/compose.yaml` and `server/compose.toml` are the multi-node example (PostgreSQL, one `migrate` run, one container per part); [`multi-node.md`](../user/multi-node.md) embeds both verbatim and `test/compose_doc_test.exs` checks that. The CI job `compose-smoke` imports the data directory, starts the compose file, creates the account `smoke` and runs `test/support/compose_smoke.exs` (see [`testing.md`](testing.md)).

## Processes

[`processes.md`](processes.md) describes the listener and the connection process.

## Settings

`Settings` loads the TOML file and the environment, `Settings.Schema` holds the NimbleOptions schema, `Settings.Doc` renders [`docs/user/settings.md`](../user/settings.md) from it. NimbleOptions stops at the first error, so `Settings.Schema.validate/1` walks the schema and sends each leaf through `NimbleOptions.validate/2` alone; that way every problem is reported together. There is no release config provider (the release reads `PINATA_CONFIG` and the other variables at start-up through `Settings.load/1`, like `mix`); `Toml.decode/1` in `start/2` behaves the same everywhere.

A new key goes into `Settings.Schema` and the type `Settings.t()`. Then regenerate the page: `mix run --no-start -e 'File.write!("docs/user/settings.md", Settings.Doc.render())'`. `server/test/settings_doc_test.exs` fails when it is stale.

## Game data

`GameData` loads the tables of the node's parts from the data directory before any supervisor starts and serves look-ups from `persistent_term`; `mix pinata.import_data` makes the data directory. Both are described in [`game-data.md`](game-data.md).

## Cluster registry

`Cluster.Registry` names the processes and keeps the `:pg` groups; `Cluster.Sessions` and the facade `Cluster.WorldManager` carry what one part asks of another. The detail is in [`cluster.md`](cluster.md). See [ADR 0002](../../../docs/adr/0002-fail-simple-cluster-model.md).

## Persistence

Two Ecto repos (PostgreSQL, SQLite) sit behind `Persistence`; the adapter follows `database.url`. SQLite migrates itself at start-up, PostgreSQL refuses to start while migrations are pending. See [`persistence.md`](persistence.md).

## Protocol

[`protocol.md`](protocol.md) describes framing, cipher and packet definitions; [`packets.md`](packets.md) lists the defined packets (generated).

## Time and randomness

Server code reads time through `Clock` and random numbers through `Random`, never directly ([ADR 0008](../../../docs/adr/0008-byte-compatibility-proven-by-capture-replay.md)). Each forwards to a source module taken from the application environment (`:clock_source`, `:random_source`), so a test can put its own source in place. `Clock.local_time/1` turns a Unix time into local wall-clock time (the system source uses the time zone of the operating system).

## Testing

[`testing.md`](testing.md) describes the transcripts under `server/test/replay/transcripts/` and how a capture is converted into one. It also describes the test client and the replay harness in `server/test/support/`.

## The gate

`mix check` and the three custom Credo checks in `server/credo/checks/` are described in [`server/AGENTS.md`](../../AGENTS.md). Each check has a probe file in `server/test/probes/` that breaks its rule, and a test that requires the check to report it.
