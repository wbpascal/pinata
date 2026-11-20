# Multi-node

In multi-node mode the three parts (Login, WorldManager, Zone) run on separate nodes, which can be separate machines or containers. A node is in multi-node mode when it does not run all three parts or when `cluster.nodes` is not empty; with the defaults it is in single-node mode (see [`quick-start.md`](quick-start.md)).

## What you need

- **PostgreSQL.** All nodes use one database, so `database.url` (or `DATABASE_URL`) must be a `postgres://` URL, the same on every node. SQLite works only in single-node mode: a node that runs only some parts, or has `cluster.nodes` set, does not start on it. Run the migrations once, before the nodes of a new version start: `bin/pinata eval "Persistence.Release.migrate()"` (see [`operation.md`](operation.md)).
- **The same data directory on every node** (see [`install.md`](install.md)); see the check below.
- **The release or the image** (see [`install.md`](install.md)).

## Per node

| What | How |
|---|---|
| parts | `PINATA_PARTS` is a comma-separated list of `login`, `world_manager` and `zone`; each node of the example runs one |
| node list | `cluster.nodes` in the settings file lists the nodes to connect to, for example `["pinata@login", "pinata@wm", "pinata@zone"]` (see [`settings.md`](settings.md)) |
| node name | `RELEASE_NODE` (for example `pinata@wm`), with `RELEASE_DISTRIBUTION=sname` for short names (long names need host names with a dot) |
| cookie | `RELEASE_COOKIE`; all nodes need the same one, and anyone who knows it can run code on the nodes. Change the cookie of the example and keep the nodes on a network only your machines can reach |
| address clients use | `public_host` in the settings file, with the client ports (`login.port`, `world_manager.port`, `zone.port`) published or reachable on that address |

`login.auto_create_accounts` defaults to off in multi-node mode. Create accounts with `bin/pinata eval "Persistence.Release.create_account(~s(<name>))"` (see [`accounts.md`](accounts.md)).

## Data directory check

Every node computes a digest (SHA-256) of its data directory at start-up and logs it (`GameData: data directory digest ...`). When a node without the WorldManager part connects to a node with it and the digests differ, the node prints this to standard error and stops with exit status 1:

```
Data directory digest mismatch, the node stops:
  this node (pinata@zone): <digest of this node>
  WorldManager node (pinata@wm): <digest of the WorldManager node>
Every node must use the same data directory.
```

The WorldManager node logs an error naming the refused node. The check happens when the two nodes connect, so a node runs unchecked until it has seen the WorldManager node. The digest covers every file of the data directory (path, size and content) except `pinata.db*` at its top level; symlinked directories inside the data directory are not checked either. Single-node mode computes nothing.

## Example: Docker Compose

Download `compose.yaml` and `compose.toml` of a version from the [releases page](https://github.com/wbpascal/pinata/releases) into one directory. They start PostgreSQL, run the migrations once, and start one container per part, all from one image: `ghcr.io/wbpascal/pinata` with the tag of that version, which `docker compose up` pulls from the GitHub container registry (see [`install.md`](install.md), also for the `docker login ghcr.io` needed while the repository is private). The nodes read `compose.toml` and the data directory `data` beside the two files (read-only). The ports 9010, 9110 and 9210 are published on the host, so the client connects to `127.0.0.1:9010`. To run your own build instead, see [`from-source.md`](from-source.md).

`compose.yaml`:

```yaml
# Multi-node example: PostgreSQL and one container per part. See docs/user/multi-node.md.
x-node: &node
  image: ghcr.io/wbpascal/pinata:0.1.0
  volumes:
    - ./compose.toml:/etc/pinata/pinata.toml:ro
    - ./data:/data:ro
  depends_on:
    migrate:
      condition: service_completed_successfully

x-env: &env
  DATABASE_URL: postgres://pinata:pinata@postgres/pinata
  PINATA_CONFIG: /etc/pinata/pinata.toml
  RELEASE_DISTRIBUTION: sname
  RELEASE_COOKIE: change-this-cookie

services:
  postgres:
    image: postgres:18
    environment:
      POSTGRES_USER: pinata
      POSTGRES_PASSWORD: pinata
      POSTGRES_DB: pinata
    volumes:
      - postgres:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U pinata"]
      interval: 2s
      timeout: 5s
      retries: 30

  migrate:
    <<: *node
    environment: *env
    command: ["eval", "Persistence.Release.migrate()"]
    restart: "no"
    depends_on:
      postgres:
        condition: service_healthy

  login:
    <<: *node
    hostname: login
    environment:
      <<: *env
      PINATA_PARTS: login
      RELEASE_NODE: pinata@login
    ports: ["9010:9010"]

  wm:
    <<: *node
    hostname: wm
    environment:
      <<: *env
      PINATA_PARTS: world_manager
      RELEASE_NODE: pinata@wm
    ports: ["9110:9110"]

  zone:
    <<: *node
    hostname: zone
    environment:
      <<: *env
      PINATA_PARTS: zone
      RELEASE_NODE: pinata@zone
    ports: ["9210:9210"]

volumes:
  postgres:
```

`compose.toml`:

```toml
# Settings of the Docker Compose example (compose.yaml), shared by all three nodes.
data_dir = "/data"
# The address clients use to reach the published ports.
public_host = "127.0.0.1"

[cluster]
nodes = ["pinata@login", "pinata@wm", "pinata@zone"]
```

First import the data directory into `data` beside the two files, with the release archive of your machine (see [`install.md`](install.md), "The data directory"; the data directory is the same on every platform). Then, in that directory:

```
docker compose up -d
printf 'my-password\n' | docker compose exec -T login /app/bin/pinata eval "Persistence.Release.create_account(~s(<name>))"
docker compose logs -f
docker compose down -v
```

On Windows (Docker Desktop with Linux containers, PowerShell; the recommended way to run multi-node mode there) start the second command with `'my-password' |` in place of `printf 'my-password\n' |`; the others are unchanged. These commands were not tried on Windows.

`down -v` also deletes the database volume; `docker compose down` keeps it. The password of the example database and its cookie are for a trial on one machine only.

To move to a new version, download the `compose.yaml` of the new version (its image tag is the new version) over the old one, run `docker compose up -d` again, and read "Moving from the previous version" in the changelog section of the new version (see [`operation.md`](operation.md), "Moving to a new version"). Compose runs the migrations of the new version before it starts the nodes. `compose.toml` and the database volume stay.
