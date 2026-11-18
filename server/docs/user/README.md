# User documentation

For administrators: how to install, configure, run and manage the Pinata server.

The server cannot be played on yet. `iex -S mix` in `server/` starts all three parts in single-node mode on the default settings; the parts are still empty, so no port is opened yet.

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
