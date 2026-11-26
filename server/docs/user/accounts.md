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
| Change it | `Persistence.Release.block` and `unblock` (below) | `Persistence.set_login_able/2`, no command yet (see the end of this page) |

When an account is both blocked and not login-able, the player sees the blocked message. A wrong password is reported as a wrong password whatever the flags say.

The original server kept login-able per account group (member, closed beta, test, admin) and could close a whole group at once. This server has no groups, so the flag is set per account.

## Names

A name is 1 to 255 printable ASCII characters (`!` to `~`), no spaces. Names are compared without regard to case and to trailing spaces, so `Bob` and `bob` are the same account (*inferred* from the original server).

## Commands

Run them from the release with `bin/pinata eval`, or from a source checkout with `mix` in `server/` (see [`from-source.md`](from-source.md)). They use the same settings file and `DATABASE_URL` as the node and may run while the node runs. On SQLite they migrate the database first; on PostgreSQL they refuse while migrations are pending (see [`operation.md`](operation.md)).

| Action | From the release | From source |
|---|---|---|
| create | `bin/pinata eval "Persistence.Release.create_account(~s(<name>))"` | `mix pinata.account.create <name>` |
| create many | `bin/pinata eval "Persistence.Release.create_accounts(~s(<prefix>), <count>)"` | `mix pinata.account.create --count <n> --prefix <prefix>` |
| block | `bin/pinata eval "Persistence.Release.block(~s(<name>))"` | `mix pinata.account.block <name>` |
| unblock | `bin/pinata eval "Persistence.Release.unblock(~s(<name>))"` | `mix pinata.account.unblock <name>` |

Create many makes the accounts `<prefix>0001` to `<prefix><count>` (the number has four digits, the count is 1 to 9999), for example `load0001` to `load2500` for a [load run](../technical/load-run.md). It asks for the password once and gives it to every account. A name that exists already is skipped and counted. It ends with `Created <n> accounts, <m> existed already: <first> to <last>.` Every account hashes its password, so 2500 accounts take some minutes.

Create asks `Password: `. The password is echoed while you type it. The game client sends the MD5 of the typed password, so the server stores the hash of that MD5; that the client's MD5 covers only the typed password is not yet verified against a capture.

Every command exits non-zero with one of these messages:

| Message | Meaning |
|---|---|
| `No password given.` | empty input or end of input at the prompt |
| `An account named <name> exists already.` | the name is taken (case and trailing spaces ignored) |
| `The database failed; see the log line above.` | the database could not be reached or queried |
| `<name> is not a valid account name: ...` | breaks the name rules above |
| `No account named <name>.` | block or unblock of a missing account |
| `The count must be 1 to 9999.` | create many with a count outside 1 to 9999 |
| `Usage: mix pinata.account.create <name> \| --count <n> --prefix <prefix>`, `Usage: mix pinata.account.block <name>` (alike for unblock) | wrong arguments |

The setting `login.auto_create_accounts` exists (see [`settings.md`](settings.md)); at login, an unknown name is created when it applies (it is on in single-node mode) and the stored password is the one sent at that first login; a name that is not valid gets the same refusal as a wrong password. There is no command for the login-able flag yet: call `Persistence.set_login_able/2` from `bin/pinata remote` or `iex`.

## Placing characters

This command exists for the [load run](../technical/load-run.md): it puts characters on a map and position before they enter the world. It reads one line `<character name>,<map>,<x>,<y>` per character from standard input and sets the stored map and position of those characters of world 0, all or nothing.

| From the release | From source |
|---|---|
| `bin/pinata eval "Persistence.Release.place_characters()" < placement.csv` | `mix pinata.character.place < placement.csv` |
| Compose: `docker compose exec -T login /app/bin/pinata eval 'Persistence.Release.place_characters()' < placement.csv` | |

Names are compared without regard to ASCII letter case. The map is a map name (letters, digits, `_`, `-`, at most 12 characters); `x` and `y` are whole numbers from 0. Empty lines and a `\r` at the line end are ignored. Run it only for characters that are not in the world: a character in the world writes its own position when it is saved. It ends with `Placed <n> characters.` or exits non-zero with one of these messages, and then nothing was placed:

| Message | Meaning |
|---|---|
| `No placement lines given.` | empty input |
| `Line <n> is not <character name>,<map>,<x>,<y>: "<line>"` | a malformed line |
| `No character named <name> in world 0; nothing was placed.` | an unknown character |
| `The database failed; see the log line above.` | the database could not be reached or queried |
| `Usage: mix pinata.character.place < <file with name,map,x,y lines>` | an argument was given |
