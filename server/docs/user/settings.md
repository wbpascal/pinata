# Settings

<!-- Generated from `Settings.Schema` by `Settings.Doc.render/0`. Do not edit by hand: see "Settings" in server/docs/technical/README.md. -->

A node reads its settings once, at start-up, from one TOML file. Every key has a default, so the file is optional:
with no file the node starts in single-node mode on the data directory `./data`, which must exist (see [`install.md`](install.md)).

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `PINATA_CONFIG` | `pinata.toml` in the working directory | Path of the settings file. The default file may be missing; a path set here must exist. |
| `PINATA_PARTS` | `login,world_manager,zone` | The parts this node starts, separated by commas. A part that is not listed opens no port. |
| `DATABASE_URL` | not set | Overrides `database.url`, so the secret can stay out of the file. |

## Keys

| Key | Type | Default | Meaning |
|---|---|---|---|
| `data_dir` | string | `"./data"` | The data directory, written by `mix pinata.import_data` (see install.md). The node does not start without it. |
| `public_host` | string | `"127.0.0.1"` | The address the client is told to connect to. |
| `client_version_key` | string | `"20151116141627"` | The version key a client must send at login. The default is the key of the 2016 client. |
| `login.port` | integer 1 to 65535 | `9010` | Client listener of the Login part. |
| `login.auto_create_accounts` | boolean | see description | Create an account at the first login with an unknown name. Default: `true` when all parts run on this node and `cluster.nodes` is empty, else `false`. |
| `world_manager.port` | integer 1 to 65535 | `9110` | Client listener of the WorldManager part. |
| `zone.port` | integer 1 to 65535 | `9210` | Client listener of the Zone part, one per Zone node. |
| `[[world]] number` | integer, 0 or more | `0` | World number. |
| `[[world]] name` | string | `"INITIO"` | World name. |
| `database.url` | string | see description | Database URL. Default: the SQLite file `pinata.db` in `data_dir`. The environment variable `DATABASE_URL` overrides it. |
| `cluster.nodes` | list of strings | `[]` | Names of the other nodes (`name@host`). Empty means single-node mode. |
| `data.strict_references` | boolean | `true` | Refuse to start when a data table refers to a row that does not exist. |

A key with a dot is written inside a table: `login.port` is `port` under `[login]`. Each world is one `[[world]]` table.

```toml
public_host = "203.0.113.7"

[login]
port = 9010

[[world]]
number = 0
name = "INITIO"
```

## Start-up errors

The node checks the whole file before it starts anything. A key it does not know, a value of the wrong type, a file
that is not valid TOML, a `PINATA_CONFIG` path that cannot be read and an unknown name in `PINATA_PARTS` are all
errors. It prints every problem at once to standard error, each with its key, its value and what was expected, and
does not start:

```
Invalid settings, the node does not start:
  bogus: unknown key
  login.port: invalid value for :port option: expected one of 1..65535, got: 0
```

After the settings the node loads its game data. If `data_dir` does not exist, or a data table is damaged, it prints
the problems and does not start. Both cases are described in [`install.md`](install.md).
