# Ecto on PostgreSQL and SQLite: gaps and portability

Research for issue #3, done 2026-11-17. Every claim cites the source that owns it. Package claims were read in the
published Hex tarballs (file and line given), not in summaries. Claims I could not check are collected in
"Not verified" at the end.

## Answer in short

- One schema and one migration set on both databases is affordable **if the persistence library stays inside a
  portable subset**: plain column types, unique indexes, `ON CONFLICT` with an explicit column target, atomic
  conditional `UPDATE`s, and no `ALTER COLUMN`. The cost is a rule list (below) and a CI run per adapter.
- The largest gap is **row locking**: `lock: "FOR UPDATE"` raises on SQLite. Write every multi-statement operation
  as a transaction of guarded updates that checks affected-row counts. That pattern is correct on both.
- On SQLite, set `default_transaction_mode: :immediate`. The default deferred mode can fail a read-then-write
  transaction with `SQLITE_BUSY` that no busy timeout cures.
- Choose the adapter by **two thin Repo modules and a run-time switch**; the `:adapter` of a Repo is fixed at
  compile time.
- SQLite in WAL mode has one writer at a time. A local probe did about 17,000 three-statement transactions per
  second. One world needs a small fraction of that, so throughput is not the limit; long transactions are.

## Versions checked (hex.pm API, 2026-11-17)

| Package | Version | Released |
|---|---|---|
| ecto | 3.14.3 | 2026-11-04 |
| ecto_sql | 3.14.0 | 2026-05-19 |
| postgrex | 0.22.4 | 2026-08-07 |
| ecto_sqlite3 | 0.26.0 | 2026-10-20 |
| exqlite | 0.43.0 | 2026-10-20 |
| db_connection | 2.10.2 | 2026-07-06 |

- exqlite 0.43.0 bundles SQLite **3.54.1** (`c_src/sqlite3.h:149`) and ships precompiled NIFs (`mix.exs:15`,
  `README.md:74`).
- PostgreSQL "current" documentation is version 18 (<https://www.postgresql.org/docs/current/transaction-iso.html>).
- Elixir requirement: ecto `~> 1.14`, ecto_sqlite3 and exqlite `~> 1.17` (their `mix.exs`). Nothing blocks 1.20.

Source of the version list: `https://hex.pm/api/packages/<name>`.

## Feature gaps that matter here

`C` = `ecto_sqlite3-0.26.0/lib/ecto/adapters/sqlite3/connection.ex`, `A` = `…/sqlite3.ex`,
`D` = `…/sqlite3/data_type.ex`, `P` = `ecto_sql-3.14.0/lib/ecto/adapters/postgres/connection.ex`.

### Column types

| Ecto type | PostgreSQL (`P:2058-2075`) | SQLite (`D:11-84`) | Consequence |
|---|---|---|---|
| `:integer` | `integer` (32-bit) | `INTEGER` (64-bit) | An overflow fails on PostgreSQL only. Validate ranges in the changeset |
| `:bigint` | `bigint` | `INTEGER` | Same on both. Use for money and item keys (original: `bigint`) |
| `:boolean` | `boolean` | `INTEGER` 0/1 | Transparent through schemas; raw SQL fragments differ |
| `:string` | `varchar` | `TEXT` | Equality is case-sensitive on both by default (`A:142-150`) |
| `:binary` | `bytea` | `BLOB` | Same. Fits packed game blobs |
| `:utc_datetime*` | `timestamp` | `TEXT` ISO 8601 | Transparent through schemas; date arithmetic in SQL is not portable |
| `:decimal` | `numeric` | `DECIMAL` affinity, encoded as text (`codec.ex:107-111`) | Avoid; use integers |
| `:map` | `jsonb` (config `:postgres_map_type`) | `TEXT` JSON, or JSONB with `map_type: :binary` | Read and write whole values only |
| `{:array, t}` | native array | JSON text | Array operators raise on SQLite (`C:840-848`, `C:1356`). Avoid arrays |
| `:binary_id` | `uuid` | `TEXT` (36 bytes) or `BLOB` | Works; integer keys are simpler here |

Neither database has unsigned integers. The original `tinyint` columns map to `:integer` plus a range validation.

### Constraints

- **Unique**: works on both. SQLite reports only the columns, so the adapter **guesses** the index name as
  `table_col1_col2_index` (`C:107-149`). `Ecto.Changeset.unique_constraint/3` therefore matches only when the index
  keeps Ecto's default name. Rule: never pass a custom `:name` to `unique_index`.
- **Foreign key**: enforced on both (the adapter turns `foreign_keys` on, `A` option list). SQLite does not say
  which constraint failed (`C:151-154`), so `foreign_key_constraint/3` "may not work at all" (`A:178-183`). Rule:
  treat a foreign-key violation as a bug, not as a user-facing result.
- **Check**: `Ecto.Migration.constraint/3` works on both since SQLite 3.53.0 (`A:160-176`). Exclusion constraints,
  `validate: false` and `drop_if_exists` for constraints raise on SQLite (`C:544`, `C:560`, `C:1647`).
- **Case-insensitive unique name**: PostgreSQL needs `citext` or an expression index, SQLite needs
  `collate: :nocase` (`A:148-158`). Neither spelling is portable. Portable form: a second column holding the
  name normalised in Elixir, with a plain unique index. SQL Server compared names case-insensitively
  (`docs/plan/db-backups.md`, "Parameter count differs"), so the rebuild has to decide this on purpose.

### Upserts

- `on_conflict: :nothing`, `{:replace, fields}`, `:replace_all`, keyword updates and queries work on both.
- SQLite **requires `:conflict_target`** for every replacing upsert and rejects `{:constraint, name}`
  (`C:596-602`). PostgreSQL accepts both. Rule: always give `conflict_target: [columns]`.
- `RETURNING` works on SQLite for insert, update and delete (`C:233-341`), with a workaround because SQLite does
  not accept a table qualifier there (`C:1118-1131`).

### Row locking

- `lock:` in a query raises `ArgumentError, "locks are not supported by SQLite3"` (`C:170-172`). There is no
  portable `SELECT … FOR UPDATE`.
- On SQLite a write transaction already excludes every other writer: "There can only be a single writer at a
  time" (<https://sqlite.org/isolation.html>).
- `Ecto.Changeset.optimistic_lock/3` is the portable alternative Ecto names (`ecto-3.14.3/lib/ecto/query.ex:2523-2525`).

### Transactions and isolation

- `Repo.transaction/2` is deprecated in favour of `Repo.transact/2` (`ecto-3.14.3/lib/ecto/repo.ex:2353`).
  `transact` commits on `{:ok, _}` and rolls back on `{:error, _}`, `Repo.rollback/1` or a raise (`repo.ex:2553-2572`).
- PostgreSQL default is Read Committed. A concurrent `UPDATE` waits, then re-evaluates its `WHERE` clause on the
  new row version (<https://www.postgresql.org/docs/current/transaction-iso.html>). Higher levels raise
  serialization failures that "applications … must be prepared to retry".
- SQLite: "all transactions in SQLite show 'serializable' isolation"; WAL mode gives readers snapshot isolation
  (<https://sqlite.org/isolation.html>).
- SQLite `BEGIN` is deferred by default. A read followed by a write upgrades the transaction, and if another
  connection wrote in between, "the write statement will fail with SQLITE_BUSY"
  (<https://sqlite.org/lang_transaction.html>). The adapter default is `:deferred` with a pool of 5 and
  `busy_timeout` 2000 ms (`A:16-18` and option list). Set `default_transaction_mode: :immediate` (`A:234-240`).
- The `:mode` option is **not portable**: exqlite accepts `:deferred | :immediate | :exclusive | :savepoint`
  (`exqlite-0.43.0/lib/exqlite/connection.ex:301-318`), postgrex only `:transaction | :savepoint`
  (`postgrex-0.22.4/lib/postgrex/protocol.ex:614-627`). Passing `mode: :immediate` to PostgreSQL has no matching
  clause. Set the mode in the SQLite repo config, never per call.
- After a constraint error PostgreSQL aborts the whole transaction (`25P02`, `repo.ex:2483-2488`); SQLite does
  not. Rule: after any failed statement, leave the transaction. Never continue in it.

### Concurrent writers

- WAL: "readers do not block writers and a writer does not block readers", but "there can only be one writer at a
  time" (<https://sqlite.org/wal.html>).
- "All processes using a database must be on the same host computer; WAL does not work over a network filesystem"
  (same page). This is the technical reason SQLite stays in single-node mode.
- A long read transaction stops checkpoints, and the WAL file "will grow without bound" (same page). Keep read
  transactions short; do not hold one across a game tick.
- `Ecto.Adapters.SQL.Sandbox` with async tests is not supported on SQLite (`A:130-135`). Tests against SQLite run
  with `async: false`, or each test gets its own database file.

### JSON

- PostgreSQL stores `:map` as `jsonb`; SQLite as JSON text by default (`D:63-75`).
- Ecto's `json_extract_path` (the `field["a"]["b"]` syntax) compiles on SQLite to `json_extract` (`C:1309-1319`).
  PostgreSQL operators such as `@>` and GIN indexes have no SQLite counterpart.
- Rule: a JSON column is an opaque value. Anything queried or indexed is a real column.

### Migrations SQLite cannot express

- `modify` raises `"ALTER COLUMN not supported by SQLite3"` (`C:1595-1597`), although SQLite 3.53.0 added
  `ALTER COLUMN … SET/DROP NOT NULL` (<https://sqlite.org/lang_altertable.html>). Changing a type, default or
  nullability needs the 12-step table rebuild from that page, written by hand in `execute/2`.
- `add` of a `:utc_datetime` or `:naive_datetime` column silently **drops `null: false`** (`C:1565-1583`).
- `ADD COLUMN` cannot be `PRIMARY KEY` or `UNIQUE`, and `NOT NULL` needs a non-null default. `DROP COLUMN` fails
  for a column that is indexed, unique, part of a key, or used by a foreign key or check
  (<https://sqlite.org/lang_altertable.html>). Drop the index first.
- Index options `concurrently`, `only`, `include`, `using`, `nulls_distinct` raise (`C:451-467`). `CASCADE` on
  drop raises (`C:579`).
- Query features that raise on SQLite: `ilike` (`C:1280`), multi-column `DISTINCT ON` (`C:717`), joins in
  `delete_all` (`C:240`), join hints (`C:901`).
- Both adapters run DDL inside a transaction (SQLite: `A:315-316`). SQLite takes no migration lock (`A:318-321`);
  PostgreSQL locks the migrations table or uses `:pg_advisory_lock` (`ecto_sql-3.14.0/lib/ecto/adapters/postgres.ex:30-40`).

Because the schema is fresh, with no imported data, most of this is avoided by one practice: **until the first
release, edit the initial migrations instead of stacking `alter` migrations.** After that, a migration that needs
`modify` branches on `repo().__adapter__()` (`repo.ex:274`, `765`) and carries a hand-written SQLite rebuild.

## Choosing the adapter

`use Ecto.Repo, adapter: …` is read at compile time (`ecto-3.14.3/lib/ecto/repo.ex:120`, `260`;
`repo/supervisor.ex:72-77`). `put_dynamic_repo/1` switches the running instance, not the adapter (`repo.ex:901-946`).

| Option | How | Cost |
|---|---|---|
| Build time | `adapter: Application.compile_env(:app, :repo_adapter)` | One Repo module. Two builds; CI recompiles to test the other adapter |
| **Start-up (recommended)** | `Repo.Postgres` and `Repo.SQLite`, both compiled. The persistence library calls `repo()`, which reads run-time config. Only the chosen one is started | Two three-line modules. Both drivers are in every release |

Reasons for the start-up switch: one release artefact covers single-node and multi-node mode, and CI tests both
adapters without recompiling. Both repos point at the same migrations with the `:priv` option (`repo.ex:36`).
The persistence library is the only code that may name a Repo module.

## Transaction patterns that replace the stored procedures

The original procedures (read with `tools/protocol-re/bak.py`, *(db-backup)*):

- `p_Char_Create` (`Character.bak`): checks slot and name with `IF EXISTS (SELECT … (NOLOCK))`, then inserts
  `tCharacter`, `tCharacterShape`, `tCharacterOptions` in one transaction. Result codes: char number, `0`, `-1`
  slot taken, `-2`, `-3`. The check-then-insert is a race; a later private-server fix
  (`Fixes/Duplicate Names/p_Char_Create.sql`) exists because of duplicate names.
- `usp_SafeTrade_setAll` (`w00_Character.bak`): reads the item owner outside the transaction, then
  `BEGIN TRAN`, `p_Char_MoneyMove`, `p_Item_SetStorageAndOwner`, commit or rollback. Codes `-2621` to `-2624`.
- `p_Char_MoneySub`: read money, subtract in the procedure, write back. Read-modify-write without a lock.

Portable replacements:

1. **Create with a unique name**: do not check first. Put unique indexes on the normalised name and on
   (user, slot) for live characters, insert inside `Repo.transact`, and map the unique-constraint error of each
   index to the original result code. The database decides the race. With soft delete (`bDeleted`) the slot
   index would have to be partial (not checked on SQLite, see "Not verified"); the portable alternative is to
   clear the slot value on delete.
2. **Guarded update instead of read-modify-write**: one statement,
   `update_all(where: id == ^id and money >= ^n, update: [inc: [money: ^-n]])`, then require an affected-row
   count of 1. PostgreSQL re-checks the `WHERE` after waiting for a concurrent writer (Read Committed, quoted
   above); SQLite has a single writer. No lock clause is needed on either.
3. **Trade**: one `Repo.transact` with guarded steps, each checked for count 1: move the item
   `where key == ^k and owner == ^seller and storage_type == ^shop`, subtract the buyer's money with the guard
   from 2, add the seller's money. Any count of 0 returns `{:error, code}`, which rolls back. The ownership check
   is inside the transaction, which also closes the original's check-outside race.
4. **Fixed order**: on PostgreSQL two trades touching the same two characters in opposite order can deadlock.
   Update rows in ascending key order. SQLite cannot deadlock this way with immediate transactions.
5. **No game logic inside a transaction that waits**: compute in Elixir first, then run a short transaction of
   writes. This keeps the SQLite writer lock in the millisecond range and avoids PostgreSQL lock waits.
6. **Result sets**: a procedure that returned rows becomes an ordinary query; `OUTPUT` parameters become the
   function's return value.

Since each zone process already owns its players' state, most saves are single-owner writes with no contention.
The guarded patterns matter for the cross-player operations (trade, shop, guild money, mail).

## SQLite write throughput in WAL mode

- SQLite gives no official WAL figure. It says a write lock lasts "milliseconds" and recommends client/server
  only for "many concurrent writers" (<https://sqlite.org/whentouse.html>). The FAQ figure of "a few dozen
  transactions per second" describes rotating disks with a full sync per commit, and carries a 2024 note that
  SQLite "will do far more than 50K inserts/second now" (<https://sqlite.org/faq.html>, item 19).
- With `synchronous = NORMAL`, the adapter default, commits do not sync the WAL; only checkpoints do. The price:
  transactions "might rollback following a power failure or hard reset", without corruption
  (<https://sqlite.org/wal.html>). For a game server that is the last second of saves after a power cut.
- **Local probe** (not a primary source; SQLite 3.54.1 through Python's `sqlite3`, Apple M1 Pro, internal SSD,
  one connection, `BEGIN IMMEDIATE`, three indexed `UPDATE`s per transaction, 100,000 items and 2,000 characters):
  about **17,000 transactions per second** at `synchronous = NORMAL` and about 11,700 at `FULL`. The `FULL`
  number is optimistic, since macOS `fsync` does not force the drive cache without `PRAGMA fullfsync`. Ecto and
  the NIF add per-statement overhead on top.
- Demand: the original server's own load is not measured here. As an order of magnitude, 2,000 players each
  causing one persisted change per second is 2,000 transactions per second, well under the probe. Batching each
  player's periodic save into one transaction lowers it further.
- Real risks are elsewhere: one slow transaction blocks every writer for its duration, and waiting writers fail
  after `busy_timeout` (2,000 ms by default). Options: raise the timeout, or send all writes through one
  connection (`pool_size: 1` for a write repo).

## Rule list for the persistence library

1. Types: `:integer`, `:bigint`, `:boolean`, `:string`, `:binary`, `:utc_datetime`, opaque `:map`. No arrays, no decimals.
2. Unique indexes keep Ecto's default names. Upserts always name `conflict_target` columns.
3. No `lock:`, no `mode:` per call, no `ilike`, no array operators, no SQL fragments outside one reviewed module.
4. SQLite repo config: `default_transaction_mode: :immediate`; keep the WAL and `foreign_keys` defaults.
5. Every multi-row operation is one `Repo.transact` of guarded statements with affected-row checks, rows in key order.
6. No `modify` in migrations. Before the first release, edit the initial migrations.
7. CI runs the persistence tests once per adapter. SQLite tests are not async.

## Not verified

- Nothing was executed against Ecto: no project exists under `server/` yet. The adapter claims are read from
  source, not observed. The guarded-update and trade patterns should get a test on both adapters as the first
  persistence task.
- The throughput figure comes from one machine through Python, not through exqlite. No measurement with
  several writer connections or with `fullfsync`.
- How many writes per second one busy world produces is an assumption. The reconstruction docs may allow a count
  of `{CALL}`s per player action; that was not done.
- Whether a partial unique index (`where:`) is emitted identically by both adapters was not checked in source.
- SQLite type affinity (a `TEXT` value accepted in an `INTEGER` column unless the table is `STRICT`) and whether
  ecto_sqlite3 can create `STRICT` tables were not checked.
- The behaviour of `mode: :immediate` on PostgreSQL was read as "no matching `case` clause" in postgrex; the exact
  error was not triggered.
- The procedure sources are from the private-server backups *(db-backup)*; the 2016 binary decides their real behaviour.
