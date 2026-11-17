# Fiesta server rebuild

The language of the new Elixir server that replaces the 2016 Fiesta server binaries while speaking the unchanged client protocol.

## Language

### Deployment

**Part**:
One of the independently startable pieces of the new server: Login, WorldManager or Zone.
_Avoid_: service, component, server (alone)

**Zone node**:
A runtime instance that runs the Zone part and hosts a set of maps with the players on them. A world has one or more.
_Avoid_: zone server, zone (alone), channel

**Single-node mode**:
All parts running inside one runtime instance on one machine. The only mode that may use SQLite.
_Avoid_: offline mode (that is a use of single-node mode, not a synonym), standalone

**Multi-node mode**:
Parts spread over several connected runtime instances. Requires PostgreSQL.
_Avoid_: cluster mode, distributed mode, split mode

**World**:
One game universe with its own characters, behind a shared Login. Several may exist; one is configured for now.
_Avoid_: realm, shard, server

### Sources of truth

**Original server**:
The 2016 server binaries and the behaviour reconstructed from them in `docs/`.
_Avoid_: old server, legacy server

**Client data table**:
An SHN table the unmodified client also holds, kept byte-identical as the source of truth.
_Avoid_: game data, resource file

**Server data table**:
Game data only the server reads, free to be stored in a new format.
_Avoid_: server-only configuration, TXT config

**Settings**:
The operational values an administrator sets per node: addresses, ports, worlds, database.
_Avoid_: config, server info

### Delivery

**Milestone**:
A slice of the rebuild that is usable with the real client on its own.
_Avoid_: phase, stage

**Capture checkpoint**:
A point where a milestone waits for named packet captures and a manual check with the real client before it may close.
_Avoid_: gate

**Original-server bug**:
Behaviour of the original server judged unintended, listed in the bug register. Fixed silently unless the fix changes packets or gameplay.
