# User documentation

For administrators: how to install, configure, run and manage the Pinata server.

The server cannot be played on yet. `iex -S mix` in `server/` starts all three parts in single-node mode on the default settings; the parts are still empty, so no port is opened yet. It creates the SQLite database `./data/pinata.db`.

## Development tasks

`mix pinata.packets_doc` (in `server/`) writes `docs/technical/packets.md` from the packet definitions. Run it after changing a packet definition; `mix check` fails on a stale file.

Database and accounts (see [`operation.md`](operation.md) and [`accounts.md`](accounts.md)):

- `mix pinata.migrate` runs the pending database migrations.
- `mix pinata.account.create <name>` creates an account; it asks for the password.
- `mix pinata.account.block <name>` and `mix pinata.account.unblock <name>` block and unblock an account.

## Pages

| Page | Content |
|---|---|
| [`settings.md`](settings.md) | every setting |
| [`accounts.md`](accounts.md) | creating, blocking and unblocking accounts |
| [`operation.md`](operation.md) | database and migrations; start, stop and logs follow |

## Not written yet

Each page is written by the first change that builds what it describes:

| Page | Content |
|---|---|
| `quick-start.md` | single-node start with no configuration, pointing the client at it |
| `install.md` | mise, building the release, the data directory |
| `multi-node.md` | PostgreSQL, the node list, which part runs where |
| `gm-commands.md` | GM commands |
