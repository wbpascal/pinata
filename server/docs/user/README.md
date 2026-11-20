# User documentation

For administrators: how to install, configure, run and manage the Pinata server.

The server cannot be played on yet. You build a release (or the container image), import a data directory (see [`install.md`](install.md)) and start it (see [`operation.md`](operation.md)); with the default settings it starts all three parts in single-node mode, each listening on its port (9010, 9110 and 9210 by default), and creates the SQLite database `./data/pinata.db`. A client can log in, sees the world list, selects the world and sees its character list; entering the game does not work yet (see [`quick-start.md`](quick-start.md)). The parts can also run on separate nodes (see [`multi-node.md`](multi-node.md)).

## Tasks

Release commands (`bin/pinata eval "<expression>"`, in place of the mix tasks where there is no `mix`):

- `GameData.Release.import_data(~s(<9Data folder>), ~s(<new data directory>))` for `mix pinata.import_data`.
- `Persistence.Release.migrate()`, `Persistence.Release.create_account(~s(<name>))`, `Persistence.Release.block(~s(<name>))` and `Persistence.Release.unblock(~s(<name>))` for the database and account tasks below.

A string inside the expression is written `~s(...)`, not in double quotes: that form works in every shell, also on Windows. [`install.md`](install.md), section "Windows", lists what differs on Windows. The `mix` tasks are the same there.

`mix pinata.import_data <9Data folder> <new data directory>` (in `server/`) creates the data directory from an original `9Data` folder; see [`install.md`](install.md).

`mix pinata.packets_doc` (in `server/`) writes `docs/technical/packets.md` from the packet definitions. Run it after changing a packet definition; `mix check` fails on a stale file.

Database and accounts (see [`operation.md`](operation.md) and [`accounts.md`](accounts.md)):

- `mix pinata.migrate` runs the pending database migrations.
- `mix pinata.account.create <name>` creates an account; it asks for the password.
- `mix pinata.account.block <name>` and `mix pinata.account.unblock <name>` block and unblock an account.

## Pages

| Page | Content |
|---|---|
| [`quick-start.md`](quick-start.md) | single-node start with no configuration, pointing the client at it, logging in |
| [`install.md`](install.md) | the release, what differs on Windows, the container image, the data directory and its import, start-up errors |
| [`settings.md`](settings.md) | every setting |
| [`accounts.md`](accounts.md) | creating, blocking and unblocking accounts |
| [`operation.md`](operation.md) | start, stop, logs, start-up failures, memory, time zone, database and migrations |
| [`multi-node.md`](multi-node.md) | PostgreSQL, the node list, which part runs where, the data directory check, a Docker Compose example |

## Not written yet

Each page is written by the first change that builds what it describes:

| Page | Content |
|---|---|
| `gm-commands.md` | GM commands |
