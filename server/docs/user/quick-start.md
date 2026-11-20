# Quick start

From a clean machine to the client's world list, in single-node mode (all three parts in one process, SQLite, no settings file). You need the release archive of your platform and an original `9Data` folder (the one with the `Shine` folder inside). No Erlang, no Elixir and no clone of this repository. To build the server yourself, see [`from-source.md`](from-source.md).

1. Download the release archive of your platform from the [releases page](https://github.com/wbpascal/pinata/releases/latest): `pinata-<version>-linux-x86_64.tar.gz`, `pinata-<version>-linux-arm64.tar.gz` or `pinata-<version>-macos-arm64.tar.gz`. What each needs is in [`install.md`](install.md).
2. Unpack it in a terminal, in the directory the server should run in: `tar -xzf pinata-<version>-<platform>.tar.gz`. This makes the directory `pinata-<version>`, the release.
3. Import the data directory, in the same directory: `pinata-<version>/bin/pinata eval "GameData.Release.import_data(~s(<9Data folder>), ~s(./data))"`. It must report more than 0 tables.
4. Start the server, in the same directory: `pinata-<version>/bin/pinata start`. The Login part listens on port 9010, WorldManager on 9110, Zone on 9210. The database `./data/pinata.db` is created.
5. Point the client at the address of this machine and port 9010. How a client install is told the address depends on the client install. If the client is on another machine, set `public_host` to this machine's address (see [`settings.md`](settings.md)).
6. Log in with any new name and password. In single-node mode `login.auto_create_accounts` is on, so the account is created at the first login with the password you typed (see [`accounts.md`](accounts.md)).
7. The client shows the world list with the world `INITIO`. Selecting it works and the client shows the character list. Entering the game does not work yet: the Zone part is a stub.

Stop the server with `Ctrl-C` twice, or with `pinata-<version>/bin/pinata stop` from another terminal (see [`operation.md`](operation.md)).

## On Windows

Steps 1 to 4 differ (PowerShell; see [`install.md`](install.md), section "Windows", for `cmd` and for why the commands differ):

1. Download `pinata-<version>-windows-x86_64.zip` from the releases page.
2. Unpack it in the directory the server should run in: `Expand-Archive pinata-<version>-windows-x86_64.zip .` (or "Extract All" in Explorer). This makes the directory `pinata-<version>`.
3. In the same directory: `pinata-<version>\bin\pinata eval "GameData.Release.import_data(~s(C:/Fiesta/9Data), ~s(./data))"`. It must report more than 0 tables.
4. In the same directory: `pinata-<version>\bin\pinata start`.

Stop the server with `pinata-<version>\bin\pinata stop` from another window. Windows supports single-node mode with SQLite; for multi-node mode see [`install.md`](install.md), section "Windows".

## What the player sees on a refusal

| Case | Client text |
|---|---|
| wrong password, or an unknown name with auto-create off | Please check ID or Password. |
| blocked account | The ID has been blocked. |
| account not login-able | The World Servers are down for maintenance. |
| `client_version_key` differs from the client's | the client's wrong-version message; the connection is closed |
