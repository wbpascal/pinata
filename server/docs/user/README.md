# User documentation

For administrators: how to install, configure, run and manage the Pinata server.

The server cannot be played on yet. `iex -S mix` in `server/` starts all three parts in single-node mode on the default settings; each part listens on its port (9010, 9110 and 9210 by default). A client can connect and is kept alive by the heartbeat, but cannot log in yet.

## Development tasks

`mix pinata.packets_doc` (in `server/`) writes `docs/technical/packets.md` from the packet definitions. Run it after changing a packet definition; `mix check` fails on a stale file.

## Pages

| Page | Content |
|---|---|
| [`settings.md`](settings.md) | every setting |

## Not written yet

Each page is written by the first change that builds what it describes:

| Page | Content |
|---|---|
| `quick-start.md` | single-node start with no configuration, pointing the client at it |
| `install.md` | mise, building the release, the data directory |
| `multi-node.md` | PostgreSQL, the node list, which part runs where |
| `accounts.md` | creating accounts |
| `operation.md` | start and stop, migrations, logs, start-up failures |
| `gm-commands.md` | GM commands |
