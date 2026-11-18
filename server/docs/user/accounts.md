# Accounts

An account has a name, a password, a *blocked* flag and a *login-able* flag. A player can log in only when the account is neither blocked nor missing the login-able flag. New accounts are not blocked and are login-able.

## Names

A name is 1 to 255 printable ASCII characters (`!` to `~`), no spaces. Names are compared without regard to case and to trailing spaces, so `Bob` and `bob` are the same account (*inferred* from the original server).

## Commands

Run them in `server/` with `mix`, or from a release with `bin/pinata eval`. They use the same settings file and `DATABASE_URL` as the node and may run while the node runs. On SQLite they migrate the database first; on PostgreSQL they refuse while migrations are pending (see [`operation.md`](operation.md)).

| Action | From source | From a release |
|---|---|---|
| create | `mix pinata.account.create <name>` | `bin/pinata eval 'Persistence.Release.create_account("<name>")'` |
| block | `mix pinata.account.block <name>` | `bin/pinata eval 'Persistence.Release.block("<name>")'` |
| unblock | `mix pinata.account.unblock <name>` | `bin/pinata eval 'Persistence.Release.unblock("<name>")'` |

Create asks `Password: `. The password is echoed while you type it. The game client sends the MD5 of the typed password, so the server stores the hash of that MD5; that the client's MD5 covers only the typed password is not yet verified against a capture.

Every command exits non-zero with one of these messages:

| Message | Meaning |
|---|---|
| `No password given.` | empty input or end of input at the prompt |
| `An account named <name> exists already.` | the name is taken (case and trailing spaces ignored) |
| `<name> is not a valid account name: ...` | breaks the name rules above |
| `No account named <name>.` | block or unblock of a missing account |
| `Usage: mix pinata.account.create <name>` (alike for the others) | wrong number of arguments |

The setting `login.auto_create_accounts` exists (see [`settings.md`](settings.md)); login itself comes with a later change. There is no command for the login-able flag yet: call `Persistence.set_login_able/2` from `bin/pinata remote` or `iex`.
