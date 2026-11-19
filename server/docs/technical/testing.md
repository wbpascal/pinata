# Testing

Byte-compatibility with the 2016 client is proven by capture replay ([ADR 0008](../../../docs/adr/0008-byte-compatibility-proven-by-capture-replay.md)). A Capture is converted into a Transcript, and a Replay test plays the Transcript against the server. The test client and the replay harness live in `server/test/support/`; this page describes both.

## Transcripts

A Transcript is a text file with one line per decrypted client-facing packet of one Capture. It lives in `server/test/replay/transcripts/<capture>.txt`. The Capture and its scenario notes are `re-data/captures/<capture>.pcapng` and `.md`. Elixir never parses pcap.

### Format

```
# transcript of 26_11_15_login-logout.pcapng (format: server/docs/technical/testing.md)
# start 1794732629.955599
1794732629.955599 login#1 S 0x0807 6301
1794732629.964827 login#1 C 0x0C65 3230313531313136...
1794732634.007957 wm#1 C 0x080D -
```

- Exactly two header lines start with `#`: the capture file name, and `start`, the timestamp of the first frame of the capture. The relative time of `docs/protocol/capture-validation.md` is `time - start`.
- A packet line has five fields separated by one space:
  1. capture timestamp, epoch seconds, six decimals;
  2. connection `login#N`, `wm#N` or `zone#N` (Login, WorldManager, Zone), numbered in order of first appearance in the capture; the ids are the same as in the normal output of `pcap_decode.py`;
  3. direction, `C` = client to server, `S` = server to client;
  4. opcode, `0x` and four upper-case hex digits;
  5. payload, the decrypted bytes after the 2-byte opcode, lower-case hex without separators; `-` when empty.
- Lines are in capture order across all connections. ASCII, `\n` line ends, newline after the last line.

### What a transcript does not hold

- Server-link traffic between the original processes.
- TCP open and close. Three captures hold no SYN/FIN frames at all; a connection opens before its first line.
- Opcode names and decoded fields (the normal output of `pcap_decode.py` has them).
- Masking: the `0x0C5A` password field is in clear, so captures must use test accounts only.

### Converting a capture

```bash
python3 -I tools/protocol-re/pcap_decode.py --transcript server/test/replay/transcripts <capture.pcapng> ...
```

Converting an unchanged capture rewrites the file identically. A capture is refused (message on stderr, exit 1, no file written) when a client-facing stream has a gap, a brute-forced (unseeded) decrypt or a framing problem other than ignored retransmits.

Before committing a transcript, review it for sensitive data: account names, password hashes, IP addresses, anything that looks like a real person, mail address or public host. The accounts in the five transcripts are `admin` and `testaccountB` (MD5 hashes of the test passwords), IPs are the private LAN addresses `172.16.42.214` and `172.16.42.15`.

### Transcripts in the repository

| File | Packets | Connections | Scenario |
|---|---|---|---|
| `26_11_15_login-logout` | 26 | login 2, wm 1 | login, select world, see characters, logout |
| `26_11_15_login-errors` | 44 | login 3, wm 2 | wrong password, two clients on one account, first is kicked |
| `26_11_15_create-char` | 30 | login 1, wm 1 | create a character, then delete it |
| `26_11_15_37_login-heartbeat-refusals-delete` | 122 | login 6, wm 1 | login side: idle heartbeat, refusals, character delete |
| `26_11_16_37b_char-select-rename-refusals` | 495 | login 3, wm 3, zone 5 | character-select paths: create error, rename, character login error, rename right |

## Test code layout

`server/test/support/` holds test-only code: `TestClock`, `TestClient`, `Replay` and the `Replay.*` modules. `server/test/test_helper.exs` loads it. It is not part of the application, so the `boundary` compiler and Dialyzer do not see it.

## Test client

`TestClient` is a TCP client of the client-facing protocol. It frames, encrypts and decodes like the 2016 client. It starts its cipher when it receives the seed packet `0x0807`.

| Function | What |
|---|---|
| `connect(host, port)` | opens the connection, reads nothing, raises on failure |
| `recv_raw(client, timeout)` | next body (opcode and payload): `{:ok, body, client}` or `{:error, :timeout \| :closed}` |
| `recv(client, timeout)` | `recv_raw/2` and `Proto.decode/1`; adds `:unknown_opcode`, `:bad_size` |
| `send_raw(client, body)` | encrypts, frames, sends; raises before the seed was received |
| `send_packet(client, packet)` | `send_raw/2` of `Proto.encode/1` |
| `expect(client, packet, timeout)` | asserts that the next packet is exactly `packet` |
| `close(client)` | closes the socket |

```elixir
client = TestClient.connect(~c"127.0.0.1", port)
{:ok, %Proto.Packets.MiscSeedAck{}, client} = TestClient.recv(client)
{:ok, client} = TestClient.send_packet(client, %Proto.Packets.MiscHeartbeatReq{})
client = TestClient.expect(client, %Proto.Packets.MiscHeartbeatAck{})
```

## Replay harness

`Replay.run/2` plays a Transcript and returns `:ok` or `{:error, %Replay.Failure{}}`. `Replay.assert_replay/2` fails the test with the failure message. Options:

| Option | Meaning |
|---|---|
| `stop:` | required: the last packet index to play, or `:end` |
| `endpoints:` | required: connection kind (`login`, `wm`, `zone`) to `{host, port}`; use `Replay.Topology.endpoints()` |
| `masks:`, `handles:` | per-test additions to the global lists |
| `close_after:` | packet indices; the harness closes the connection of that packet right after it (the transcript holds no TCP close) |
| `sync_after:` | packet indices; a heartbeat round trip after each, so the server has handled the packet before the clock moves on |
| `timeout:` | milliseconds to wait for a server packet, default 2000 |

**Pacing.** Client packets are sent in capture order. Each one is sent after all earlier server packets of the Transcript arrived. Order is compared per connection only. A connection is opened right before its first line. All connections are closed when the replay ends.

**Clock.** The harness puts `TestClock` in as the clock source and sets it to the capture timestamp before each connection open and each client packet. The clock source is global, so replay tests are not async.

**Stop point.** Packets with an index above `stop:` are not played. Each Replay test uses the highest index the server supports so far: the way back to the world list (issue #47): `:end` for `login-logout` and 70 for `37_login-heartbeat-refusals-delete`; the successful `0x0C0C` for the others (18 for `login-errors`, 11 for `create-char`, 9 for `37b_char-select-rename-refusals`). `milestone1_test.exs` leaves the lines of later issues out of every replay (`0x0C14`, `0x080D`, `0x1401`, `0x1406`, `0x1407`, `0x140C`); the indices stay. `milestone1_test.exs` can replay one connection of a capture (it keeps only the packets of that `conn`, the indices stay): `login#3` up to 90 with the world closed (its WorldManager process stopped) and `login#4` up to 108 with the world full (2375 players in the `:pg` group).

**Timer-driven opcodes.** `0x0804` (heartbeat) and `0x080E` (game time) come from timers. `S` lines with these opcodes are not expected, and received packets with these opcodes are dropped. Client lines are always sent.

**Extra packets.** At the end the harness sends a client heartbeat on every open connection and reads until the `0x0805` answer. Anything else read before it is an extra packet. A connection the server closed has no extras.

**Failures.** `kind` is `:mismatch` (bytes differ), `:unexpected` (other opcode), `:missing` (timeout or closed connection), `:extra` or `:handle`. The message looks like this:

```
replay of handwritten failed: byte mismatch
connection: login#1
packet index: 3
opcode: 0x7F01 unknown
  code: expected 0200, got 0100
```

The opcode name comes from `docs/protocol/opcodes.json`. The field lines need a packet module (found through a mask or handle entry, else `Proto.Packets`); without one the line is `payload: expected ..., got ...`.

## Masks

A Mask is `{packet_module, path, reason}`. The field is zeroed in both payloads before the comparison. The reason is required: an empty reason or an unknown field raises `ArgumentError`. `Replay.Masks.global/0` is the one list of masks every replay uses (the seed, the payload byte of `0x0C66` L00-B1, and in `0x0C0C` the `ip` and the `validate` key, P02-B23); a test adds its own with `masks:`. A path is a field name or a list of names through nested structs and arrays (`[:items, :id]` is the `id` of every element).

Paths resolve to byte ranges through `mod.__packet__().layout`, a list of `{name, offset, size, sub}` per field (offset in the payload; for an array the offset of its count and size `nil`). A `bits` field masks its whole byte.

## Handle map

A handle is `{packet_module, path, namespace, reason}`: a value the server picks anew in each run (identifiers, item keys). In a server packet, the first time a captured value is seen it is bound to the received value; later the received value must equal the bound one, and one received value cannot belong to two captured values. A violation is a `:handle` failure. In a client packet the captured value is replaced by the bound one; a captured value that was never bound is a `:handle` failure. `Replay.Masks.handles/0` is the global list: the login token (`:login_token`, `0x0C34` and `0x0C37`) and the world key (`:world_key`, `0x0C0C` and `0x0C0F`).

## Setup functions

`Replay.Setups` has one function per capture. It builds the state the capture starts from, with public `Persistence` operations where one exists, a test-only factory otherwise, never a database dump. Each one empties the accounts table and creates the account `admin` (the client sends the MD5 text of the password, as in every transcript). Later issues add characters.

## Topology

`PINATA_TEST_TOPOLOGY` selects where the replay connects. `single` (default) uses the application `test_helper.exs` starts, on ports 9010, 9110, 9210. `multi` raises, because it is completed by issue #48. Another value raises. The database follows `DATABASE_URL` as for any test. The variable is for tests only, so it is not in the user documentation.

## Adding a replay test

1. Convert the Capture to a Transcript (above) and review it.
2. Add or extend its function in `Replay.Setups`.
3. Write the test: call the setup function, `Replay.Transcript.read!/1` the file, `Replay.assert_replay/2` with `stop:` and `endpoints: Replay.Topology.endpoints()`. See `server/test/replay/milestone1_test.exs`.
4. Mask every field the server cannot reproduce, each with a reason (global list for a field of the packet itself, `masks:` for one test).

## Peer nodes

`TestPeers` (`test/support/test_peers.ex`) starts two `:peer` nodes, one with `PINATA_PARTS=login` (client port 9310) and one with `world_manager` (port 9311). They share one settings file, the database of the test VM, and the cookie; they are connected to each other, not to the test VM, so the control connection is standard I/O. `TestClock` is loaded on both peers so a test can move their clocks. `test/world_manager/hand_off_test.exs` runs every test in both topologies: `:single` (the application of the test VM, ports 9010 and 9110) and `:peers`.

## Limits

- Connections are closed at the end of the replay, or after the packets listed in `close_after:`.
- The endpoint comes from the connection kind, not from the address the server sends.
- A `bits` field masks its whole byte.
- The handle map has no sentinel values and random game values are not handled.
