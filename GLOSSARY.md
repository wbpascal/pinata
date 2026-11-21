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

**Server log**:
The lines a node writes about its own operation for the administrator: start-up, connections, failures.
_Avoid_: log (alone), debug output, console output

**Game log**:
The stored record of what players did, kept so an administrator can verify what happened and restore a lost item by hand.
_Avoid_: log (alone), audit log, action log

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

**Sight radius**:
The distance, set per map, within which objects of one map instance are told about each other.
_Avoid_: area of interest, view range

**In sight**:
Two objects are in sight of each other when they are within the sight radius and allowed to see each other.

**Dimension**:
A number on every object of a map instance; objects with different numbers are not in sight of each other. Everyone is in dimension 0 unless a GM moves.
_Avoid_: main layer, layer (reserved for the tutorial's separate copy of a map)

**Sub-layer**:
The visibility class of an object, which says one way at a time who may see whom; a hidden GM sees players who do not see the GM.

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

**Milestone map**:
The planning issue of one milestone. It is opened early to collect points for that milestone and charted into tickets when the milestone before closes.

**Capture checkpoint**:
A point where a milestone waits for named packet captures and a manual check with the real client before it may close.
_Avoid_: gate

**Release**:
The self-contained server directory for one operating system and CPU, holding its own runtime. It is the same thing whether downloaded or built from source.
_Avoid_: binary release, build, binaries

**Version**:
A numbered, published state of the server, made when a milestone closes. A milestone is not closed until its version exists.
_Avoid_: release (that is the directory), milestone release

**Release archive**:
The downloadable file that holds the release of one version for one platform.
_Avoid_: binary, download, package

**Changelog**:
The record of what each version changed for an administrator or a player: a title, a short summary of the most important changes, and every change one of them can observe. Internal work is not in it.
_Avoid_: release notes, history

**Original-server bug**:
Behaviour of the original server judged unintended, listed in the bug register. Fixed silently unless the fix changes packets or gameplay.

**User documentation**:
What an administrator needs to run and manage the rebuilt server, one page per task.
_Avoid_: admin guide, manual

**Technical documentation**:
How the rebuilt server is built and how it talks to the client, at the level of parts, processes and flows. It says how things are; the reasons are in the ADRs.
_Avoid_: architecture docs, developer docs

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

**Deferral**:
A packet or packet field that a replay test does not compare yet because the milestone that builds its data has not landed. It names that milestone, which removes it.
_Avoid_: mask (a mask never goes away), skip, placeholder (that is what the server sends meanwhile)

**Handle map**:
The pairing a replay test builds between identifiers the original server handed out and the ones the new server hands out, which must stay consistent for the whole replay.

**Load run**:
A manual run in which many test clients play a fixed script against a server to check the capacity targets. It is part of a milestone's capture checkpoint.
_Avoid_: load test (alone), stress test, benchmark

**Capacity figure**:
One of the two measured values a load run passes or fails on: packet handling time and tick duration.
_Avoid_: metric, KPI, latency

**World scenario**:
The load run that spreads the full player count of one world over its maps.
_Avoid_: spread test, world test

**Crowd scenario**:
The load run that puts the full player count of one map instance on a single map instance, spread over the whole map.
_Avoid_: zone test, single-map test
