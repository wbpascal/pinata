# User documentation

For administrators: how to install, configure, run and manage the Pinata server.

The server cannot be played on yet. You download the release archive of your platform or the container image, import a data directory (see [`install.md`](install.md)) and start it (see [`operation.md`](operation.md)); with the default settings it starts all three parts in single-node mode, each listening on its port (9010, 9110 and 9210 by default), and creates the SQLite database `./data/pinata.db`. A client can log in, sees the world list, selects the world and sees its character list; entering the game does not work yet (see [`quick-start.md`](quick-start.md)). The parts can also run on separate nodes (see [`multi-node.md`](multi-node.md)).

## Commands

`bin/pinata` of the release (see [`operation.md`](operation.md)): `start`, `daemon`, `stop`, `pid`, `remote` and `eval "<expression>"`. The tasks run with `eval`:

- `GameData.Release.import_data(~s(<9Data folder>), ~s(<new data directory>))` creates the data directory from an original `9Data` folder (see [`install.md`](install.md)).
- `Persistence.Release.migrate()` runs the pending database migrations (see [`operation.md`](operation.md)).
- `Persistence.Release.create_account(~s(<name>))` creates an account; it asks for the password. `Persistence.Release.block(~s(<name>))` and `Persistence.Release.unblock(~s(<name>))` block and unblock an account (see [`accounts.md`](accounts.md)).

A string inside the expression is written `~s(...)`, not in double quotes: that form works in every shell, also on Windows. [`install.md`](install.md), section "Windows", lists what differs on Windows.

From a source checkout each of these has a `mix` task; they are listed in [`from-source.md`](from-source.md).

## Pages

| Page | Content |
|---|---|
| [`quick-start.md`](quick-start.md) | single-node start with no configuration, pointing the client at it, logging in |
| [`install.md`](install.md) | the release archive, the container image, the data directory and its import, what differs on Windows, start-up errors |
| [`from-source.md`](from-source.md) | building the release and the image yourself, starting without a release, the `mix` tasks |
| [`settings.md`](settings.md) | every setting |
| [`accounts.md`](accounts.md) | creating, blocking and unblocking accounts |
| [`operation.md`](operation.md) | start, stop, logs, start-up failures, memory, time zone, database and migrations, moving to a new version |
| [`multi-node.md`](multi-node.md) | PostgreSQL, the node list, which part runs where, the data directory check, a Docker Compose example |

## Not written yet

Each page is written by the first change that builds what it describes:

| Page | Content |
|---|---|
| `gm-commands.md` | GM commands |
