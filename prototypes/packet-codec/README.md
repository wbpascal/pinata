THROWAWAY PROTOTYPE for issue 14 (packet codec). Lives on branch `agent/issue-14`, not meant for `master`.

# What should a packet definition look like in Elixir?

**Question (issue 14):** prototype two or three shapes for a handful of real login and character
packets: generated from the `docs/protocol` JSON, hand-written structs with binary pattern matching, or a
small declarative macro. Judge by byte-exactness, what the Elixir 1.20 type checker and Dialyzer see, readability
next to the pseudocode, and how a corrected layout from a new capture flows in.

**Assumption:** the prototype skill's "single HTML file" form does not fit (the audience is developers judging
code shape), so the artifact is runnable Elixir plus [FINDINGS.md](FINDINGS.md). There is no `server/` yet, hence
this top-level `prototypes/` directory. Scope is the payload codec only (bytes after the 2-byte opcode).

The answer material is in [FINDINGS.md](FINDINGS.md); raw tool output is in `results/`.

## Layout

| Path | What |
|---|---|
| `lib/hand/` | Shape B: structs + binary pattern matching, written by hand (`Proto.Hand.*`) |
| `lib/macro/` | Shape C: `use Proto.Macro.Packet` DSL (`packet.ex`) and the 8 packets + 2 structs (`packets.ex`) |
| `gen.exs`, `lib/gen/generated.ex` | Shape A: generator and its checked-in output (`Proto.Gen.*`) |
| `lib/wire.ex` | The two shared helpers, `cstr/1` and `pad/2` |
| `test/` | `roundtrip_test.exs` (3 shapes x 9 captured payloads), `fixtures.json` (from `re-data/captures/26_11_15_create-char.pcapng`) |
| `probes/` | Deliberately wrong callers, compiled only with `PROBES=1` |
| `results/` | `compiler.txt`, `dialyzer.txt`, `correction.txt`, `coverage.txt` |

## Commands (from the repo root, then `cd prototypes/packet-codec`)

```bash
cd prototypes/packet-codec
mix deps.get
mix format --check-formatted
mix compile --force --warnings-as-errors
mix test                                   # 27 tests: 3 shapes x 9 fixtures
elixir gen.exs && git status --short .     # regenerates lib/gen/generated.ex, expect no change

# evidence files (warnings expected, mix dialyzer exits non-zero)
PROBES=1 mix compile --force 2>&1 | tee results/compiler.txt
PROBES=1 mix dialyzer 2>&1 | tee results/dialyzer.txt
elixir gen.exs --coverage | tee results/coverage.txt

# the corrected-layout experiment of FINDINGS.md section 6, shape A
mkdir -p /tmp/issue14-docs && cp -r ../../docs/protocol/annotations.json ../../docs/protocol/annotations ../../docs/protocol/pdb2016-layouts.json /tmp/issue14-docs/
# edit AVATAR in /tmp/issue14-docs/annotations/W01.json, then
PROTO_DOCS=/tmp/issue14-docs elixir gen.exs
```

Toolchain: Elixir 1.20.x on OTP 29, Hex reachable (`dialyxir`). JSON is read with the built-in `JSON` module.
The password packet `0x0C5A` is deliberately not in the fixtures (captures are sensitive).
