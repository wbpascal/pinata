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

## Where the documentation is

- `GLOSSARY.md`: the project's vocabulary. Use its terms in code, documentation and issues.
- `docs/adr/`: why the architecture is as it is. Read the ADRs of the area before you change it.
- `docs/protocol/`: packet layouts, opcodes and client error codes of the original server. Consult it for every client-facing packet.
- `docs/pseudocode/`: reconstructed behaviour of the original handlers. Consult it before you implement a handler.
- `docs/pseudocode/README.md`, section "Original-server bugs": the bug register. Check it before you copy a behaviour that looks unintended.
- `re-data/captures/`: captures of real traffic with scenario notes. A capture wins over the reconstruction.
- `server/docs/user/` and `server/docs/technical/`: the documentation of this server. The technical index lists the boundaries as built; the `Protocol` boundary of ADR 0001 is the module `Proto` there.
- Root `CLAUDE.md`, section "Context budget": how to read the big reconstruction files.

## Documentation checklist

A reviewer passes or fails a PR on these five points:

1. Every setting, `mix` task, command, GM command or start-up error added or changed in the diff appears in the user documentation.
2. Every new part, boundary or process type appears in the technical documentation.
3. Every new flow where a client action crosses a part or process boundary has a sequence diagram in `server/docs/technical/flows/`.
4. For everything the diff renames or removes, the reviewer greps `server/docs/` for the old name and finds no hits.
5. A PR that changes no documentation says why in its description.
