# Settings

<!-- Generated from `Settings.Schema` by `Settings.Doc.render/0`. Do not edit by hand: see "Settings" in docs/technical/README.md. -->

A node reads its settings once, at start-up, from one TOML file. Every key has a default, so the file is optional:
with no file the node starts in single-node mode on the data directory `./data`, which must exist (see [`install.md`](install.md)).

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `PINATA_CONFIG` | `pinata.toml` in the working directory | Path of the settings file. The default file may be missing; a path set here must exist. |
| `PINATA_PARTS` | `login,world_manager,zone` | The parts this node starts, separated by commas. A part that is not listed opens no port. |
| `DATABASE_URL` | not set | Overrides `database.url`, so the secret can stay out of the file. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | not set | The OTLP endpoint when `telemetry.otlp_enabled` is true and `telemetry.otlp_endpoint` is not set. |

## Keys

| Key | Type | Default | Meaning |
|---|---|---|---|
| `data_dir` | string | `"./data"` | The data directory, written by `bin/pinata eval "GameData.Release.import_data(...)"`, from a source checkout by `mix pinata.import_data` (see install.md). The node does not start without it. |
| `public_host` | string, at most 15 bytes | `"127.0.0.1"` | The address the client is told to connect to. Login sends it together with its own `world_manager.port` when a world is selected, so in multi-node mode set both on the Login node to where the WorldManager node is reached. On a node with the Zone part it must be an IPv4 address in text form (`203.0.113.7`), not a host name: the Zone node reports it to WorldManager, which sends it to the client in a 16-byte field. |
| `client_version_key` | string | `"20151116141627"` | The version key a client must send at login. The default is the key of the 2016 client. |
| `login.port` | integer 1 to 65535 | `9010` | Client listener of the Login part. |
| `login.auto_create_accounts` | boolean | see description | Create an account at the first login with an unknown name. Default: `true` when all parts run on this node and `cluster.nodes` is empty, else `false`. |
| `world_manager.port` | integer 1 to 65535 | `9110` | Client listener of the WorldManager part. |
| `zone.port` | integer 1 to 65535 | `9210` | Client listener of the Zone part, one per Zone node. |
| `[[world]] number` | integer 0 to 255 | `0` | World number. |
| `[[world]] name` | string, at most 15 bytes | `"INITIO"` | World name, sent to the client in the world list. The 2016 client does not show it: each row of its world list is a picture from the client's own files, picked by the row (the first world shows "Enid"). The client only writes the name to its log `%APPDATA%\FiestaOnline\ConnectWorldInfo.txt` when the world is selected. |
| `database.url` | string | see description | Database URL: `sqlite:<path>` or `postgres://user:password@host/database`. Default: the SQLite file `pinata.db` in `data_dir`. SQLite works only in single-node mode; in multi-node mode the node does not start without a `postgres://` URL. The environment variable `DATABASE_URL` overrides it. |
| `cluster.nodes` | list of strings | `[]` | Names of the other nodes (`name@host`). Empty means single-node mode. |
| `connection.max_packets_per_second` | integer, 1 or more | `100` | A client that sends more packets than this within one second is disconnected. |
| `connection.max_unsent_bytes` | integer, 1 or more | `1048576` | A client with more than this many bytes of unsent outbound data is disconnected. |
| `log.level` | `"debug"`, `"info"`, `"warning"` or `"error"` | `"info"` | The lowest level the server log prints (see operation.md). |
| `data.strict_references` | boolean | `true` | Refuse to start when a data table refers to a row that does not exist. |
| `telemetry.otlp_enabled` | boolean | `false` | Export traces and metrics over OTLP (OpenTelemetry). When `false` nothing is exported and no connection is opened, whatever the `OTEL_*` environment variables say. See operation.md. |
| `telemetry.otlp_endpoint` | string, an `http://` or `https://` URL | see description | The OTLP endpoint (HTTP), for example `http://collector:4318`. It wins over the environment variable `OTEL_EXPORTER_OTLP_ENDPOINT`. Default: that variable, else `http://localhost:4318`. |
| `telemetry.trace_ratio` | number 0 to 1 | `0.01` | The share of packets and ticks exported as trace spans. Metrics and the capacity figures count every packet and tick. |

A key with a dot is written inside a table: `login.port` is `port` under `[login]`. Each world is one `[[world]]` table.

```toml
public_host = "203.0.113.7"

[login]
port = 9010

[[world]]
number = 0
name = "INITIO"
```

## OpenTelemetry variables

With `telemetry.otlp_enabled = true` the standard variables of the OpenTelemetry SDK work as upstream documents them:
`OTEL_EXPORTER_OTLP_HEADERS`, `OTEL_EXPORTER_OTLP_PROTOCOL`, `OTEL_RESOURCE_ATTRIBUTES`, `OTEL_SERVICE_NAME` (default
`pinata`) and the others ([SDK configuration](https://opentelemetry.io/docs/languages/sdk-configuration/),
[`opentelemetry_exporter`](https://hexdocs.pm/opentelemetry_exporter/)). `OTEL_TRACES_SAMPLER`, when set, replaces
`telemetry.trace_ratio`. With `telemetry.otlp_enabled = false` none of them has an effect.

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
