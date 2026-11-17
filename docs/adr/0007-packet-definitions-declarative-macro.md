# Packet definitions use a declarative macro, seeded once from the protocol docs

Each packet and shared struct is one module that lists its fields in wire order with a small macro: `use Proto.Packet, opcode: 0x0C0A`, then `field :world_no, :u8`, `field :world_name, {:char, 16}`, `bits gender: 1, chrclass: 5, race: 2`, `array :worlds, World, count: :u8`. The macro expands to the ADR 0003 contract: `@enforce_keys`, `@type t`, `opcode/0`, `decode/1 :: {:ok, t} | {:error, :bad_size}` (never raises) and `encode/1`. Scope is the payload only. Framing and the cipher sit below it.

The definitions are written once, from `docs/protocol`, when a milestone first needs a packet. A generator may write the first draft. From then on the Elixir is hand-owned, like the CSV tables of ADR 0005. A correction from a capture goes into both the annotation and the module. Nothing regenerates the code or checks it against the docs.

We chose this after the prototype of issue #14 (branch `agent/issue-14`, `prototypes/packet-codec/README.md` "Findings"). The prototype built 8 login/character packets in three shapes: generated from the JSON, hand-written binary matching, and this macro. All three were byte-exact on captured payloads. The 1.20 compiler and Dialyzer saw exactly the same thing in each, because the macro and the generator expand to the hand-written code. Readability therefore decided. The macro needs 79 lines, against about 370 for each of the others. It reads like the pseudocode's field table, and a layout fix is one local edit. A generator that always regenerates was rejected: 18 % of the login/wm annotations do not fit its grammar, bitfields and names need overrides, and it would copy the merge rules of `pcap_decode.py`.

## Rules

- `char[N]` decodes to the text before the first NUL, and encode pads it with zeros. Bytes the client leaves after the NUL are dropped. We only talk to the 2016 client and never replay or proxy, so they carry nothing.
- `u8[N]` / `bytes[N]` stay raw binaries and round-trip exactly, uninitialised bytes included.
- Lengths are strict: a missing or extra byte, or a count that does not match the data, is `{:error, :bad_size}`. A packet that is proven by a capture to have a variable tail gets an explicit trailing field.
- An array's count field is not a struct field: the list length is the count.
- Field types: when an annotation and the 2016 server PDB disagree, the PDB wins on the type, the annotation wins where the PDB is silent, and a capture overrides both. The annotation is fixed when the conflict is found (e.g. `AVATAR.level` is `u16`, not `i16`).
- Field names are hand-picked snake_case without Hungarian prefixes. The official name goes in a comment on the field line when it differs.
- The codec checks only sizes. Ranges and allowed codes (`slot` 0..5, `status`) are checked by the handler that uses the field.

## Consequences

- The macro (about 200 lines) is ours to own. Its error messages point into the macro, and contributors must learn its small type vocabulary (integers, `char`, `bytes`, `u16s`, nested struct, `bits`, counted `array`).
- The type checker sees field types only through the generated `encode/1` patterns, so a wrong list element type is caught by Dialyzer alone. Both gates stay required (ADR 0003).
- `docs/protocol` and the code can drift. The guard is the captured-payload round-trip tests per packet, not a generator.
- Not yet tried: conditional layouts, nested arrays, length-prefixed strings. The macro grows an entry kind when the first such packet is needed.
