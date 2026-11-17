# What Elixir 1.20 typing and Dialyzer each catch

Research for issue #2, as of 2026-11-17. Versions examined: Elixir 1.20.5 (released 2026-10-29),
Erlang/OTP 29.1.2, Dialyxir 1.4.9 (2026-11-11).

Evidence levels used below:

- **[doc]**: stated in a primary source, linked in [Sources](#sources).
- **[probe]**: observed by compiling a 19-case probe module with exactly these versions
  ([Appendix](#appendix-probe-results)). The docs describe the type system in general terms; the probe
  is what settles the per-construct questions.

## Short answer

1. The 1.20 compiler infers types for every language construct and type checks the whole project,
   across modules and dependencies, with **no annotations** [doc S1, S2]. It reports only what is
   *certain* to fail: a value of type `dynamic(nil or binary())` passed to `String.upcase/1` is accepted,
   because one member of the union works [doc S2, probe].
2. So the compiler catches typos and definite mismatches very well, and catches **"might be nil"
   almost never**. Dialyzer does not catch it either: both tools are built to avoid false positives.
   Nil safety has to come from code shape (see [Nil](#nil-handling)), not from a tool.
3. The compiler **does not read `@spec` / `@type`** [doc S2, S4, probe]. User-written signatures and
   typed structs are future milestones [doc S2]. Dialyzer is the only tool that checks typespecs today.
4. Dialyzer added exactly two findings the compiler missed in the probe (a call that violates only the
   `@spec`, and a body that contradicts its own `@spec`), plus `unmatched_return` behind a flag. The
   compiler found two things Dialyzer missed (unknown struct field, unknown map key).
5. Fastest loop: compiler warnings in the editor through the language server, `--warnings-as-errors`
   in CI, Dialyzer as a separate CI job with the PLT cached. Warm Dialyzer run on the probe: 1.6 s;
   cold PLT build: 49 s.

## What the 1.20 compiler catches

"Elixir's type system now understands all language constructs and can infer types for your function
definitions, using typing information from Elixir's standard library and your dependencies, to find
verified bugs and dead code." [doc S1]

| Area | 1.20 behaviour | Evidence |
|---|---|---|
| Inference from patterns and guards | `is_list/1`, `is_map_key/2`, `tuple_size(x) < 3`, `or`/`and`/`not` in guards all refine the argument type | doc S1 |
| Whole-body inference | `data.foo + data.bar` infers a map with keys `foo`, `bar` holding numbers; argument types are narrowed by how the body uses them | doc S1 |
| Typing across clauses | A later clause knows what earlier clauses already matched; occurrence typing on `case`, `cond`, `with` | doc S1; probe D4 |
| Redundant clauses / dead code | "Detect and warn on redundant clauses" | doc S1; probe C07, C16 |
| Cross-module calls | Signatures are inferred per module, then "the whole project is type checked considering all modules and all types" | doc S2; probe C08 |
| Dependencies | "Perform type inference across applications" (new in 1.20) | doc S1 |
| Struct field access | Unknown field on a value known to be a struct warns | probe C01 |
| Struct literals | Field values written in a literal are tracked, including the `nil` default | probe C04, C12 |
| Maps | Atom keys and domain keys (`%{integer() => binary()}`); most of `Map` is typed; `Map.fetch!/2` on a key proven absent is an error | doc S1; probe C18 |
| Binaries | Segment types from binary patterns are tracked | probe C17 |
| Anonymous functions, captures | Inferred and checked since 1.19 | doc S3 |
| Protocol dispatch | Interpolating or enumerating a type without the implementation warns, since 1.19 | doc S3 |

All of these are **warnings**, not errors. `mix compile --warnings-as-errors` turns them into a failed
build [doc S5, probe].

## What it still misses

The rule behind every gap: inferred types of unannotated code are wrapped in `dynamic()`, and a
`dynamic()` union is only reported when **no** member can succeed. "Type inference in Elixir is
best-effort: it doesn't guarantee it will find all possible type incompatibilities, only that it may
find bugs where all combinations of a type *will* fail." [doc S2]

| Gap | Probe | Does Dialyzer close it? |
|---|---|---|
| "Might be nil" passed where nil is invalid (own function, stdlib `System.get_env/1`, local `if`) | C02, C03, D1 | No (C02, C03, C10) |
| `nil.field` when the value is a struct-or-nil union | C13, C14 | No |
| Struct field types: a matched `%User{name: n}` gives `n` the type `term()` | C05 | No |
| Non-exhaustive `case` (missing clause) | C06, D2 | No |
| `@spec` on the callee is ignored when checking a call | C09 | **Yes** (`call`) |
| A body that contradicts its own `@spec` | C11 | **Yes** (`invalid_contract`) |
| Ignored error return such as `File.write/2` | C19 | **Yes**, with the `unmatched_returns` flag |
| Message contents, `GenServer.call/2` replies, ETS / process dictionary reads | C15 (`v` is `dynamic()`) | No; a `@spec` on a wrapper function gives Dialyzer something to check callers against |

Not available in 1.20 at all [doc S2]:

- **User-written type signatures.** "User provided type signatures are planned for future releases."
  They are the third roadmap milestone.
- **Typed structs.** The second milestone: "it knows nothing about their respective types".
- **Exhaustiveness checking.** Neither the changelog nor the type-system page claims it; only
  *redundant* clauses are reported. The probe confirms a `case` that omits a union member is silent.

Two documented sources of false positives [doc S2]: `for` comprehensions are assumed to run at least
once, and `%User{user | ...}` requires `user` to be statically proven a `User` (fix: match
`%User{} = user` where it is bound).

### Nil handling

The compiler tracks `nil` precisely as an atom type and narrows it away across clauses
(`nil -> ...; value -> ...` gives `value` the type `binary()`) [doc S1]. It warns when a value is
*certainly* nil at a use site [probe C04, D4]. It is silent for a `nil or T` union [probe C02, C03,
C13, D1], and so is Dialyzer, including when the union comes from a `@spec` [probe C10].

What follows for the rebuild (design consequence, not a documented recommendation):

- Return `{:ok, value} | :error` (or raise in a `!` variant) rather than `value | nil` from lookups.
  A caller that uses the tuple as the value is then a *certain* failure, which both tools report.
- Bind structs with a pattern (`%Character{} = c`) at every boundary, so field typos are caught.
- Use `@enforce_keys` on structs so a `nil` default cannot silently stand in for a real value.
- Expect to revisit when typed structs land; this is the gap they are meant to close.

## What Dialyzer adds, and what it costs

Dialyzer analyses BEAM files with success typings and reads `@spec`/`@type`; its analysis "can be
improved by inclusion of type hints (called specs) but it can be useful even without those" [doc S6].
The Elixir docs warn that "Typespecs may be phased out as the set-theoretic type effort moves
forward" and that they "do not map one-to-one to the new types" [doc S4]. Specs written now are for
Dialyzer and documentation; the compiler will not use them.

Worth turning on (probe, Dialyxir `flags:`):

- default flags: `call`, `invalid_contract`, `pattern_match`, `no_return`;
- `:unmatched_returns`: the only finding class with no compiler equivalent besides spec checks;
- `:underspecs` / `:overspecs` are noisy: they flagged both hand-written specs in the probe as
  "subtype of the success typing" although the specs were the intended contract.

Overlap is large: of 14 default Dialyzer warnings on the probe, 11 pointed at lines the compiler had
already reported, with a less precise message.

Cost on the probe (10-core Apple Silicon, no dependencies besides Dialyxir): cold run including all
three PLTs 49 s; warm run 1.6 s. PLT time grows with the dependency count [doc S6].

## Fastest feedback setup

**Editor.** Type warnings are ordinary compiler diagnostics, so any language server that compiles the
project shows them.

- ElixirLS (v0.31.1): lists Elixir 1.20 on OTP 27, 28 and 29 in its support matrix, returns
  `mix compile` warnings as LSP diagnostics, and runs incremental Dialyzer after each build
  (`elixirLS.dialyzerEnabled`, `elixirLS.dialyzerWarnOpts`) [doc S8].
- Expert (v0.2.3, the official language server): its README says it "is currently in alpha" and its
  version table stops at Elixir 1.19 / Erlang 27 [doc S9]. Not confirmed for 1.20 on OTP 29.

**Compiler flags.**

- `mix compile --warnings-as-errors` in CI; `mix test --warnings-as-errors` also exists [doc S1, S5].
  Keep it off in `mix.exs` for dev so a warning does not block the edit-run loop.
- Leave `infer_signatures` at its default. Mix sets it to the dependency list, which is what enables
  inference across applications; `false` disables the signatures used for remote calls [doc S5].
  The docs say Mix disables it under `MIX_ENV=test`; in the probe, `MIX_ENV=test mix compile` still
  printed the same 9 type warnings including the cross-module one.
- `mix compile --profile time` prints per-module type-checking times since 1.20.2 [doc S1].

**Dialyzer in CI** [doc S6, S7].

```elixir
# mix.exs
{:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}

dialyzer: [
  plt_local_path: "priv/plts/project.plt",
  plt_core_path: "priv/plts/core.plt",
  flags: [:unmatched_returns]
]
```

- Git-ignore `/priv/plts/*.plt` and `/priv/plts/*.plt.hash`.
- Cache `priv/plts` keyed on OS, OTP version, Elixir version and the hash of `mix.lock`, with a
  restore key that drops the lock hash.
- `mix dialyzer --plt` builds only the PLT (run on cache miss, then save the cache before the analysis
  step so a failing analysis still saves it).
- `mix dialyzer --format github --format dialyxir` annotates the PR and keeps readable logs.
- "The PLT will need to be rebuilt whenever adding a new Erlang or Elixir version."

**Order of feedback, fastest first:** editor diagnostics from the compiler (seconds, on save) →
`mix compile --warnings-as-errors` (CI gate, incremental locally) → `mix dialyzer` (CI job, about a
second per run once the PLT is cached, on a project the size of the probe).

## `mise.toml`

```toml
[tools]
erlang = "29.1.2"
elixir = "1.20.5-otp-29"
```

- Elixir 1.20 "requires Erlang/OTP 27+ and is compatible with Erlang/OTP 29"; supported range 27-29
  [doc S1, S10].
- mise installs Hex's precompiled Elixir builds named `X.Y.Z-otp-NN`; the suffix must match the Erlang
  major, and a bare `1.20.5` is "the build without an OTP suffix" [doc S11]. `mise ls-remote` lists
  `1.20.5-otp-29` and Erlang `29.1.2`.
- Erlang comes precompiled on macOS, Windows and Ubuntu 20.04-24.04 (including GitHub Actions) and is
  compiled with kerl elsewhere [doc S11].
- Verified locally: this pair reports `Elixir 1.20.5 (compiled with Erlang/OTP 29)`, and Dialyxir
  1.4.9 builds its PLTs and runs on it.

## Not verified

- Expert on Elixir 1.20 / OTP 29, and how either language server renders the multi-line type warnings.
  Neither server was run.
- Compile-time and Dialyzer cost on a real project with dependencies (Ecto, etc.); the timings are
  from a two-module project.
- Whether Dialyxir can use Dialyzer's `--incremental` mode (which OTP 29 ships [doc S12]); its README
  does not mention it.
- The release schedule of typed structs and type signatures; the docs give an order, not dates.
- The `infer_signatures` test-environment behaviour: docs and probe disagree as noted above.
- Credo and other linters were not examined.

## Appendix: probe results

Compiled with `mix compile --force`, then `mix dialyzer` (default flags unless noted). `User` is a
struct `defstruct [:name, age: 0]`; `User.find_name/1` returns `"bob"` or `nil` (no spec);
`User.lookup_name/1` has `@spec ... :: String.t() | nil` over `Process.get/1`; `User.only_int/1` has
`@spec only_int(integer()) :: integer()` over `Process.get/1`; `User.strict/1` has an `is_integer`
guard.

| # | Code | Compiler | Dialyzer |
|---|---|---|---|
| C01 | `def c01(%User{} = u), do: u.nme` | unknown key `.nme` | silent |
| C02 | `String.upcase(User.find_name(id))` | silent | silent |
| C03 | `String.upcase(System.get_env("X"))` | silent | silent |
| C04 | `String.upcase(%User{}.name)` | incompatible types (`nil`) | `no_return` |
| C05 | `def c05(%User{name: name}), do: name + 1` | silent | silent |
| C06 | `case User.find_name(id) do nil -> :none end` | silent | silent |
| C07 | same `case` with an extra `:error ->` clause | clause will never match | `pattern_match` |
| C08 | `User.strict("one")` | incompatible types | `call` |
| C09 | `User.only_int("one")` (violates only the spec) | silent | `call` |
| C10 | `String.upcase(User.lookup_name(1))` | silent | silent |
| C11 | `@spec c11(integer()) :: binary()` / `def c11(x), do: x + 1` | silent | `invalid_contract` |
| C12 | `%User{age: "x"}.age + 1` | incompatible types | `no_return` |
| C13 | `u = if id > 0, do: %User{}, else: nil; u.name` | silent | silent |
| C14 | `maybe(id).name`, private `maybe/1` returns `%User{}` or `nil` | silent | silent |
| C15 | `{:ok, v} = GenServer.call(pid, :get); v + "a"` | incompatible types (the `"a"`; `v` is `dynamic()`) | `call` |
| C16 | `case pair() do {:ok, a, b} -> ... end`, `pair/0` returns `{:ok, 1}` | clause will never match | `pattern_match` |
| C17 | `def c17(<<len::16, rest::binary>>), do: len <> rest` | incompatible types in binary construction | `bin_construction` |
| C18 | `m = %{hp: 1}; m.mp` | unknown key `.mp` | silent |
| C19 | `File.write(path, "x"); :done` | silent | `unmatched_return` (flag `--unmatched_returns` only) |
| D1 | `x = if c, do: "a", else: nil; String.upcase(x)` | silent | silent |
| D2 | `case Map.fetch(m, :k) do {:ok, v} -> v end` | silent | silent |
| D4 | `if is_nil(name), do: String.upcase(name), else: name` | incompatible types (`dynamic(nil)`) | silent |

## Sources

- S1: Elixir v1.20 changelog, tag `v1.20.5`:
  <https://github.com/elixir-lang/elixir/blob/v1.20.5/CHANGELOG.md>
  (rendered: <https://hexdocs.pm/elixir/1.20.5/changelog.html>)
- S2: "Gradual set-theoretic types", Elixir 1.20.5:
  <https://hexdocs.pm/elixir/1.20.5/gradual-set-theoretic-types.html>
  (source: `lib/elixir/pages/references/gradual-set-theoretic-types.md` at tag `v1.20.5`)
- S3: Elixir v1.19 changelog: <https://github.com/elixir-lang/elixir/blob/v1.19/CHANGELOG.md>;
  v1.18 changelog: <https://github.com/elixir-lang/elixir/blob/v1.18/CHANGELOG.md>
- S4: "Typespecs reference", Elixir 1.20.5: <https://hexdocs.pm/elixir/1.20.5/typespecs.html>
- S5: `mix compile.elixir` options and `Code.put_compiler_option/2` (`:infer_signatures`):
  <https://hexdocs.pm/mix/1.20.5/Mix.Tasks.Compile.Elixir.html>,
  <https://hexdocs.pm/elixir/1.20.5/Code.html#put_compiler_option/2>
- S6: Dialyxir README and changelog (1.4.9): <https://github.com/jeremyjh/dialyxir/blob/master/README.md>,
  <https://github.com/jeremyjh/dialyxir/blob/master/CHANGELOG.md>
- S7: Dialyxir GitHub Actions example:
  <https://github.com/jeremyjh/dialyxir/blob/master/docs/github_actions.md>
- S8: ElixirLS README (support matrix, Dialyzer integration):
  <https://github.com/elixir-lsp/elixir-ls/blob/master/README.md>
- S9: Expert README and installation page: <https://github.com/expert-lsp/expert/blob/main/README.md>,
  <https://github.com/expert-lsp/expert/blob/main/pages/installation.md>
- S10: "Compatibility and deprecations", Elixir 1.20.5:
  <https://hexdocs.pm/elixir/1.20.5/compatibility-and-deprecations.html>
- S11: mise docs for Elixir and Erlang: <https://mise.jdx.dev/lang/elixir.html>,
  <https://mise.jdx.dev/lang/erlang.html>
- S12: Dialyzer command-line reference, OTP 29.1.2 (`lib/dialyzer/src/dialyzer.erl` at tag
  `OTP-29.1.2`): <https://www.erlang.org/doc/apps/dialyzer/dialyzer.html>
