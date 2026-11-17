THROWAWAY PROTOTYPE for issue 14 (packet codec). Lives on branch `agent/issue-14`, not meant for `master`.

# What should a packet definition look like in Elixir?

**Question (issue 14):** prototype two or three shapes for a handful of real login and character
packets: generated from the `docs/protocol` JSON, hand-written structs with binary pattern matching, or a
small declarative macro. Judge by byte-exactness, what the Elixir 1.20 type checker and Dialyzer see, readability
next to the pseudocode, and how a corrected layout from a new capture flows in.

**Assumption:** the prototype skill's "single HTML file" form does not fit (the audience is developers judging
code shape), so the artifact is runnable Elixir plus the [Findings](#findings) below. There is no `server/` yet, hence
this top-level `prototypes/` directory. Scope is the payload codec only (bytes after the 2-byte opcode).

The answer material is in [Findings](#findings) below; raw tool output is in `results/`.

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

# the corrected-layout experiment of Findings section 6, shape A
mkdir -p /tmp/issue14-docs && cp -r ../../docs/protocol/annotations.json ../../docs/protocol/annotations ../../docs/protocol/pdb2016-layouts.json /tmp/issue14-docs/
# edit AVATAR in /tmp/issue14-docs/annotations/W01.json, then
PROTO_DOCS=/tmp/issue14-docs elixir gen.exs
```

Toolchain: Elixir 1.20.x on OTP 29, Hex reachable (`dialyxir`). JSON is read with the built-in `JSON` module.
The password packet `0x0C5A` is deliberately not in the fixtures (captures are sensitive).

## Findings

Everything below was observed by running the code in this directory; line references point into `results/`.

### 1. Question and what was built

Question: what should a packet definition look like in Elixir? Judged by byte-exactness, what the 1.20 type checker and Dialyzer see of the fields, readability next to the pseudocode, and how a corrected layout from a new capture flows in.

Built: the same 8 real login and character packets (`0x0807`, `0x0C65`, `0x0C0A`, `0x0C0C`, `0x0C14`, `0x1401`, `0x1406`, `0x1407`) plus `WORLD` and `AVATAR`, from `26_11_15_create-char.pcapng`, in three shapes: A generated (`gen.exs` -> `lib/gen/generated.ex`), B hand-written (`lib/hand/`), C macro (`lib/macro/`, `use Proto.Macro.Packet`). All satisfy the ADR 0003 contract: `@enforce_keys`, `@type t`, `opcode/0` (packets only), `decode/1 :: {:ok, t} | {:error, :bad_size}` (never a crash), `encode/1`, with `@spec`. Scope: payload only.

### 2. The same packet in three shapes

Docs row (`docs/protocol/README.md` §3.1): `0x0C0A | S->C | u8 count; WORLD[count] | WORLD (18 bytes) = u8 world_no; char name[16]; u8 status ...`.

Shape C, complete definitions of `World` and `NC_USER_LOGIN_ACK`:

```elixir
defmodule Proto.Macro.World do
  use Proto.Macro.Packet
  field :world_no, :u8
  field :world_name, {:char, 16}
  field :status, :u8
end

defmodule Proto.Macro.UserLoginAck do
  use Proto.Macro.Packet, opcode: 0x0C0A
  array :worlds, Proto.Macro.World, count: :u8
end
```

Shape B (`lib/hand/world.ex`, `packets.ex`): the same, spelled out. `decode` is a function head with a literal pattern, `<<count::8, rest::binary-size(count * 18)>>`, then `for(<<w::binary-size(18) <- rest>>, do: elem(World.decode(w), 1))`; `encode` is `<<length(worlds)::8, for(w <- worlds, into: <<>>, do: World.encode(w))::binary>>`; each struct has `@enforce_keys`, `@type t`, `@spec`s and a catch-all `decode(_) -> {:error, :bad_size}`.

Shape A (`lib/gen/generated.ex` lines 139-156, 196-221): the same code as B, with generator-invented variable names (`world_name_raw`, `worlds_count`, `worlds_rest`) and fully spelled module names. Input: JSON row `[1, "WORLD[count]", "worlds", ...]` in `annotations/L00.json` plus `.structs.WORLD` in `annotations/L01.json`.

`Avatar` (130 bytes, 21 annotation fields), shape C complete: 24 lines (`defmodule`, `use`, 21 field lines, `end`; `field :chrregnum, :u32`, ..., `bits gender: 1, chrclass: 5, race: 2`, `field :equip, {:u16s, 20}`, ..., `field :tutorial_step, :u8`; see `lib/macro/packets.ex`). Shape B: `lib/hand/avatar.ex`, 133 lines, the same 23 names four times (`@enforce_keys`, `@type`, decode head and struct build, encode head); shape A: `lib/gen/generated.ex` lines 3-137, same as B with the long mechanical names.

Size: hand-written 367 lines (21 + 133 + 213) + `wire.ex` 12 shared; macro 79 lines + DSL 200 lines; generated 375 lines + `gen.exs` 294 lines. The DSL needed 7 entry kinds (integer, `char`, `bytes`, `u16s`, nested struct, `bits`, counted array) and no escape hatch.

### 3. Byte-exactness

`mix test`: 27 tests, 27 pass. Per test: decode `{:ok, _}`, known capture values match, one byte more or less gives `{:error, :bad_size}`, `encode(decode(payload)) == payload`.

- All S->C round trips and the C->S `0x1401`, `0x1407` are byte exact in all three shapes, including the uninitialised `delinfo` bytes of `0x0C14` (kept because `u8[5]` is a raw binary).
- `@tag :known_loss` (3 tests): `0x0C65`. The client sends `20151116141627`, NUL, then non-zero garbage to byte 64. `char[64]` keeps only the part before the NUL, so the round trip differs (the test asserts 64 bytes out and different content). Harmless while the server only compares the key; it matters if a codec is used for replay or proxying.
- The rule "`u8[N]` is raw, `char[N]` is a C string" decides what survives; that is a field-semantics decision (section 9).

### 4. What the tools see

Probes (`probes/*_probes.ex`, compiled with `PROBES=1`), the same five per shape. Hard compile errors common to all shapes, checked with `mix run`: an unknown key in a struct literal (`key :sloot not found`) and a missing enforced key.

| # | Probe | Compiler 1.20 | Dialyzer |
|---|---|---|---|
| 1 | `unknown_field` (`p.wm_prot`) | caught x3 (`compiler.txt` 197 hand, 223 gen, 249 macro) | silent |
| 2 | `wrong_field_type` (`wm_port: "9110"` to `encode/1`) | caught x3 (28 hand, 56 gen, 84 macro) | caught x3 (`dialyzer.txt` 411 hand, 312 gen, 510 macro) |
| 3 | `untagged_result` (`%T{} = T.decode(bin)`) | caught x3 (113, 142, 171) | caught x3 (437, 338, 536) |
| 4 | `wrong_element` (`worlds: [:not_a_world]`) | silent | caught x3 (459, 360, 558) |
| 5 | `impossible_compare` (integer vs `:open`) | silent | silent |

- The three shapes are indistinguishable to both tools: macro and generator expand to the same code as the hand-written shape, so every probe has the same result in every shape. The type tools do not decide between shapes.
- The 1.20 compiler takes field types from the code (the binary patterns of `encode/1`: the warning's expected type shows `wm_port: integer()`), not from `@type t`; that is why probe 4, constrained only by `@type`, slips through it. Dialyzer reads `@type`/`@spec` and finds it. Probe 5 slips through both.
- Dialyzer route: Hex reachable, `dialyxir` used. `results/dialyzer.txt` also holds the compile warnings of the compile step it runs first (lines 1-267); the Dialyzer findings start at line 268.

### 5. Readability next to the pseudocode

- Names: official names are in the annotations (`sVersionKey`, `numofavatar`, `nKQHandle`, `CharIDChangeData.bNeedChangeID|bInit`), ours are plain (`world_no`, `wm_port`), some `(inferred)` (`hair/colour/face (inferred)`). B and C use hand-picked snake_case; A one mechanical rule (drop a trailing `(...)`, split camelCase, non-alphanumerics to `_`, lower-case). They differ for 12 `Avatar` fields (`shape_hairtype`, `shape_haircolor`, `shape_faceshape`, `n_kq_handle`, `s_kq_map_name`, `n_kq_coord_x`, `n_kq_coord_y`, `d_kq_date`, `char_id_change_data_b_need_change_id_b_init`, `char_id_change_data_n_row_no`, `tutorial_info_n_tutorial_state`, `tutorial_info_n_tutorial_step`; B/C drop the prefixes). Hungarian prefixes and dotted nesting leak into every caller of A.
- Count fields (`count`, `numofavatar`) vanish in all three shapes (the list length is the count).
- C reads closest to the pseudocode table: one line per field in order; `Avatar` is 24 lines against 133 in B. B and A repeat each name four times. B's strength is plain Elixir: a stack trace or Dialyzer message points at the exact line.
- The JSON note of a field (`"0..5"`, `"1..20 chars, no space"`, the bit description) is carried by none of the shapes: A reads only offset, type, name; B and C would need a hand-written comment or `@doc`.
- Module names come from the official `NC_...` opcode name; 6 of the 250 login/wm annotations have no official name (A falls back to `Op0C0A`-style names).

### 6. A corrected layout flowing in

Simulated: `AVATAR.level` `i16` -> `u16` and `AVATAR.delinfo` `u8[5]` -> five `u8` (`del_year` ... `del_min`). Raw record in `results/correction.txt`.

| | Steps | Hand-edited | diff --stat | Compile | Test |
|---|---|---|---|---|---|
| A | edit JSON copy in `/tmp/issue14-docs`, `PROTO_DOCS=... elixir gen.exs` | 7 JSON entries, 0 Elixir lines | `generated.ex` 32+ 14- | no warning | 26/27 |
| B | edit `lib/hand/avatar.ex` in 4 places | 31+ 15- | `avatar.ex` | no warning | 26/27 |
| C | edit the `Avatar` definition in `lib/macro/packets.ex` | 6+ 2- | `packets.ex` | no warning | 26/27 |

- Who noticed: in every shape exactly one test failed (`KeyError key :delinfo not found`, the test's own check of the garbage bytes); no compiler warning, because nothing outside the test reads `delinfo`. The round-trip comparison still passed, so the tools prove consistency only; right versus wrong needs a new capture decoded into new expectations.
- Drift: A is the only shape with a source of truth the code can drift from, and the only one where drift is detectable by a command: `elixir gen.exs && git diff --exit-code lib/gen` (observed: the generator run on the corrected copy shows the change in `git diff`; a re-run on the real docs leaves `git status` clean). Nothing runs it automatically yet. B and C have no link to `docs/protocol`: a correction is two edits that nothing ties together (inferred, not tested).
- In B the compiler checked that all four places agree.

### 7. Generator reality check

`results/coverage.txt`, counted without the override, over every login/wm packet with direction C->S or S->C in the merged annotations (250):

- 205 generate cleanly (82 %), 45 do not (login 17 of 18, wm 188 of 232).
- Top reasons: 16x the array count field is not the preceding integer field, 7x `char[len]`, 3x each offset gaps, `DATE`, `PROTO_AVATAR_SHAPE_INFO`, `entries[n]`, a struct with an offset gap.
- Caveat: "generates cleanly" is about the grammar, not correctness. A layout with a note like "more appearance bytes follow; not decoded" still counts as fine. How many of the 205 are such partial layouts was not counted.
- Overrides in `gen.exs`: 1. The bitfield byte `shape.race|chrclass|gender` is plain `u8` in the annotation, the bit layout is only in the free-text note. Each further bitfield costs one override.
- Merge rule copied: sorted annotation files, later file wins per `(server, opcode, dir)`, missing struct falls back to `pdb2016-layouts.json`, directions normalised. It is a copy of `load_docs()` in `tools/protocol-re/pcap_decode.py`, so the two can disagree. For `AVATAR.level` the winning annotation says `i16`, the 2016 PDB `u16` (not changed here).
- Rules the generator invents: the identifier rule, "the count field is the preceding integer field and disappears", "the array is the last field", "`u8[N]` and `bytes[N]` are raw".

### 8. Recommendation (for the human to confirm)

Shape C (macro) as the checked-in definition, optionally fed by shape A's generator emitting the DSL instead of expanded code (that combination is not built).

1. The type tools cannot choose between shapes and byte-exactness is equal, so readability and cost decide: C is 79 lines against 367 (B) and 375 (A), reads like the pseudocode table, and a correction is a 6-line edit in one place.
2. A already covers 82 % of the login/wm annotations, so a generator emitting `field :slot, :u8` lines would keep definitions reviewable and give a `git diff --exit-code` drift check.

Main cost: a 200-line macro to own, with error messages that point into the macro and a type vocabulary (`:u16s`, `bits`, `array`) every contributor must learn. Fallback: B, the longest but plain Elixir with exact stack traces.

### 9. Open points for the human

1. `char[N]` keeps raw bytes or not (decided here: cut at the first NUL, which loses the `0x0C65` garbage).
2. Count fields are not struct fields (decided here); a mismatched count is `:bad_size`; the official names (`numofavatar`) vanish.
3. Strict length: a trailing byte is `:bad_size`. The `0x1401` annotation once said "more appearance bytes follow"; longer packets from other client builds are not settled.
4. `i16` vs `u16` for `AVATAR.level` (annotation `i16`, 2016 PDB `u16`) and `tutorial_state` (annotation `u32`, 2017 PDB `i32`): which source wins is a policy. `docs/protocol` was not edited.
5. Field-name policy: mechanical (long, Hungarian prefixes) or hand-picked (needs a list); bitfields split into three fields in B/C, by an override in A.
6. Field notes (ranges, status codes) have no home in any shape.
7. Nothing in any shape limits `slot` to `0..5` or `status` to the documented codes.

### 10. Not checked

- Only 8 packets and 2 structs: no conditional layouts, nested arrays, length-prefixed strings, trailing-byte packets.
- No property or fuzz tests; `decode` tried only on the fixtures plus one byte more or less. No performance measurement.
- The generator never ran on packets beyond the 8 (coverage only counts); the 205 are not 205 verified codecs.
- The password packet `0x0C5A` is excluded.
- No test against the real client; framing and cipher not exercised.
- Observed on Elixir 1.20.5 / OTP 29 / dialyxir 1.4.9 only. Credo and `mix check` (other ADR 0003 gates) not set up.
- The corrected layout is a simulation; the new values are not from a capture.
