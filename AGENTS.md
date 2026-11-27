# Pinata: rules for every session

Pinata is an Elixir server for the 2016 Fiesta client. Start sessions at the repository root; every command here runs there.

## Repository map

| Path | What |
|---|---|
| `lib/`, `test/`, `config/`, `priv/`, `credo/`, `mix.exs` | the server, one Mix project (ADR 0001) |
| `test/replay/transcripts/` | Transcripts of the captures, written by `pcap_decode.py --transcript` of the reconstruction |
| `test/fixtures/opcodes.json` | copy of the reconstruction's `docs/protocol/opcodes.json` |
| `original-data/9Data/` | copy of the original server's `Shine` and `ServerInfo` tables (Git LFS); the tests import it |
| `docs/user/`, `docs/technical/` | the documentation of this server |
| `docs/adr/`, `docs/roadmap.md`, `docs/agents/`, `GLOSSARY.md`, `CHANGELOG.md` | decisions, milestones, agent setup, vocabulary, changes per version |
| `Dockerfile`, `compose.yaml`, `compose.toml` | the image and the Docker Compose example |
| `.github/` | CI (`server.yml`), release (`release.yml`) and the changelog check |

## The reconstruction

The Reconstruction of the original server (protocol, pseudocode, knowledge, captures, the binaries and the tools that read them) lives in [`wbpascal/pinata-re`](https://github.com/wbpascal/pinata-re), cloned next to this repository as `../pinata-re`. Its `AGENTS.md` describes its layout and tools. Citations in code and docs (`docs/pseudocode/…`, `docs/protocol/…`, `docs/knowledge/…`, `re-data/captures/…`, `tools/protocol-re/…`, item IDs like `Z02`) are paths in that repository. The tests never need it.

`original-data/9Data/` and `test/fixtures/opcodes.json` are copies: refresh them with `../pinata-re/tools/sync-server.sh "$PWD"` and name the `pinata-re` commit it prints in the commit message.

## The gate

Run `mix check` before you finish or approve anything, and paste its output into the PR. CI runs the same command. It runs, in this order:

- `mix format --check-formatted`
- `mix deps.unlock --check-unused` and `mix hex.audit`
- `mix compile --warnings-as-errors` (this includes the `boundary` compiler)
- `mix xref graph --label compile-connected --fail-above 0`
- `mix credo`: the defaults plus `Readability.Specs`, `Readability.ImplTrue`, `Warning.UnsafeToAtom`, `Warning.MapGetUnsafePass`, `Warning.LeakyEnvironment`, `Warning.MixEnv` and the three checks in `credo/checks/` (no `| nil` in the return type of a public `@spec`; no `:named_table`; system time and `:rand` only inside `Clock` and `Random`)
- `mix dialyzer` with `:unmatched_returns`, `:extra_return`, `:missing_return`; there is no ignore file
- `mix test --warnings-as-errors`

CI also runs `mix deps.audit`. `mix check` covers only the job `check`; a test plan names every job of the table "CI jobs" that the change affects. A noisy Credo check is switched off on its own in `.credo.exs`, never a whole category.

## CI jobs

`.github/workflows/server.yml` runs these jobs. A test plan names each job the change affects, with its local
command. `test/workflow_test.exs` fails when a job has no row here or a row names no job.

| Job | Checks | Affected by | Locally (macOS) |
|---|---|---|---|
| `changelog` | a `CHANGELOG.md` line or `Changelog: none` in the PR description | every PR | at the repo root: `bash .github/scripts/changelog-check-test.sh`; `PR_BODY="…" bash .github/scripts/changelog-check.sh origin/master HEAD` |
| `check` | the gate, single-node on SQLite, and `mix deps.audit` | every change | `mix check && mix deps.audit` |
| `check-windows` | the gate on Windows | paths, line ends, file modes, symlinks, SQLite | CI only |
| `windows-smoke` | release on Windows: import, start, account, login to the character list | release, config, start-up, import code | CI only |
| `test-postgres` | the tests on PostgreSQL with three peer nodes | database code, migrations, cluster code, anything a peer node runs | `docker run -d --name pinata-pg -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=pinata_test -p 5432:5432 postgres:18`, then with `MIX_ENV=test DATABASE_URL=postgres://postgres:postgres@localhost:5432/pinata_test PINATA_TEST_TOPOLOGY=multi`: `mix pinata.migrate`, `mix test --warnings-as-errors` |
| `compose-smoke` | the Docker image and the Compose example: login to the character list | `Dockerfile`, `compose.yaml`, `compose.toml`, release, config, start-up code | `docs/technical/testing.md`, "Smoke test" |
| `otel-smoke` | the release with OpenTelemetry export off and on, against a real Collector | telemetry, `Pinata.Otel`, release, config, start-up code, `Zone.Player`, `Zone.MapInstance.enter/2` | `MIX_ENV=prod mix release`, then the job's steps (`docs/technical/testing.md`, "Smoke test") |
| `load-smoke` | the load run task against the release in single-node mode: 50 players for 10 s, every player in the world, no `error` line of the node | `test/support/load*`, `TestClient`, login, character list and create, map entry, movement and chat code, release, start-up code | `MIX_ENV=prod mix release`, then the job's steps (`docs/technical/load-run.md`, "CI smoke run") |

**No inline code in workflows.** An `eval` or `rpc` string in a workflow is one call with literal arguments.
Anything longer is a script in `test/support/` that the workflow runs (`mix run`, or
`bin/pinata rpc "Code.eval_file(…)"`), and a test of the suite loads the script or runs the same code
(`test/workflow_test.exs`), so that `mix check` fails when the script breaks.

## Conventions

- **Typespecs:** every public function has a `@spec`, every struct a `@type t`. Private functions are exempt.
- **Tagged results:** a public function never returns `value | nil`. A lookup returns `{:ok, v} | :error`, a failure `{:ok, v} | {:error, atom}`. A `!` variant exists only where a crash is intended.
- **Structs:** `@enforce_keys` for required fields. A field is nil only when the data is truly optional, and its type says so. Function heads match on the struct at module boundaries.
- **Exhaustiveness:** no catch-all clause on a closed set of our own values; a catch-all is mandatory on anything decoded from the client. This is a review rule; no tool checks it.
- **Time and randomness:** only through `Clock` and `Random`.
- **ETS:** no named tables.
- **Telemetry:** server code emits only `:telemetry` events and `Logger` calls and never calls the OpenTelemetry API (ADR 0011). A duration is a `:telemetry` span (`:telemetry.span/3`, `start` / `stop`), never a single event with a time measured by hand. `Pinata.Otel` is the only module that names the OpenTelemetry API.
- **Packet docs:** after a change to a packet definition run `mix pinata.packets_doc`; `mix check` fails on a stale `docs/technical/packets.md`.

## Untrusted input

Every byte from a client connection is untrusted input (ADR 0012; terms in `GLOSSARY.md`, "Security"). These rules apply to every handler:

- **Check at the trust boundary.** The packet handler turns each client value into a checked value (a table row, an owned object, a number in range) before it calls anything else. Code behind the handler never receives a text or a number a client wrote. A name is looked up in its table, never joined into a path or a statement.
- **Intent, not outcome.** Check that the packet is valid in the current step of the connection, that the objects it names belong to the sender or are reachable by them, and that claimed values (position, distance, count) are possible.
- **Two answers.** Impossible input closes the connection with a server log line and a telemetry event. A refused request gets the error code of the original server and the connection stays open.
- **Compatibility covers only input the unmodified client can produce.** Do not copy an exploitable original-server bug; fix it and cite its bug id.
- **Issued values** (tokens, keys) come from the cryptographic random source, work once and expire.
- **Isolation.** Untrusted input may crash only its own connection process, never a shared one.
- **Judging a finding.** Ask first: can a client reach this code today? If yes, fix it before merge. If no, it is ordinary work.

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
- `docs/user/` and `docs/technical/`: the documentation of this server. The technical index lists the boundaries as built.
- In `../pinata-re`:
  - `docs/protocol/`: packet layouts, opcodes and client error codes of the original server. Consult it for every client-facing packet.
  - `docs/pseudocode/`: reconstructed behaviour of the original handlers. Consult it before you implement a handler.
  - `docs/pseudocode/README.md`, section "Original-server bugs": the bug register. Check it before you copy a behaviour that looks unintended.
  - `re-data/captures/`: captures of real traffic with scenario notes. A capture wins over the reconstruction.

## Context budget

Every tool output stays in the session, and the reconstruction files are big (`decomp.c` 15 MB with lines up to 6,700 characters, `strings.tsv` lines up to 2,000, pseudocode docs up to 110 KB). Print only what you need, in few calls:

- **Fewer, larger calls.** Every turn re-reads the whole context. Read related functions in one call, search several patterns in one `rg -e A -e B`, and send independent calls in parallel.
- **Code of the original:** read functions only with `../pinata-re/tools/protocol-re/clean.py`, never `cat`, `sed -n` or `head` on `decomp.c`.
- **Search:** `rg -M 200` on the exports; `-c` or `-l` first when the hit count is unknown.
- **Docs over about 15 KB** (pseudocode, knowledge, protocol, `docs/technical/packets.md`): `python3 -I ../pinata-re/tools/protocol-re/sect.py <file>` for the outline, then `sect.py <file> <§|regex>`, or `Read` with `offset` and `limit`. `packets-*.md` and `opcodes-*.md`: `rg` the opcode.
- **JSON** (`opcodes.json`, `layouts.json`, annotations, client error codes): query with `jq`, selecting only the fields you need.
- **Tools with unknown output size** (`shn.py`, `pdb.py`, `bak.py`, scripts): pipe through `| head -c 4000` or print counts.
- Transcripts in `test/replay/transcripts/` are long: `rg` the opcode or the time instead of reading them whole.

## Documentation checklist

A reviewer passes or fails a PR on these seven points:

1. Every setting, `mix` task, command, GM command or start-up error added or changed in the diff appears in the user documentation.
2. Every new part, boundary or process type appears in the technical documentation.
3. Every new flow where a client action crosses a part or process boundary has a sequence diagram in `docs/technical/flows/`.
4. For everything the diff renames or removes, the reviewer greps `docs/` for the old name and finds no hits.
5. A PR that changes no documentation says why in its description.
6. Every new failure branch, server-initiated close and start-up step in the diff writes a server log line, or the PR says why not.
7. Every change to what an administrator must do to keep the server secure (a new port, a secret, a setting that opens or limits access, a new accepted limit) appears in `docs/user/security.md`.

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
