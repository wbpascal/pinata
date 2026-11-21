# Elixir server: rules for every session

Start sessions at the repo root. The repository map, the tools and the context budget of the root `CLAUDE.md` apply here too; its work-item conventions do not.

## The gate

Run `mix check` in `server/` before you finish or approve anything, and paste its output into the PR. CI runs the same command. It runs, in this order:

- `mix format --check-formatted`
- `mix deps.unlock --check-unused` and `mix hex.audit`
- `mix compile --warnings-as-errors` (this includes the `boundary` compiler)
- `mix xref graph --label compile-connected --fail-above 0`
- `mix credo`: the defaults plus `Readability.Specs`, `Readability.ImplTrue`, `Warning.UnsafeToAtom`, `Warning.MapGetUnsafePass`, `Warning.LeakyEnvironment`, `Warning.MixEnv` and the three checks in `credo/checks/` (no `| nil` in the return type of a public `@spec`; no `:named_table`; system time and `:rand` only inside `Clock` and `Random`)
- `mix dialyzer` with `:unmatched_returns`, `:extra_return`, `:missing_return`; there is no ignore file
- `mix test --warnings-as-errors`

CI also runs `mix deps.audit`. A noisy Credo check is switched off on its own in `.credo.exs`, never a whole category.

## Conventions

- **Typespecs:** every public function has a `@spec`, every struct a `@type t`. Private functions are exempt.
- **Tagged results:** a public function never returns `value | nil`. A lookup returns `{:ok, v} | :error`, a failure `{:ok, v} | {:error, atom}`. A `!` variant exists only where a crash is intended.
- **Structs:** `@enforce_keys` for required fields. A field is nil only when the data is truly optional, and its type says so. Function heads match on the struct at module boundaries.
- **Exhaustiveness:** no catch-all clause on a closed set of our own values; a catch-all is mandatory on anything decoded from the client. This is a review rule; no tool checks it.
- **Time and randomness:** only through `Clock` and `Random`.
- **ETS:** no named tables.
- **Packet docs:** after a change to a packet definition run `mix pinata.packets_doc`; `mix check` fails on a stale `docs/technical/packets.md`.

## Persistence: the portable subset

Schema and queries must run on PostgreSQL and SQLite (ADR 0004). No tool checks these rules; CI runs the tests on both.

1. Column types: `:integer`, `:bigint`, `:boolean`, `:string`, `:binary`, `:utc_datetime`, opaque `:map`. No arrays, no decimals.
2. Unique indexes keep Ecto's default names. Upserts always name the `conflict_target` columns.
3. No `lock:`, no `mode:` per call, no `ilike`, no array operators, no SQL fragments outside one reviewed module.
4. The SQLite repo runs with `default_transaction_mode: :immediate` and keeps the WAL and `foreign_keys` defaults.
5. Every operation is one `Repo.transact` of guarded statements, each checked for its affected-row count, rows touched in key order. Leave the transaction after a failed statement. Slow work such as password hashing stays outside the transaction.
6. No `modify` in migrations. Migrations are append-only: a migration that a published version contains is never edited (ADR 0010).
7. Tests that touch the database are not async and must pass on both adapters; CI runs them once per adapter.

Nothing outside `Persistence` names a Repo, a schema or a query. A text compared without case gets a second, normalised column with a plain unique index (`accounts.name_key`).

## Server log

- Every line is `Part: message`, where the part is the part or boundary that writes it (`Login`, `WorldManager`, `Zone`, `Pinata`, `Cluster`, `Persistence`, `GameData`). The format and the timestamps (UTC) come from `config/config.exs`; the level from the setting `log.level`.
- Levels:

  | Level | Meaning |
  |---|---|
  | `error` | the server failed, an administrator must act (database failure, digest mismatch) |
  | `warning` | the server is degraded or defended itself (limit exceeded, send failed, node lost, world unavailable) |
  | `info` | normal events worth a line (node started, listening, login accepted or refused, client protocol violations) |
  | `debug` | per-packet and per-connection detail |

  Client misbehaviour is never `error`.
- Every server-initiated close and every failure branch writes exactly one line with its reason.
- Never log passwords, tokens or the database URL.
- A handler does not call `Logger`: it returns `{:log, level, message}` or `{:close, level, reason}` and `Net.Connection` adds the part and the peer address.
- Tests assert on the captured line (level, part, reason) with `TestLog.capture/1`. No tool checks the convention; the reviewer does (checklist point 6).

## Where the documentation is

- `GLOSSARY.md`: the project's vocabulary. Use its terms in code, documentation and issues.
- `docs/adr/`: why the architecture is as it is. Read the ADRs of the area before you change it.
- `docs/protocol/`: packet layouts, opcodes and client error codes of the original server. Consult it for every client-facing packet.
- `docs/pseudocode/`: reconstructed behaviour of the original handlers. Consult it before you implement a handler.
- `docs/pseudocode/README.md`, section "Original-server bugs": the bug register. Check it before you copy a behaviour that looks unintended.
- `re-data/captures/`: captures of real traffic with scenario notes. A capture wins over the reconstruction.
- `server/docs/user/` and `server/docs/technical/`: the documentation of this server. The technical index lists the boundaries as built.
- Root `CLAUDE.md`, section "Context budget": how to read the big reconstruction files.

## Documentation checklist

A reviewer passes or fails a PR on these six points:

1. Every setting, `mix` task, command, GM command or start-up error added or changed in the diff appears in the user documentation.
2. Every new part, boundary or process type appears in the technical documentation.
3. Every new flow where a client action crosses a part or process boundary has a sequence diagram in `server/docs/technical/flows/`.
4. For everything the diff renames or removes, the reviewer greps `server/docs/` for the old name and finds no hits.
5. A PR that changes no documentation says why in its description.
6. Every new failure branch, server-initiated close and start-up step in the diff writes a server log line, or the PR says why not.

## Changelog checklist

`CHANGELOG.md` at the repository root records, per version, what an administrator or a player can observe: a client action that now works, a setting, a command, a start-up error, a changed default. Internal work (test harness, CI, refactoring) is not in it. The top section is always the next version, marked `(unreleased)`, and every PR adds its own lines to it. The form of a section:

```
## 0.1.0 – Login to character select (unreleased)

<two to four sentences: the most important changes of this version>

### New
- one line per observable change, with its issue number (#45)

### Fixed
- one line per defect of an earlier version (#61)

### Differences from the original server
- only fixes of original-server bugs that change packets or gameplay

### Moving from the previous version
- migrations, changed settings, whether the data directory must be imported again
```

The title is the milestone's name unless a sharper one fits. A heading with nothing under it is left out. "Fixed" is for defects of an earlier Pinata version; a fix of an original-server bug goes under "Differences from the original server", and only when it changes packets or gameplay. Lines stay in issue-number order until the version is published.

The charting session of a milestone opens its section (`docs/roadmap.md`, "Rules"). The issue "Publish version 0.N.0" sets the date in place of `(unreleased)`, checks that every observable change has its line and orders the lines. A fix version `0.N.P` is tagged on master: at that point the lines of the top section so far become the section of the fix version, with a title written for it, and a new unreleased section opens above it.

A reviewer passes or fails a PR on these four points:

1. A change an administrator or player can observe has a line in the top section, under the right heading, with its issue number.
2. A PR that leaves `CHANGELOG.md` untouched has a line starting with `Changelog: none` in its description, followed by the reason. CI checks only that one of the two is there.
3. The overview is unchanged unless the PR does one of three things, and the description names which: it delivers a capability named in the milestone's row of `docs/roadmap.md` that the overview lacks; it adds a step every administrator must take when moving to the version; it removes or breaks something an earlier version had. The overview stays at two to four sentences, so a change rewrites it and does not append.
4. Sections of published versions are not changed.
