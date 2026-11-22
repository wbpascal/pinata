# Changelog

## 0.2.0 – Enter the world (unreleased)

A character enters the world: the client loads the map, walks and runs, takes gates and town portals to other maps, sees other players and the standing NPCs, and chats (normal, shout, whisper). Logging out, a lost connection and a second login of the account save the character, and a character can be renamed on the character list. Maps have no mobs yet, and items and skills do not work.

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
