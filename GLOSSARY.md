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

**Data directory**:
The folder a node reads its client data tables, server data tables, scripts and geometry from, produced by the import task.
_Avoid_: 9Data, resource folder

**Settings**:
The operational values an administrator sets per node: addresses, ports, worlds, database.
_Avoid_: config, server info

### Simulation

**Map instance**:
One running copy of a map with everything on it: players, monsters, NPCs, drops. A field map has one for the life of its Zone node; instance content (Kingdom Quest, instance dungeon, mini-house) gets one per run.
_Avoid_: map (alone, when the running copy is meant), field, room, channel

**Handle**:
The 16-bit number by which the client knows an object on its map. Unique within one map instance; its range tells the object type.
_Avoid_: object id, entity id

**Tick**:
One step of a map instance's time, in which movement, monster behaviour, combat and expiry advance.
_Avoid_: frame, pass, loop

**Bot**:
A player with no connection, driven by the server instead of a client.
_Avoid_: test client (that one talks over the network), NPC, fake player

**Level ceiling**:
The highest level the unmodified client can be told about: 255, for players, monsters and every level requirement alike. Fixed; no data can raise it.
_Avoid_: maximum level, level limit (alone)

**Level cap**:
The highest level a character can reach on a running server. Set by the server data tables, never above the level ceiling.
_Avoid_: maximum level, level ceiling

### Delivery

**Milestone**:
A slice of the rebuild that is usable with the real client on its own.
_Avoid_: phase, stage

**Capture checkpoint**:
A point where a milestone waits for named packet captures and a manual check with the real client before it may close.
_Avoid_: gate

**Original-server bug**:
Behaviour of the original server judged unintended, listed in the bug register. Fixed silently unless the fix changes packets or gameplay.

### Testing

**Capture**:
A recording of real traffic between the unmodified client and the original server, with its scenario notes.
_Avoid_: dump, trace, pcap (that is its file format)

**Transcript**:
The decrypted packets of one capture in order, per connection and direction, in a form tests read.
_Avoid_: fixture, decoded capture

**Replay test**:
A test that sends a transcript's client packets to the new server and requires the server packets it answers with to equal the transcript's.
_Avoid_: capture test, golden test

**Test client**:
The stand-in for the game client that tests use to talk to the new server over the network.
_Avoid_: simulated client, fake client, bot (a bot is a player without a connection)

**Mask**:
A named packet field that a replay test does not compare because its value cannot match the capture.
_Avoid_: ignore list, wildcard

**Handle map**:
The pairing a replay test builds between identifiers the original server handed out and the ones the new server hands out, which must stay consistent for the whole replay.
