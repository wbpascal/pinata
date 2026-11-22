# Security

For administrators: what to do so that a server reachable by other people stays secure. This page grows with the server; each version that adds a port, a secret or an access setting adds its advice here.

The server treats everything a client sends as untrusted. What it cannot protect is listed under "Limits of the client protocol".

## Network

- **Open only the three client ports** to players: `login.port`, `world_manager.port` and `zone.port` (see [`settings.md`](settings.md)).
- **Never open the database** or the ports the nodes use to talk to each other to the internet.
- **Multi-node mode:** keep the nodes on a network only your machines can reach. Anyone who can reach a node and knows the cookie can run code on all nodes (see [`multi-node.md`](multi-node.md)).

## Secrets

- **Cookie (`RELEASE_COOKIE`):** replace the cookie of the example with a long random value and keep it secret.
- **Database URL:** a `postgres://` URL holds the database password. Make the settings file readable only by the user the server runs as. Replace the database password of the Compose example.
- **Database and its backups:** they hold the accounts and the password hashes. Store backups where only you can read them.

## Accounts

- **Turn off `login.auto_create_accounts` on a public server.** It is on by default in single-node mode, and then anyone who reaches the Login port can create accounts. Create accounts yourself (see [`accounts.md`](accounts.md)).
- **Block an account** you suspect of abuse with `Persistence.Release.block` (see [`accounts.md`](accounts.md)).

## Connection limits

`connection.max_packets_per_second` and `connection.max_unsent_bytes` disconnect a client that floods the server or does not read. Keep the defaults unless honest players are disconnected.

- The chat spam filter blocks the chat of a player who sends too many lines of normal chat or shout (values from `SpamerPenaltyRule.shn` and `SpamerPenalty.shn`, no setting; see "Chat" in `operation.md`).
- A line of chat or shout carries at most 76 item links; a line with more is dropped with an `info` line.

## Server log

Watch for these lines (see [`operation.md`](operation.md)); many of one kind from one peer suggest an attack or a modified client:

- `connection closed: packet rate exceeded`
- `connection closed: unsent bytes exceeded`
- client protocol violations (unknown opcode, wrong first packet, wrong version key)
- many `login refused` lines for one account or from one peer

## Telemetry export

With `telemetry.otlp_enabled` the node opens outbound connections to the OTLP endpoint and opens no port. The exported data holds part names, packet names, map names, world numbers and durations, no account name, address or packet content. A secret for the Collector (an authentication header) belongs in the environment variable `OTEL_EXPORTER_OTLP_HEADERS`, not in the settings file. With the default `false` nothing leaves the node.

## Running the server

- Run it as a user of its own without administrator rights.
- Move to each new version; `CHANGELOG.md` names the fixes.

## Limits of the client protocol

The unmodified 2016 client cannot be changed, so these remain:

- **The password is readable on the network path** between the player and the server. Tell players to use a password they use nowhere else.
- **All game traffic is readable and changeable on the network path** for the same reason.
