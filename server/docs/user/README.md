# User documentation

For administrators: how to install, configure, run and manage the Pinata server.

The server cannot be played on yet. Once you have imported a data directory (see [`install.md`](install.md)), `iex -S mix` in `server/` starts all three parts in single-node mode on the default settings; each part listens on its port (9010, 9110 and 9210 by default). A client can connect and is kept alive by the heartbeat, but cannot log in yet. It creates the SQLite database `./data/pinata.db`.

## Tasks

`mix pinata.import_data <9Data folder> <new data directory>` (in `server/`) creates the data directory from an original `9Data` folder; see [`install.md`](install.md).

`mix pinata.packets_doc` (in `server/`) writes `docs/technical/packets.md` from the packet definitions. Run it after changing a packet definition; `mix check` fails on a stale file.

Database and accounts (see [`operation.md`](operation.md) and [`accounts.md`](accounts.md)):

- `mix pinata.migrate` runs the pending database migrations.
- `mix pinata.account.create <name>` creates an account; it asks for the password.
- `mix pinata.account.block <name>` and `mix pinata.account.unblock <name>` block and unblock an account.

## Pages

| Page | Content |
|---|---|
| [`install.md`](install.md) | the data directory and its import, start-up errors (the release part is still missing) |
| [`settings.md`](settings.md) | every setting |
| [`accounts.md`](accounts.md) | creating, blocking and unblocking accounts |
| [`operation.md`](operation.md) | database and migrations; start, stop and logs follow |

## Not written yet

Each page is written by the first change that builds what it describes:

| Page | Content |
|---|---|
| `quick-start.md` | single-node start with no configuration, pointing the client at it |
| `release.md` | building the release |
| `multi-node.md` | PostgreSQL, the node list, which part runs where |
| `gm-commands.md` | GM commands |
