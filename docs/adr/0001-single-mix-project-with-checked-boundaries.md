# Single Mix project with checked boundaries, not an umbrella

The server in `server/` is one Mix project. Its top-level namespaces `Protocol`, `Persistence`, `Cluster`, `Login`, `WorldManager` and `Zone` are declared as boundaries with the `boundary` library (a compile-time-only dependency), and the three parts may depend only on the three libraries, never on each other. One release is built; the `FIESTA_PARTS` setting chooses at start which parts run, defaulting to all.

An umbrella with one application per part would enforce the same rule with no dependency, but costs six `mix.exs` files and test suites, makes moving a module between applications expensive while the boundaries are still being found, and isolates less than it appears to (configuration and the dependency lock are shared anyway). `boundary` also checks boundaries inside a part, which an umbrella cannot.

## Consequences

- Every node carries the code of all parts; only the started supervisors differ.
- `boundary` 0.12.0 was checked on Elixir 1.20.5 / OTP 29: it compiles and reports a forbidden reference between two parts. If it stops working on a later Elixir, replace it with a `mix xref`-based test, not with an umbrella.
- `boundary` cannot see ETS access, so named ETS tables are banned (a test fails on `:named_table` under `server/`): an unnamed table is reachable only through the table id its owner holds.
