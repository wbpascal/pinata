# Accounts

An account has a name, a password and two flags, *blocked* and *login-able*. A player can log in only when the account is not blocked and is login-able. New accounts are not blocked and are login-able.

## Blocked and login-able

Both flags refuse a login with the right password. They differ in what they mean and in what the player is told.

| | Blocked | Login-able |
|---|---|---|
| Meaning | the account is banned | the account is fine, but may not enter for now |
| The player sees | "The ID has been blocked." | "The World Servers are down for maintenance." |
| Use it to | ban one account | keep an account out without calling it banned, for example players during maintenance while staff accounts stay login-able |
| New account | not blocked | login-able |
| Change it | `mix pinata.account.block` and `unblock` (below) | `Persistence.set_login_able/2`, no command yet (see the end of this page) |

When an account is both blocked and not login-able, the player sees the blocked message. A wrong password is reported as a wrong password whatever the flags say.

The original server kept login-able per account group (member, closed beta, test, admin) and could close a whole group at once. This server has no groups, so the flag is set per account.

## Names

A name is 1 to 255 printable ASCII characters (`!` to `~`), no spaces. Names are compared without regard to case and to trailing spaces, so `Bob` and `bob` are the same account (*inferred* from the original server).

## Commands

Run them in `server/` with `mix`, or from a release with `bin/pinata eval`. They use the same settings file and `DATABASE_URL` as the node and may run while the node runs. On SQLite they migrate the database first; on PostgreSQL they refuse while migrations are pending (see [`operation.md`](operation.md)).

| Action | From source | From a release |
|---|---|---|
| create | `mix pinata.account.create <name>` | `bin/pinata eval "Persistence.Release.create_account(~s(<name>))"` |
| block | `mix pinata.account.block <name>` | `bin/pinata eval "Persistence.Release.block(~s(<name>))"` |
| unblock | `mix pinata.account.unblock <name>` | `bin/pinata eval "Persistence.Release.unblock(~s(<name>))"` |

Create asks `Password: `. The password is echoed while you type it. The game client sends the MD5 of the typed password, so the server stores the hash of that MD5; that the client's MD5 covers only the typed password is not yet verified against a capture.

Every command exits non-zero with one of these messages:

| Message | Meaning |
|---|---|
| `No password given.` | empty input or end of input at the prompt |
| `An account named <name> exists already.` | the name is taken (case and trailing spaces ignored) |
| `The database failed; see the log line above.` | the database could not be reached or queried |
| `<name> is not a valid account name: ...` | breaks the name rules above |
| `No account named <name>.` | block or unblock of a missing account |
| `Usage: mix pinata.account.create <name>` (alike for the others) | wrong number of arguments |

The setting `login.auto_create_accounts` exists (see [`settings.md`](settings.md)); at login, an unknown name is created when it applies (it is on in single-node mode) and the stored password is the one sent at that first login; a name that is not valid gets the same refusal as a wrong password. There is no command for the login-able flag yet: call `Persistence.set_login_able/2` from `bin/pinata remote` or `iex`.
