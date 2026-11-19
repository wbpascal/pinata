# Quick start

1. Import a data directory from an original `9Data` folder (see [`install.md`](install.md)).
2. In `server/`, run `iex -S mix` with no settings file. All three parts start in single-node mode; the Login part listens on port 9010.
3. Point the client at the address of this machine and port 9010. How a client install is told the address depends on the client install.
4. Log in with any new name and password. In single-node mode `login.auto_create_accounts` is on, so the account is created at the first login with the password you typed (see [`accounts.md`](accounts.md) and [`settings.md`](settings.md)).
5. The client shows the world list with the world `INITIO`.

That is as far as the server goes: selecting the world does not work yet.

## What the player sees on a refusal

| Case | Client text |
|---|---|
| wrong password, or an unknown name with auto-create off | Please check ID or Password. |
| blocked account | The ID has been blocked. |
| account not login-able | The World Servers are down for maintenance. |
| `client_version_key` differs from the client's | the client's wrong-version message; the connection is closed |
