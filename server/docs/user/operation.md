# Operation

Start, stop and logs are written together with the release.

## Time zone

The in-game clock and the stored dates shown to the client (for example the Kingdom Quest date in the character list) use the time zone of the node's operating system. Set the `TZ` environment variable to change it.

## Character creation

A character name has 1 to 20 bytes, no space, and must pass `shn/BadNameFilter.shn` of the data directory. The Sentinel class needs a character of the level in the row `ChrLevel_CanCreateSen` of `shn/SingleData.shn` on the same account and world. The starting values (map, position, level, items, skills, shortcuts) come from `tables/DefaultCharacterData/*.csv` of the data directory. A change to these files needs a restart.

A database created by an earlier build must be deleted: the initial migration gained columns and tables.

## Database and migrations

`database.url` (or the environment variable `DATABASE_URL`) has two forms:

- `sqlite:<path>`: the default is `sqlite:./data/pinata.db`. The file and its directory are created and migrated at every start. Nothing to do.
- `postgres://user:password@host/database`: the node refuses to start while migrations are pending. Run them once before you start the nodes of a new version:
  `bin/pinata eval "Persistence.Release.migrate()"` from a release, or `mix pinata.migrate` in `server/`.

Start-up errors from the database:

| Message | Meaning |
|---|---|
| `database.url: unknown scheme: "...", expected sqlite:<path> or postgres://user:password@host/database` | the URL form is not one of the two |
| `database.url: unknown scheme: a URL without scheme, expected ...` | the URL has no `scheme:` part at all (for example a bare file path) |
| `database.url: cannot create the directory of <path> (...)` | the directory of the SQLite file cannot be created |
| `The database has N pending migration(s): ...` | PostgreSQL only; run the migrate command named in the message |
