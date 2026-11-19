# Quick start

From a clean machine to the client's world list, in single-node mode (all three parts in one process, SQLite, no settings file). You need a clone of this repository and an original `9Data` folder (the one with the `Shine` folder inside).

1. Install the tools: `mise install` at the repository root.
2. Fetch the dependencies and build the release: in `server/`, `mix deps.get`, then `MIX_ENV=prod mix release` (see [`install.md`](install.md)).
3. Import the data directory, in `server/`: `_build/prod/rel/pinata/bin/pinata eval 'GameData.Release.import_data("<9Data folder>", "./data")'`.
4. Start the server in `server/`: `_build/prod/rel/pinata/bin/pinata start`. The Login part listens on port 9010, WorldManager on 9110, Zone on 9210. The database `./data/pinata.db` is created. (From a source checkout, `mix pinata.import_data <9Data folder> data` and `iex -S mix` do the same without a release.)
5. Point the client at the address of this machine and port 9010. How a client install is told the address depends on the client install. If the client is on another machine, set `public_host` to this machine's address (see [`settings.md`](settings.md)).
6. Log in with any new name and password. In single-node mode `login.auto_create_accounts` is on, so the account is created at the first login with the password you typed (see [`accounts.md`](accounts.md)).
7. The client shows the world list with the world `INITIO`. Selecting it works and the client shows the character list. Entering the game does not work yet: the Zone part is a stub.

Stop the server with `Ctrl-C` twice, or with `bin/pinata stop` when it was started with `daemon` (see [`operation.md`](operation.md)).

## What the player sees on a refusal

| Case | Client text |
|---|---|
| wrong password, or an unknown name with auto-create off | Please check ID or Password. |
| blocked account | The ID has been blocked. |
| account not login-able | The World Servers are down for maintenance. |
| `client_version_key` differs from the client's | the client's wrong-version message; the connection is closed |
