# Changelog

## 0.2.0 – Enter the world (unreleased)

A character enters the world: the client loads the map, walks and runs, takes gates and town portals to other maps, sees other players and the standing NPCs, and chats (normal, shout, whisper). Logging out, a lost connection and a second login of the account save the character, and a character can be renamed on the character list. Maps have no mobs yet, and items and skills do not work.

### New

- A node with the Zone part reads the map and NPC tables of the data directory at start-up (`FieldList`, `ShineNPC`, `LinkTable`, `Common` of `ChrCommon`, `MobInfo.shn`, `TownPortal.shn`, `SpamerPenalty.shn`, `SpamerPenaltyRule.shn`) and does not start when one is missing or damaged. Files of the data directory are found whatever the letter case of their names (#105).
- A node with the Zone part runs one map instance per field map (88 with the original data), places the NPCs of `ShineNPC` and logs how many rows it skipped. It does not start when the `.shbd` file of a field map is missing or damaged; the error names the map (#106).
- In multi-node mode each Zone node reports its own `public_host` and `zone.port` to WorldManager (#106).
- Selecting a character on the character list hands the client to the Zone node that runs the character's stored map; when that map runs nowhere, the client is told "The Map is under maintenance" and an `info` line names the map. A character that has not started the tutorial is asked first; skipping it enters the world (#107).
- The Client data check: a client whose copy of one of 49 client tables differs from the server's is refused at the map login with "The client has been illegally manipulated…", and a `warning` line names the table and both hashes. A node with the Zone part does not start when one of the 49 files is missing; the error names the file (#107).
- A character that enters the world passes the loading screen and stands on its stored map at its stored position, wearing its equipment. Inventory, skills, quests, titles and the shortcut bar are empty until their milestones (#108).
- A client packet that belongs to the protocol but is not built yet is ignored with a `debug` line; before, it closed the connection. A packet outside the protocol still closes it (#108).
- Players on a map see each other and the standing NPCs: when they enter the map, when they come into or leave each other's sight, and when one leaves the map. A player in a crowd (29 or more objects within 500 units) gets the players of a smaller radius at entry, as in the original. A map without `MapInfo` row and an NPC without `MobInfo` row are logged with an `info` line at start-up (#109).
- Renaming a character on the character list when the client asks for a new name: the name rules of creation with at most 16 bytes; a name in use is refused. The rename right is always refused until items exist (#117).
- `bin/pinata rpc "Pinata.Figures.print()"` prints the two capacity figures (packet handling time, tick duration) as bucket counts with the 50th and 99th percentile, merged over all nodes and per node; `Pinata.Figures.reset()` clears them (#118).
- Traces and metrics can be exported over OpenTelemetry (OTLP): the settings `telemetry.otlp_enabled` (default `false`), `telemetry.otlp_endpoint` and `telemetry.trace_ratio` (default `0.01`). The release includes the OpenTelemetry libraries; with the default nothing is exported and no connection is opened (#118).

### Differences from the original server

- Skipping the tutorial enters the world on the character's stored map; the original refused the login after the skip (P02-B33) (#107).
- A refused map login carries the real refusal code; the original sent another one (Z01-B1) (#107).
- Objects in different dimensions no longer get an appear and a delete packet on every step (P02-B27) (#109).
- A client request for the appear packet of an object (`0x1C01`) is answered only when the object is in sight (#109).
- A rename onto a name that is in use is refused ("The name cannot be used."); the original renamed anyway and two characters shared the name (P02-B42) (#117).
- The refusal of the rename right carries the slot of the request; the original sent a byte of its own memory (P02-B34) (#117).

### Moving from the previous version

- `public_host` must be an IPv4 address in text form on a node with the Zone part (every single-node setup): a node with a host name there does not start (#106).
- The data directory: one made by the import of 0.1.0 already holds the tables and geometry files that 0.2.0 reads and needs no new import. Import again only a directory that was trimmed or edited by hand and now fails the start-up check (#105).

## 0.1.0 – Login to character select (2026-11-21)

The first version: the unmodified 2016 client logs in, sees the world list, selects a world and lists, creates and deletes its characters; entering the game does not work yet. The server runs as one node with SQLite, on Linux, macOS and Windows, or as one node per part with PostgreSQL. It comes as release archives for four platforms and as a container image, and is set up with one settings file and a data directory imported from an original `9Data` folder.

### New

- Every version is published as release archives for Linux (x86_64, arm64), Windows (x86_64) and macOS (arm64), and as the container image `ghcr.io/wbpascal/pinata` for linux/amd64 and linux/arm64; the Docker Compose example pulls that image (#76).
- The user documentation starts from the release archive and the image; building from source is on its own page, `from-source.md`. The start-up error for a missing data directory names the release command first (#77).
- One settings file, `pinata.toml` (path in `PINATA_CONFIG`), in which every key is optional; a node with a wrong setting prints every problem and does not start. `PINATA_PARTS` chooses the parts a node runs, `DATABASE_URL` overrides `database.url` (#35).
- The data directory: `GameData.Release.import_data` (or `mix pinata.import_data`) makes it from an original `9Data` folder; a node checks it at start-up and does not start on a missing directory or a damaged table (`data.strict_references`) (#43).
- Accounts in SQLite (default `sqlite:./data/pinata.db`, migrated at start-up) or PostgreSQL (migrated with `Persistence.Release.migrate()`; a node does not start while migrations are pending), and commands to create, block and unblock accounts (#38).
- Login: the client version check against `client_version_key`, account login with the client's messages for a wrong password, a blocked and a not login-able account, accounts created at the first login (`login.auto_create_accounts`, on in single-node mode), and the world list. A second login of the same account cuts off the first (#41).
- Selecting a world in the world list takes the client to the world's character list (#42).
- The character list, and the server time the client asks for (#44).
- Character creation, with the original's name rules (1 to 20 bytes, `BadNameFilter`), the level rule for the Sentinel class and the starting values of the data directory (#45).
- Character deletion; the name is free again at once (#46).
- Going back from the character list to the world list, and quitting from the character list (#47).
- Multi-node mode: Login, WorldManager and Zone on separate nodes with PostgreSQL (`cluster.nodes`); a node whose data directory differs from that of the WorldManager node stops. A Docker Compose example runs one container per part (#48).
- SQLite only in single-node mode: a node of a multi-node setup does not start on a `sqlite:` URL. A client packet of the wrong size is dropped instead of closing the connection (#71).
- Windows: single-node mode with SQLite (#72).
- Client connections with the original's framing and cipher, the original's heartbeat (a check after 30 s of silence, close after 180 s more), and limits on the packet rate and on unsent data (`connection.max_packets_per_second`, `connection.max_unsent_bytes`) (#37).
- The server log: listeners, the node start, every connection the server closes and why, login outcomes, cluster events, and a one-line error for a port already in use; `log.level` sets the lowest level printed (#73).

### Differences from the original server

- WorldManager accepts a client only for the account Login selected the world for, and only within 30 s; the original took any account name the client sent and kept the selection forever (W01-B1) (#42).
- A refused character creation sends the code that matches the reason, so the client shows "error in the Max Slot Number" for a wrong or used slot, "wrong class" for the Sentinel level rule and "Failed to create the character." for an invalid name or a database failure; the original reported these as a taken name or with a code the client shows nothing for (W01-B2, D02-B1) (#45).
- An expired token for going back to the world list is always refused; the original could still accept one (L01-B9) (#47).
- A refused world select sends a zeroed key where the original sent 64 bytes of its own memory (P02-B23) (#42).
- The answer to a client of the wrong version sends 0 in a byte the original never wrote (L00-B1) (#41).
- The character list sends zeros where the original sent stale delete information, and both the character list and the answer to a character creation send zeros in two date bits the original left unset (P02-B1, P02-B7) (#44, #45).
