# User documentation

For administrators: how to install, configure, run and manage the Pinata server.

The server cannot be played on yet. Once you have imported a data directory (see [`install.md`](install.md)), `iex -S mix` in `server/` starts all three parts in single-node mode on the default settings; the parts are still empty, so no port is opened yet.

## Tasks

`mix pinata.import_data <9Data folder> <new data directory>` (in `server/`) creates the data directory from an original `9Data` folder; see [`install.md`](install.md).

`mix pinata.packets_doc` (in `server/`) writes `docs/technical/packets.md` from the packet definitions. Run it after changing a packet definition; `mix check` fails on a stale file.

## Pages

| Page | Content |
|---|---|
| [`install.md`](install.md) | the data directory and its import, start-up errors (the release part is still missing) |
| [`settings.md`](settings.md) | every setting |

## Not written yet

Each page is written by the first change that builds what it describes:

| Page | Content |
|---|---|
| `quick-start.md` | single-node start with no configuration, pointing the client at it |
| `release.md` | building the release |
| `multi-node.md` | PostgreSQL, the node list, which part runs where |
| `accounts.md` | creating accounts |
| `operation.md` | start and stop, migrations, logs, start-up failures |
| `gm-commands.md` | GM commands |
