# GM commands

A GM (game master) is a character with an admin level above 0. A GM types a command into the normal chat line: a
line that starts with `&` is a command and is never shown as chat. New characters have admin level 0 and can use no
command.

## Setting the admin level

The admin level is a number from 0 to 255, stored per character. Set it with the command below. It changes only the
database: a character that is in the world keeps its old level until its next login (a map change does not reload
it).

| From the release | From source |
|---|---|
| `bin/pinata eval "Persistence.Release.set_admin_level(~s(<character name>), <level>)"` | `mix pinata.character.admin_level <character name> <level>` |
| with a world: `bin/pinata eval "Persistence.Release.set_admin_level(~s(<character name>), <level>, <world>)"` | `mix pinata.character.admin_level <character name> <level> --world <world>` |
| Compose: `docker compose exec login /app/bin/pinata eval 'Persistence.Release.set_admin_level(~s(<character name>), <level>)'` | |

The name is compared without regard to ASCII letter case. The world is a world number of the settings
(`[[world]] number`, see [`settings.md`](settings.md)); it may be left out only when exactly one world is configured.
The command uses the same settings file and `DATABASE_URL` as the node and may run while the node runs (see
[`accounts.md`](accounts.md), "Commands"). It ends with
`Admin level of <name> in world <n> set to <level>. Only the database was changed: a character in the world keeps its old level until its next login.`
or exits non-zero with one of these messages:

| Message | Meaning |
|---|---|
| `The level must be 0 to 255.` | the level is out of range |
| `More than one world is configured (<numbers>): name the world with --world <n>.` | no world given, but several are configured |
| `World <n> is not configured.` | the world number is not in the settings |
| `No character named <name> in world <n>.` | no such character in that world |
| `The database failed; see the log line above.` | the database could not be reached or queried |
| `Usage: mix pinata.character.admin_level <character name> <level> [--world <n>]` | wrong arguments of the `mix` task |

A GM sees "From <address>" (the address it connected from) and its admin level in the client at every map entry.

## The commands

| Command | Korean alias | Lowest level | What it does |
|---|---|---|---|
| `&adminlevel` | | 1 | answers "Admin level is <n>" |
| `&hide` | `&숨어` | 10 | the GM disappears for every other player (they see the GM leave); the GM gets the hide icon |
| `&show` | `&보여` | 10 | the GM is visible again; the GM and the players in sight see the hide state end. A GM that is not hidden gets no answer |
| `&dimension <n>` | | 100 | moves the GM into dimension `n`: players in another dimension see the GM leave, the GM's own view changes at once and the players of the new dimension see the GM appear. Dimension -1 sees everyone and is seen by everyone |
| `&linkto` | `&이동` | 10 | moves the GM to a random free spot of its own map |
| `&linkto <map>` | `&이동` | 10 | moves the GM to the start point of the map (`RegenX`, `RegenY` of `MapInfo`) |
| `&linkto <map> <x> <y>` | `&이동` | 10 | moves the GM to that point of the map |
| `&kickout <name>` | `&추방` | 10 | disconnects the named character from the world, on any node; its position is saved |

A player who comes back into view after `&show` appears only when the other client asks for it (when one of the
two moves); the server sends no appear of its own. A map change ends the hide and sets the
dimension back to 0; the hide icon is not shown again after it.

Answers:

| Answer | When |
|---|---|
| `Invalid command : <word>` | the word is not a command (only a GM gets it) |
| `Invalid map name` | `&linkto` with a map that does not exist, a map that is not running, or `-` |
| `<name> is banned` | `&kickout` found the character and disconnected it |
| `<name> is not in game` | `&kickout` found no character of that name in the world |

A player with admin level 0 gets no answer for any `&` line. A GM whose level is below the command's level gets no
answer either. `&linkto` with a negative coordinate moves nobody and writes the `info` line
`Zone: &linkto ignored: coordinates out of range`; no free spot found writes `Zone: &linkto ignored: no free spot found`.

## How a line is read

- Only the first 100 bytes of the line count.
- Words are separated by spaces. A `"` starts or ends a quoted part in which spaces belong to the word; the quote
  itself is dropped. A `\` takes the next character as it is (`\"`, `\\`, `\ `).
- The command word (with its `&`) is at most 20 bytes, and it is case-sensitive: `&Hide` is not a command.
- At most 12 arguments are read, each cut at 32 bytes; more are ignored.
- A number that is not a number reads as 0 (`&dimension x` is dimension 0); digits followed by other characters
  count up to the first non-digit (`12x` is 12).

## The command log

Every `&` line of a GM is written to the server log at level `info`, also an unknown word and a command above the
GM's level:

```
Zone: GM command: character "<name>": "<line>", peer <address>:<port>
```

The line is cut at 100 bytes; bytes that are not printable are written escaped. A kick also writes
`WorldManager: kicked: character "<name>"` on the node of the kicked player's session and
`Zone: connection closed: kicked` for its Zone connection. Lines of characters with admin level 0 are not logged.
