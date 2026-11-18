# User documentation

For administrators: how to install, configure, run and manage the Pinata server.

The server cannot be played on yet. `iex -S mix` in `server/` starts an application with no parts, so no port is opened.

## Development tasks

`mix pinata.packets_doc` (in `server/`) writes `docs/technical/packets.md` from the packet definitions. Run it after changing a packet definition; `mix check` fails on a stale file.

## Pages

None yet. Each page is written by the first change that builds what it describes:

| Page | Content |
|---|---|
| `quick-start.md` | single-node start with no configuration, pointing the client at it |
| `install.md` | mise, building the release, the data directory |
| `settings.md` | every setting |
| `multi-node.md` | PostgreSQL, the node list, which part runs where |
| `accounts.md` | creating accounts |
| `operation.md` | start and stop, migrations, logs, start-up failures |
| `gm-commands.md` | GM commands |
