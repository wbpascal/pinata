# From source

Building the server yourself, instead of using a release archive or the published image (see [`install.md`](install.md)). You need a clone of this repository. Everything else on these pages works the same with a release you built.

## Tools

Install the tools with `mise install` at the repository root (Erlang and Elixir, versions in `mise.toml`), then `mix deps.get`, also at the root. Every command on this page runs at the repository root. For the container image you need Docker instead (or as well).

On Windows, install mise first (for example `winget install jdx.mise`) and activate it in your shell as its documentation describes; then the same two commands apply. No C compiler is needed: the SQLite library is downloaded prebuilt.

### Line ends

The repository's `.gitattributes` makes every text file LF on every platform, whatever `core.autocrlf` says; `mix format --check-formatted` and some tests depend on it. A clone made before that rule came in still has CRLF files; check them out again once, in the repository root, with no changes of your own in it: `git rm -r --cached -q .` and then `git reset --hard`.

## The release

`MIX_ENV=prod mix release` builds `_build/prod/rel/pinata` (add `--overwrite` to build again over an existing one). In PowerShell that is `$env:MIX_ENV = "prod"; mix release`, in `cmd` `set MIX_ENV=prod` and then `mix release`. The directory is the same release a release archive holds: its own Erlang runtime and the compiled server, for the operating system and CPU architecture of the build machine. Copy the whole directory; `_build/prod/rel/pinata/bin/pinata` is the `bin/pinata` of the other pages.

## The container image

`docker build -t pinata .` builds an image with the release, started with `bin/pinata start` as an unprivileged user; the published image is built from the same `Dockerfile`. On Windows the same command works with Docker Desktop and Linux containers; the image holds the Linux release whatever the host.

To run the Docker Compose example of [`multi-node.md`](multi-node.md) on your own build, build the image under the name `compose.yaml` uses: `docker build -t ghcr.io/wbpascal/pinata:<version> .` (the tag in `compose.yaml`). `docker compose up` then uses it and pulls nothing.

## Without a release

`iex -S mix` starts the same node as `bin/pinata start`, with the same settings file, environment variables and data directory.

## The `mix` tasks

Each in place of a release command of the other pages:

| Task | Release command | What it does |
|---|---|---|
| `mix pinata.import_data <9Data folder> <new data directory>` | `bin/pinata eval "GameData.Release.import_data(~s(<9Data folder>), ~s(<new data directory>))"` | creates the data directory (see [`install.md`](install.md)); on Windows it takes a path with backslashes as it is |
| `mix pinata.migrate` | `bin/pinata eval "Persistence.Release.migrate()"` | runs the pending database migrations (see [`operation.md`](operation.md)) |
| `mix pinata.account.create <name>` | `bin/pinata eval "Persistence.Release.create_account(~s(<name>))"` | creates an account; it asks for the password (see [`accounts.md`](accounts.md)) |
| `mix pinata.account.create --count <n> --prefix <prefix>` | `bin/pinata eval "Persistence.Release.create_accounts(~s(<prefix>), <n>)"` | creates the accounts `<prefix>0001` to `<prefix><n>` with one password, asked once (see [`accounts.md`](accounts.md)) |
| `mix pinata.character.admin_level <character name> <level> [--world <n>]` | `bin/pinata eval "Persistence.Release.set_admin_level(~s(<character name>), <level>)"` (a third argument names the world) | sets the admin level of a character, which makes it a GM (see [`gm-commands.md`](gm-commands.md)) |
| `mix pinata.character.place < <file>` | `bin/pinata eval "Persistence.Release.place_characters()" < <file>` | sets the stored map and position of characters from `name,map,x,y` lines (see [`accounts.md`](accounts.md), "Placing characters") |
| `MIX_ENV=test mix pinata.load --scenario world\|crowd --players <n> …` | none | developer task: the load run against a running server (see [`../technical/load-run.md`](../technical/load-run.md)) |
| `mix pinata.account.block <name>`, `mix pinata.account.unblock <name>` | `bin/pinata eval "Persistence.Release.block(~s(<name>))"`, `unblock` alike | block and unblock an account |
| `mix pinata.packets_doc` | none | writes `docs/technical/packets.md` from the packet definitions. Run it after changing a packet definition; `mix check` fails on a stale file |
