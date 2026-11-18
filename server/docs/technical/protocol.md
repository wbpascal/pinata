# Protocol

The `Proto` boundary holds the client protocol as pure code: no sockets and no processes. Reasons and rules: [ADR 0007](../../../docs/adr/0007-packet-definitions-declarative-macro.md). Wire facts: [`docs/protocol/README.md`](../../../docs/protocol/README.md) section 1. Defined packets: [`packets.md`](packets.md).

## Chains

- Receive: `Proto.Framing.split/1`, then `Proto.Cipher.crypt/2` on the body, then `Proto.decode/1`.
- Send: `Proto.encode/1`, then `Proto.Framing.frame/1`. Server to client is not encrypted.

A later session part chains them. This change adds no client flow across parts, so there is no sequence diagram.

## Framing

A body under 256 bytes has a one-byte length. A longer body has a zero byte, then the length as u16 little-endian. `split/1` returns `{:ok, body, rest}` or `:more` for an incomplete buffer and never rejects a length. A body shorter than 2 bytes is returned as is, and `Proto.decode/1` answers `{:error, :bad_size}`. The caller still runs the cipher over every body so the index stays in step. `frame/1` returns `{:error, :too_large}` for a body of 0x1FFE bytes or more.

## Cipher

Client to server only, over the whole body (opcode and payload), not the length prefix. The index starts at `seed % 499` (`Proto.Cipher.new/1`), advances one per byte across packets and wraps to 0 after 498. `crypt/2` returns the result and the next index; it both encrypts and decrypts.

## Packet definitions

`use Proto.Packet, opcode: 0x....` (no opcode for a nested struct), then:

- `field :name, :u8 | :u16 | :u32 | :i16 | :i32`
- `field :name, {:char, n}`, `{:bytes, n}`, `{:u16s, n}`, or a nested struct module
- `bits [a: 1, b: 5, c: 2]`: one byte, most significant bit first
- `array :name, Module, count: :u8`: the last entry

Rules: a `char[n]` is cut at its first NUL on decode and zero-padded on encode (bytes after the NUL are lost); lengths are strict, any other size is `:bad_size`; an array count is not a struct field. Field names are hand-picked snake_case, with the official name in a comment when it differs.

## Adding a packet

1. A module in `lib/proto/packets/<dept>.ex`.
2. A line in `Proto.Packets`.
3. `mix pinata.packets_doc`; `mix check` fails while `packets.md` is stale.
4. A round-trip test with a captured payload.

## Results of `Proto.decode/1`

`{:ok, struct}`, `{:error, :unknown_opcode}`, or `{:error, :bad_size}` (payload of the wrong size, or fewer than 2 bytes).
