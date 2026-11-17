# Nil safety comes from code shape; specs are mandatory

The Elixir 1.20 compiler reports only what is certain to fail. A value that might be nil, and a `case` that misses a variant, both compile silently, and Dialyzer closes neither gap ([research](https://github.com/wbpascal/pinata/issues/2)). No tool gives us nil safety or exhaustiveness, so the code has to be shaped so that the mistakes cannot be written quietly:

- **Tagged results.** A public function never returns `value | nil`. A lookup returns `{:ok, v} | :error`; a failure returns `{:ok, v} | {:error, reason}` with an atom reason. A `!` variant exists only where a crash is the intended outcome.
- **Structs.** Required fields are listed in `@enforce_keys`. A field may be nil only when the data is truly optional, and its type says so. Function heads match on the struct wherever one crosses a module boundary.
- **Closed sets crash, client input does not.** No catch-all clause when matching a closed set of our own values, so a new variant fails loudly in tests. A catch-all is mandatory when matching anything decoded from the client.
- **Specs everywhere.** Every public function has a `@spec` and every struct a `@type t`, although the 1.20 compiler does not read them. Dialyzer does, and specs are the only way it finds a call that breaks a callee's contract or an ignored error return.

We chose this over relying on the compiler alone (misses everything that only might fail) and over specs on facades only (a flat rule can be checked by a tool, a selective one cannot).

One command, `mix check`, is the gate: format, compile and tests with warnings as errors, Credo, Dialyzer, and the built-in dependency checks. CI runs the same command. Every implementer and every reviewer, agent or human, runs it before finishing or approving.

## Consequences

- Credo is a dev dependency: its defaults plus `Specs`, `UnsafeToAtom`, `MapGetUnsafePass`, `LeakyEnvironment`, `ImplTrue` and `MixEnv`, and two custom checks of our own that reject `| nil` in a public return type and `:named_table` (the ETS ban of ADR 0001).
- The catch-all rule cannot be checked by a tool, because nothing knows whether a set is closed. It stays a review rule.
- When a later Elixir release reads user-written signatures, the specs are already there; the Dialyzer step can then be reconsidered.
