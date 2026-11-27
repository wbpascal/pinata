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

Before committing a transcript, review it for sensitive data: account names, password hashes, IP addresses, anything that looks like a real person, mail address or public host. The accounts in the eleven transcripts are `admin` and `testaccountB` (MD5 hashes of the test passwords), IPs are the private LAN addresses `172.16.42.214` (server) and `172.16.42.231`, `172.16.42.15`, `172.16.42.239`, `172.16.42.174` (clients).

### Transcripts in the repository

| File | Packets | Connections | Scenario |
|---|---|---|---|
| `26_11_15_login-logout` | 26 | login 2, wm 1 | login, select world, see characters, logout |
| `26_11_15_login-errors` | 44 | login 3, wm 2 | wrong password, two clients on one account, first is kicked |
| `26_11_15_create-char` | 30 | login 1, wm 1 | create a character, then delete it |
| `26_11_15_37_login-heartbeat-refusals-delete` | 122 | login 6, wm 1 | login side: idle heartbeat, refusals, character delete |
| `26_11_16_37b_char-select-rename-refusals` | 495 | login 3, wm 3, zone 5 | character-select paths: create error, rename, character login error, rename right |
| `26_11_15_idle_in_world` | 208 | login 2, wm 1, zone 1 | enter the world and stand idle |
| `26_11_15_walk-run-portals` | 1057 | login 1, wm 1, zone 6 | walk, run, town portal to other maps |
| `26_11_15_14_second-client-in-sight` | 10954 | login 2, wm 2, zone 2 | two clients: B enters and leaves A's sight |
| `26_11_16_38_session-loss-kicks-char-select` | 2271 | login 15, wm 12, zone 10 | session loss, kicks, back to character select |
| `26_11_21_45_walk-sit-emote-stop-shout-whisper-cast-abort` | 1980 | login 2, wm 2, zone 2 | two clients: walk, sit, emote, stop, shout, whisper, cast abort |
| `26_11_21_52_stale-tutorial-rename-kickout-shn` | 1149 | login 8, wm 8, zone 6 | stale tutorial state, rename, `&kickout`, changed `MapViewInfo.shn`; bytes for hand-written tests |

In the two-client captures (scenarios 14, 45, 52) the connections are numbered in order of first appearance; in scenario 14 `login#1` / `wm#1` / `zone#1` are client A (`admin`) and `login#2` / `wm#2` / `zone#2` client B (`testaccountB`).

## Test code layout

`server/test/support/` holds test-only code: `TestClock`, `TestClient`, `TestPorts`, `Replay` and the `Replay.*` modules, and the load run (`Load`, `Load.Player`, `Load.Placement` and the script `load.exs` of `mix pinata.load`, see [`load-run.md`](load-run.md)). `server/test/test_helper.exs` loads it. It is not part of the application, so the `boundary` compiler and Dialyzer do not see it.

The telemetry tests are in `server/test/pinata/`: `figures_test.exs` (buckets, percentiles, merge, the printed text), `figures_peers_test.exs` (`Pinata.Figures.collect/0` over the three peer nodes) and `otel_test.exs`. `otel_test.exs` restarts the OpenTelemetry applications of the test VM and changes its `OTEL_TRACES_EXPORTER`, `OTEL_METRIC_READERS` and `OTEL_EXPORTER_OTLP_ENDPOINT` variables, so it is `async: false`; it restores both when it ends.

## Ports

No test listens on or connects to a fixed port. Every port comes from the operating system through `TestPorts` (`test/support/test_ports.ex`): `TestPorts.free(n)` binds `n` sockets on all addresses with port 0, reads the ports back and closes them. A port where a connect to `127.0.0.1` still succeeds afterwards is dropped and replaced: on Windows another program can listen on `127.0.0.1:9010` while our listener binds `0.0.0.0:9010` without an error, and the connections then reach the other program (Logitech G HUB does this on 9010).

- `test_helper.exs` calls `TestPorts.choose_app()` before it writes the test settings file, so the application of the test VM listens on three such ports; `TestPorts.app()` returns them (`%{login:, wm:, zone:}`) and `TestPorts.endpoint(part)` the `{host, port}` a test connects to.
- `TestPeers.start/0` takes three new ports per call; the digest test takes one more for its Zone node.
- `test/start_test.exs` restarts the application with the ports of `TestPorts.app()` (stopped at that moment, so free); the port-in-use test holds a listener on port 0 and names its port in the file.
- A test that starts its own `Net.Listener` passes port 0 and reads the port with `ThousandIsland.listener_info/1` (`test/login/login_test.exs`, `test/net/connection_test.exs`).
- The defaults 9010, 9110 and 9210 appear only as values: `test/settings_test.exs` checks the defaults, and packets of the captures carry 9110. A replay masks `port` of `UserWorldselectAck` whenever the WorldManager endpoint is not 9110, which with ports from the OS is practically always. The one exception is `test/support/smoke.exs`, which CI runs with the Login port 9010 (it takes the WorldManager port from the world-select answer): it runs against the published ports of the Compose example or the default ports of a release and is not part of `mix test` (see "Smoke test").

A port is free when chosen and is bound a moment later; another process can take it in between. macOS hands out port-0 ports in sequence, Linux at random, so on Linux a port just released can be handed out again to the next bind on port 0. `TestPeers.start/0` closes this window for the peers by choosing their ports after the peer VMs are up (each VM binds its distribution listener on port 0 while booting); for the application of the test VM the window is a few milliseconds. It stays open for the Zone node of the digest test (its VM boots after `TestPorts.free(1)`) and for the stop/start cycles of `test/start_test.exs` and `test/persistence/migrations_test.exs`. A collision shows as a failed start of the part: `cannot listen on port <n>: address already in use`.

## Test client

`TestClient` is a TCP client of the client-facing protocol. It frames, encrypts and decodes like the 2016 client. It starts its cipher when it receives the seed packet `0x0807`.

| Function | What |
|---|---|
| `connect(host, port)` | opens the connection, reads nothing, raises on failure |
| `try_connect(host, port)` | opens the connection, reads nothing: `{:ok, client}` or `{:error, reason}` |
| `recv_raw(client, timeout)` | next body (opcode and payload): `{:ok, body, client}` or `{:error, :timeout \| :closed}` |
| `recv(client, timeout)` | `recv_raw/2` and `Proto.decode/1`; adds `:unknown_opcode`, `:bad_size` |
| `poll(client, timeout)` | like `recv_raw/2`, but a timeout returns `{:timeout, client}` with the bytes read so far, so a client that polls loses no partial frame |
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
| `stop:` | required: the last packet index to play, `:end`, or `{:cut, seconds, reason}` (a Replay cut, see below) |
| `endpoints:` | required: connection kind (`login`, `wm`, `zone`) to `{host, port}`; use `Replay.Topology.endpoints()` |
| `masks:`, `handles:` | per-test additions to the global lists |
| `close_after:` | packet indices; the harness closes the connection of that packet right after it (the transcript holds no TCP close) |
| `sync_after:` | packet indices; a heartbeat round trip after each, so the server has handled the packet before the clock moves on |
| `before:` | a map of packet index to a zero-arity function, run before the harness sends that client packet; the scenario 14 replay switches the random source to `TestRandomSpot` before `&linkto` (10773), so the free spot is the captured point |
| `deferrals:` | per-test additions to `Replay.Deferrals.global/0` (see Deferrals) |
| `map_names:` | `{packet_module, path}` of the server packets that carry the name of the map a connection is on, added to `Replay.Masks.map_names/0`; the handle scope per map follows it |
| `tick_offset:` | whole milliseconds, 0 or more, added to the first tick of a train (see Clock) |
| `late_ms:` | whole milliseconds, default 0: how far the clock may run ahead of a Zone server line whose packet has not arrived (see Clock) |
| `drop_after:` | packet indices; after each the harness kills the server side of that connection and expects the client to see the close |
| `timeout:` | milliseconds to wait for a server packet, default 2000 |

**Pacing.** Client packets are sent in capture order. Each one is sent after all earlier server packets of the Transcript arrived. Order is compared per connection only. A connection is opened right before its first line. All connections are closed when the replay ends.

**Clock.** The harness puts `TestClock` in as the clock source and sets it to the capture timestamp of every Transcript line (client, server and timer-driven) before the harness opens the connection or sends or expects the packet. Server lines on Login and WorldManager move the clock too; if the server may still be working on the client packet before such a line, `sync_after:` is the tool. The clock source is global, so replay tests are not async.

Only the tick of a map instance is scheduled through `Clock.send_after/3`; heartbeat, game time and auto-save stay real timers. `TestClock.set/1` fires every tick that is due at the new time, earliest first (the first of equal times first), moves the clock to its due time, and waits for the receiver (`:sys.get_state/2`, so a tick receiver is an OTP process; a dead one is skipped). A tick that is scheduled while a tick fires gets no offset, so the period stays exact. `tick_offset:` is added once, to a tick scheduled from outside a running tick (the first of a train): the Zone's first tick is not aligned with the capture. At the end the harness restores the clock source, erases the offset and delivers the pending ticks at once without waiting (`TestClock.reset/0`); dropping them would leave a map instance that waits for its tick without a tick.

The clock never runs backwards: a line whose timestamp lies below the clock leaves it where it is. **`late_ms:`**:
before a server line of a `zone#N` connection whose packet is not buffered yet, the harness runs a heartbeat round
trip; when the packet is still not there, it moves the clock on by at most 100 ms (up to `late_ms` in all) and runs a
round trip again, until the packet is there; then the line is compared as usual (a packet that never comes is still
`:missing`). The reason is the tick-driven appears of a walk: the original handled a client packet 5 to 60 ms after
it was captured and ticked at its own phase, so in `walk-run-portals` a simulation puts each NPC appear between
28 ms before and 54 ms after its captured time, plus up to 100 ms of tick phase. With the clock held at the line's
timestamp that replay fails for every tick phase; with `late_ms: 200` it passes for all.

**Zone heartbeat round trip.** After every client packet on a `zone#N` connection (except a client `0x0804`, whose `0x0805` answer is a Transcript line) the harness sends a heartbeat and reads until the `0x0805` answer. The server packets read on the way are buffered per connection and compared at their own Transcript lines, so the Zone has handled the packet, and sent its answers, before the clock moves on. The Zone must have finished a client packet, map instance included, before its connection answers the next `0x0804`. A buffered packet that no line asks for is an extra packet at the end. A connection the server closed meanwhile is not a failure there (it is for a packet in `sync_after:`).

**Server-side drop.** `drop_after:` finds the server-side process of a connection among the TCP ports of the node of the part: the port whose remote port is the local port of the client socket and whose own port is the port the client connected to. It waits until that process has ended the callback it is in (`:sys.get_state/1`), so every packet of the handled client packet is sent, kills it (`Process.exit(pid, :kill)`), then reads the client socket until it is closed. Another packet on the way is an `:extra` failure, no close within `timeout:` a `:missing` one. The connection is then gone from the replay; the transcript holds no TCP close.

**Two clients.** Connections named `zone#1` and `zone#2` are two clients on the Zone listener; they share the handle scope of a map (see Handle map).

**Stop point.** Packets with an index above `stop:` are not played. Each Replay test plays everything of its capture that the milestones built so far cover:

| Capture | Played | Not played yet |
|---|---|---|
| `login-logout` | `:end` (the capture never enters the world: no map entry) | – |
| `login-errors` | `:end`, with the second login that cuts the first (`0x0C17`) | – |
| `create-char` | `:end`, creation and delete included | – |
| `37_login-heartbeat-refusals-delete` | 1 to 70: both creations (indices 31/32 and 39/40), the delete between them and the way back to the world list. Then one connection per test: `login#3` (71 to 90) with the world closed, `login#4` (91 to 108) with the world full, `login#5` (109 to 115) with account B blocked, `login#6` (116 to 122) with account B not login-able | – |
| `37b_char-select-rename-refusals` | 1 to 26: the character list, the refused create (`0x1404 {0x181}`) and five heartbeats | from 27 on: rename (`0x140F`), character login and the Zone connections, milestone 2 |
| `idle_in_world` (`milestone2_test.exs`) | `:end`: login, character login, the map login `0x1801`, both map-entry bursts, the WorldManager burst, the login-time requests, the idle minute, the leave (`0x2012`, `0x1071` and the option saves get no answer), `0x0C33` and `0x0C18 {0}`, the token login at Login | deferred: mob moves (milestone 4), the reset of abstate 291 with its `0x1035` at 145 and 146 (milestone 4), the expiry of the pick-up mini-mon at 161 to 168 (milestones 3 and 9), the Kingdom Quest notices (milestone 10) |
| `walk-run-portals` (`milestone2_test.exs`, `late_ms: 200`) | `:end`: login, character login, the map entry, the walks, runs and stops (no other player: nothing relayed), the NPC appears of the steps, the five map changes (the town portal `0x181A` at 228, 343, 453, 583 with `0x181B` and `0x180A`; the gate `0x200A` at 847 with the menu `0x3C01` and "Yes" `0x3C02` at 856), each new Zone connection with the full burst and the WorldManager connection with `0x5826` and `0x182A`; the client closed each old Zone connection after its `0x180A` (`close_after:` 231, 346, 456, 586, 857) | deferred: the target select `0x2401` (combat), the clicks on the town portal NPC with `0x243D` and the menu `0x201C` (NPC menus), the late `0x1035` (milestone 4), the arrival placement and its sight border effects (milestone 4) |
| `38_session-loss-kicks-char-select` (`milestone2_test.exs`) | to the cut at 547 s: back to character select and the same character again, quit, the Zone connection reset by the server (`drop_after:` 386), a second client of the account, the reset again (`drop_after:` 547), the killed client (`close_after:` 718, 722), the login after it | behind the cut: `&getmoney` and the zone kills (items, milestone 3; the killed-map test of `test/leave_world_test.exs` covers the rule) |
| `45_walk-sit-emote-stop-shout-whisper-cast-abort` (`milestone2_test.exs`, `late_ms: 200`) | to the cut at 471 s: two players A and B in sight of each other, the walk and run relays, the sit `0x2020 {7}` and the jump, the dance three times and the step that ends it (`0x2021` to both, `0x2025` to A), B leaving and entering A's sight at run speed (`0x1C0E`, `0x1C06` with B's emote state), the shout out of sight and the whisper to an unknown name | behind the cut: `&mb`, the mob, B's death and town revive, the casts (combat, milestone 4); deferred: B's GM setup at 104 to 152 s (items, stats, skills), the empty `0x1047` boxes (`:extra`, milestone 3), the bow and the `y` of B's appear at 888, the `0x1C0E` of object 14204 at 879, abstates, the regular `0x1035`, the mob chat; masked: the positions of the move relays (below) |
| `14_second-client-in-sight` (`milestone2_test.exs`, `late_ms: 200`) | `:end`: A (`Test1235`, admin level 100) and B (`X14B`, created in the capture, tutorial skipped), both entries, the moves and the sight between them, shouts, whispers, the stance, emotes and jumps, and A's GM commands: `&hide` (1086, 1087), `&show` (1110, 1112), `&dimensio 1` (1148), `&dimension 1`, `-1`, `-1`, `70000`, `0` (1150, 7139, 8418), `&linkto` with its `0x1809` (10774, the free spot of `TestRandomSpot`) and `0x1805` (10775), the map entry after it | deferred: the combat of step 5 (milestone 4), the P02-B27 storm 431 s to 492 s (fixed by decision), abstates, monsters, items, the regular `0x1035` |

`milestone1_test.exs` can replay one connection of a capture (it keeps only the packets of that `conn`, the indices stay). The world is closed by stopping its WorldManager process and full with 2375 players in the `:pg` group; the flags of account B are set through `before:`. The `37b` test adds three masks of its own: the rename-right fields of `0x0C14` (`need_change_id`, `change_id_init`, `change_id_row_no`), because the rename right of `Test2` belongs to milestone 2.

`0x140F` and `0xB409` of `37b` are not replayed (the fixed P02-B42 and the deferred rename right change the answers). `test/world_manager/character_rename_test.exs` covers them with the request bytes of the transcript.

**Timer-driven opcodes.** `0x0804` (heartbeat), `0x080E` (game time) and `0x0849` (server time) come from timers. `S` lines with these opcodes are not expected, and received packets with these opcodes are dropped. Client lines are always sent, so the `0x080E` answer to the client's `0x080D` is not compared by a replay; `test/world_manager/character_list_test.exs` checks its bytes. The original sends `0x0849` every full minute; the capture shows it 4 ms before the minute, so no injected clock can place it. The rebuild sends only its first-join copy in the WorldManager burst, which `test/map_entry_test.exs` and `test/world_manager/server_time_test.exs` check.

**Extra packets.** At the end the harness sends a client heartbeat on every open connection and reads until the `0x0805` answer. Anything else read before it is an extra packet. A connection the server closed has no extras. An `:extra` deferral does not apply to this check.

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

A Mask is `{packet_module, path, reason}`. The field is zeroed in both payloads before the comparison. The reason is required: an empty reason or an unknown field raises `ArgumentError`. `Replay.Masks.global/0` is the one list of masks every replay uses (the seed, the payload byte of `0x0C66` L00-B1, the `ip` of `0x0C0C`, and `delinfo` (P02-B1) and `kq_date_unused` (P02-B7) of the AVATAR in `0x0C14`, `kq_date_unused` of the AVATAR in `0x1406`, the `chrregnum` of `0x10E4`, `0x10E7` and `0x10EA` (Z18-B19), the `slot` of `0x1C05` (Z18-B10), the byte of `0x182A` (P02-B2), the `stray` byte of `0x302D` (P02-B3) the first byte of `0x2011` (Z09-B54), the `flag` of `0x200D` (P02-B29), the `item_link_count` of `0x200F` (W04-B4) and the `moveattr` of `0x2018` and `0x201A` (Z02-B2), the `zone_ip` and `zone_port` of `0x180A` (server address, as for `0x1003`), and `x` and `y` of `0x3C01` (the player's server position at the click: the original's mover lags by its tick phase; `test/map_change_test.exs` checks the values)); a test adds its own with `masks:`. A path is a field name or a list of names through nested structs and arrays (`[:items, :id]` is the `id` of every element).

**Positions of a mover.** The server computes the position of a mover at the millisecond it handles a request; the capture gives that instant only within the delay of the relay line (10 to 45 ms; one unit at run speed is 8 ms). The scenario 45 replay therefore masks `from_x` / `from_y` of `0x2018` / `0x201A` and `x` / `y` of `0x2013`. A simulation of `Zone.Mover` over the capture found, for each of the 108 relayed requests before 471 s, a handling delay inside that bound that gives the captured position. The exact bytes at a set clock are in `test/movement_test.exs` and `test/zone/mover_test.exs`.

Paths resolve to byte ranges through `mod.__packet__().layout`, a list of `{name, offset, size, sub}` per field (offset in the payload; for an array the offset of its count and size `nil`). A `bits` field masks its whole byte.

## Deferrals

A Deferral is a part of a capture the rebuild does not reproduce yet; the replay leaves it out and names the milestone that builds it, so the gap is visible in the code. Every entry has a milestone (a positive integer) and a reason (a non-empty text); `Replay.Deferrals.validate!/2` raises `ArgumentError` otherwise, for a field that does not exist, and for an `:unsent` entry that names a line of the wrong direction. The milestone that builds the part removes its entries. Forms:

| Form | Effect |
|---|---|
| `{:payload, Reply, :token, 4, "reason"}` | the field is not compared (like a Mask); `:all` instead of the field accepts the whole payload of that opcode, any size, no handle binding; the opcode still has to arrive |
| `{:payload, [12, 14], Reply, :token, 4, "reason"}` | the same as `:payload` (a field or `:all`), but only for the server packets of these Transcript indices; an index that is not a packet of that module raises |
| `{:absent, Box, 4, "reason"}` | the server packets of that module are taken out of the Transcript: the rebuild does not send them yet |
| `{:absent, [146, 161], 4, "reason"}` | these server packets are taken out, by Transcript index: for an opcode the rebuild also sends where it is built (a late `0x1035`); an index that is not a server packet raises |
| `{:unsent, 12, [13, 14], 4, "reason"}` | the client packet with index 12 and the server packets 13 and 14 are left out, by Transcript index (GM commands share the chat opcode, so an opcode cannot name them); the replay continues with a later packet |
| `{:mobs, %{appear: ..., lists: ..., gone: ..., about: ..., npc?: fun}, 4, "reason"}` | the monsters of a map are left out per object (below) |
| `{:extra, Box, 3, "reason"}` | server packets of that module that arrive where the Transcript expects another opcode are dropped: the rebuild sends a placeholder the original leaves out (the empty `0x1047` boxes) |

The global list is `Replay.Deferrals.global/0` (empty until the issue that defines a packet adds its entry); a test adds its own with `deferrals:`. Packet indices stay as they are, so failures name the line of the Transcript file.

**Deferrals of `idle_in_world`** (`test/replay/milestone2_test.exs`; packets nobody defines yet get stand-in modules with `opcode/0` at the top of the file):

| Entry | Milestone | Reason |
|---|---|---|
| `{:payload, CharOptionImproveGetShortcutdataCmd, :all}` (`0x7032`) | 4 | shortcuts: the placeholder sends an empty list |
| `{:payload, …, :all}` `0x7033`, `0x7034` | 6 | options (key map, game options): the placeholders send empty lists |
| `{:payload, CharClientBaseCmd, :fame}`, `:stat_distribute` | 4 | no column yet |
| `{:payload, …, :all}` `0x10CE`, `0x441E` | 5 | quests |
| `{:payload, …, :all}` `0x103D`, `0x103E` | 4 | skills, passives |
| `{:payload, CharClientItemCmd, :all}` | 3 | items |
| `{:payload, CharClientChartitleCmd, :all}` | 6 | titles |
| `{:payload, CharClientChargedbuffCmd, :all}` | 9 | charged buffs |
| `{:payload, MapLoginAck, :param}` | 4 | parameters |
| `{:unsent, 44, [46]}` (`0x7C06`) | 2 | order race of the original: its `0x7C07` came between `0x7005` and `0x700D`; checked by `test/map_entry_test.exs`. No milestone removes it |
| `{:payload, …, :all}` `0x7005`, `0x700D` | 6 | options |
| `{:unsent, 52, [127, 128, 129, 130]}` (`0x581B`) | 10 | order race (the original's `0x581C` came after the WorldManager burst) and the Kingdom Quest list `0x581D`; `0x581C` is checked by `test/map_entry_test.exs` |
| `{:mobs, …}` `0x1C08`, `0x1C09`, `0x1C0E`, and the moves `0x2018`, `0x201A`, `0x2013` through `about:` | 4 | the monsters of the map and their moves (mobs); the NPC elements of `0x1C09` are compared |
| `{:absent, …}` `0x242A`, `0x2429`, `0x1C18` | 4 | abstates |
| `{:payload, CharStatRemainpointCmd, :remain}` | 4 | stat points |
| `{:payload, [indices], ActNoticeCmd, :all}` (every replay, `from_notices/1`) | 2 | the address of the capture's client in the "From" notice; the rebuild sends the address of the test client. No milestone removes it |
| `{:unsent, i, [answer]}` for each `&adminlevel` after `0x1803` (every replay, `admin_levels/1`) | 2 | order race of the original: it answers inside the `0x1803` burst, the rebuild after it (`test/gm_command_test.exs`). No milestone removes it |
| `{:absent, …}` `0x10BD` | 9 | auto-pick |
| `{:payload, CharChangeparamchangeCmd, [:params, :value]}` | 4 | parameters |
| `{:payload, KqJoiningAlarmList, :all}` | 10 | Kingdom Quest |
| `{:payload, CharClientNewbieGuideViewListCmd, :all}` | 11 | newbie guide |
| `{:absent, …}` `0x2428` | 4 | the reset of abstate 291 |
| `{:absent, …}` `0x3002` | 3 | the expiry of the pick-up mini-mon |
| `{:absent, [167, 168]}` (`0x240E`, `0x240F`) | 9 | HP and SP after that expiry; the built ones of the burst stay |
| `{:absent, [146, 161, 162, 166]}` (`0x1035`) | 4 | the late `0x1035`; the built one at 133 stays |
| `{:absent, …}` `0x581F`, `0x5824` | 10 | Kingdom Quest |
| `{:unsent, 191, []}` (`0x0C18 {0}` on the Zone connection) | 2 | the rebuild closes the Zone connection when the session ends one line earlier; the client's copy would race that close. No milestone removes it |

**Deferrals of `38_session-loss-kicks-char-select`**: the shared ones above without the idle-only entries (the order races at 44 and 52, the mini-mon, 191), plus the two order races of every world entry (`0x7C06` with its `0x7C07`, `0x581B` with its `0x581C` and three `0x581D`), `{:unsent, …}` for the `0x302C` and `0x3020` the client sent before the end of the `0x1803` burst (the original answered inside it; milestone 2, no milestone removes it), `{:absent, …}` `0x1C0E`, `0x1C08` (mobs, milestone 4), `{:absent, [indices]}` for each `0x1035` after the `0x3021` of its connection (milestone 4) and `{:payload, [429, 574], UserLoginworldAck, [:avatars, :kq_date]}`, `[:avatars, :kq_date_sec]` (milestone 2; the list at 146 is compared): the original saves about 10 s after a session ends (the logout linger the rebuild leaves out, issue 94), and the lists at 429 and 574 show that time. No milestone removes it.

**Deferrals of `walk-run-portals`**: the shared ones of `idle_in_world` without the idle-only entries, plus the order races at 44 (`0x7C06` with its `0x7C07` at 47) and 49 (`0x581B` with `0x581C` and three `0x581D`), the later `0x581B` at 254, 370, 480, 610 and 882 (`{:unsent, i, []}`, milestone 10: with the first one left out the rebuild would answer the second with `0x581C`; only the first of a session is answered), the `0x302C` and `0x3020` at 58 and 59 sent before the end of the `0x1803` burst (answers 124 and 131), the late `0x1035` of each connection (139, 172, 173, 331, 444, 451, 452, 557, 698, 787, 788, 966, 1016, 1017; milestone 4, the built one of each map entry stays), the target select `0x2401` at 222, 336, 445, 567 and 846 with its `0x2402` (combat, milestone 4), the cease fire `0x243D` at 851 (combat, milestone 4), the clicks `0x200A` on the town portal NPC at 224, 338, 446 and 569 with `0x243D` and the menu `0x201C` (NPC menus, milestone 3; only the Gate role is built), `{:payload, [368, 608], MapLoginAck, :x}` (the original moved the arriving player off the town portal NPC's cell, x + 25; the placement search comes with mob spawns, milestone 4), the NPC appears at 706 and 733 at the sight border right after that arrival (the original's positions are 25 units off, so they cross the border in other slices; milestone 4) and the `0x1C0E` at 761 of an object never shown on the connection (mobs, milestone 4).

**Deferrals of `14_second-client-in-sight`**: the shared ones of `idle_in_world` without the module-wide `:absent` of `0x242A` and `0x2428` (they would hide `&hide` and `&show`; the abstates of the login protection are deferred by index), the order races of both entries, the late and regular `0x1035`, B's item cells and booth size, the starting weapon B's new character shows in the original (items), the title of `Test1235` in its `0x1C06` (titles), two NPCs at B's sight border in the other order (`:payload, :all` at 354 and 356: tick phase, no milestone removes it), the positions of a running player at a tick or a `0x1C01` (no milestone removes them), the combat of step 5 (`:unsent` client packets 653 to 1023, stand-in modules for `0x2402`, `0x2435`, `0x243D`, `0x2447` to `0x2457`, `0x240B`, `0x1C0A`, the HP / SP changes of the fight by index), the HP change counter after the fight, and computed by `computed_deferrals/1`: the P02-B27 storm between `&dimension 1` and `&dimension 0` (the other player's `0x1C06` / `0x1C0E` and the move resent behind an appear, to A also NPC appears and deletes, and the `0x1C01` answered inside it; reason names P02-B27 and 431 s to 492 s), the `0x1C01` for a monster (its answer goes to `:mobs`) and the moves and deletes of monsters by index (to a GM in dimension -1 the original relays monster moves before their next appear). X14B's character number comes from the database sequence: a per-test `handles:` entry binds `chrregnum` of `0x1038`, `0x103A`, `0x103B`, `0x10D7` in the namespace `:character`. The test asserts that none of the GM command lines and their answers is deferred.

**Monsters.** `appear` (`{module, handle_path, mob_id_path}`, `0x1C08`) names the packets that show an object: its mob id (little-endian) goes to `npc?.(map_name, mob_id)`; an NPC stays, anything else is taken out and its handle is excluded. `lists` (`{module, array, handle_field, mob_id_field, max}`, `0x1C09`) does the same per element: the NPC elements stay and the count is rewritten; a list left with no element is taken out. Then a run of consecutive kept list packets of one connection (same opcode) has its elements concatenated and split again into lists of at most `max`: chunk *i* takes the place (index, time, scope) of packet *i* of the run, run packets left without a chunk are taken out. The reason: the original fills a list with NPCs and monsters, the rebuild only with NPCs, so the list borders differ until milestone 4 (in `idle_in_world` the captured lists of 28 and 7, 6 of them monsters, become 28 and 1). `gone` (`0x1C0E`) of an excluded handle is taken out and ends the exclusion. `about` (`{module, handle_path}`) names the packets of either direction that carry a handle: one with an excluded handle is taken out. The excluded handles are kept per connection (each client gets its own appear and `gone`) and are cleared when the map of the connection changes.

## Replay cuts

`stop: {:cut, seconds, reason}` plays only the lines before `seconds` after the `start` of the Transcript (the relative time of `docs/protocol/capture-validation.md`); lines at or after it are not played. The reason is a non-empty text of one line, else `ArgumentError`. A Replay cut ends a replay where the capture continues with something the rebuild cannot do yet (a map reset, a long idle); what lies behind a cut gets a hand-written test.

## Handle map

A handle is `{packet_module, path, namespace, reason}`: a value the server picks anew in each run (identifiers, item keys). In a server packet, the first time a captured value is seen it is bound to the received value; later the received value must equal the bound one, and one received value cannot belong to two captured values. A violation is a `:handle` failure. In a client packet the captured value is replaced by the bound one; a captured value that was never bound is a `:handle` failure. `Replay.Masks.handles/0` is the global list: the login token (`:login_token`, `0x0C34` and `0x0C37`), the world key (`:world_key`: `validate` of `0x0C0C` and of the client's `0x0C0F`, so the client logs in to WorldManager with the key of this run; on a refusal the rebuild's zero key is bound to the uninitialised bytes of the capture, P02-B23) the `worldmanager` session handle of `0x0C14`, the `wm_handle` of `0x180A` and the `wm_handle` the client sends back in `0x1801` (`:wm_session`), the object handle of `0x1802`, of the briefs `0x1C02` to `0x1C05` and of the sight packets `0x1C01` (both handles), `0x1C06` to `0x1C09` (through the arrays), `0x1C0E`, `0x1805`, the moves `0x2018`, `0x201A` and `0x2013`, the NPC handle of `0x200A` and of `0x3C01`, and the actions `0x2021`, `0x2023`, `0x2025` and `0x2009` (`:object`) and the `chrregnum` of the AVATAR in `0x1406` (`:character`, the id comes from the database sequence). `TestClock.local_time/1` is UTC+1, the zone of all captures. `TestClock` also keeps timers: `Clock.send_after/3` stores one, and `TestClock.set/1` fires those that fall due, in due order, each one handled by its receiver before the next (a receiver that schedules a new timer while handling one is seen by the same loop).

The namespace `:object` is bound per map: the map of a connection is the captured value of a map name field (`Replay.Masks.map_names/0`, which holds the `map` of `0x1038`, plus `map_names:`; a trailing NUL is trimmed; `nil` before the first one), and every other namespace is global. Connections on the same map share one scope (two clients in sight of each other see the same objects), connections on different maps do not. `0xFFFF` in a 2-byte `:object` field means "no object": it is not bound on either side, a captured `ffff` must be received as `ffff` (else a `:handle` failure), and a client `ffff` is sent as it is.

## Setup functions

`Replay.Setups` has one function per capture. It builds the state the capture starts from, with public `Persistence` operations where one exists, a test-only factory otherwise, never a database dump. Each one empties the accounts table and creates the account `admin` (the client sends the MD5 text of the password, as in every transcript). `login_logout/0` and `create_char/0` also create the character "Test1235" of their capture, `login_heartbeat_refusals_delete/0` the characters "Test1235" and "Test2" (through `Factory`, the test-only inserts of characters and equipped items in `test/support/factory.ex`), `idle_in_world/0` "Test1235" with the stored values of the captured `0x1038`, `walk_run_portals/0` "Test1235" with the stored values of its `0x0C14` and `0x1038` and the one equipped item 1250, `session_loss_kicks_char_select/0` the three characters of the first `0x0C14` of scenario 38 ("Test1235" with the stored values of its first `0x1038`), `walk_sit_emote/0` the four characters of `admin` and the two of `testaccountB` that the `0x0C14` lists of scenario 45 show ("X45A" and "X45B" with the stored values of their `0x1038`); later issues add more. `TestSessions.wait_none/0` runs before the accounts table is emptied: a Zone connection of the previous test saves while it ends, and the factories reuse character ids, so a late save would overwrite the next test's character.

## Topology

`PINATA_TEST_TOPOLOGY` selects where the replay connects; `Replay.Topology.start/0` reads it once from `test_helper.exs` (after the support files are compiled, before `ExUnit.start/0`) and keeps the result in `persistent_term`. `single` (default) uses the application `test_helper.exs` starts, on the ports of `TestPorts.app()`. `multi` starts `TestPeers.start()`: Login, WorldManager and Zone each on a `:peer` node, client ports from `TestPorts` (see Ports); the peers stop at exit. Another value raises. The test VM still runs its own application in `multi`, but nothing connects to it.

`Replay.Topology.call(part, module, function, args)` (`part` is `:login`, `:wm` or `:zone`) runs a call in this VM for `single` and on the peer for `multi`; a test that reaches into the server (the "world closed" and "world full" tests of `milestone1_test.exs`) goes through it. `Replay.Topology.all/3` calls in this VM and on every peer; the harness sets the clock source and the `TestClock` time that way, because each node has its own clock. The world-select port of the capture (9110) cannot match a port from the operating system, so `Replay` masks `port` of `UserWorldselectAck` for any WorldManager endpoint other than 9110.

The topology runs on any database (the peers use the `DATABASE_URL` of the test VM; SQLite is a file shared by all VMs; `Settings` refuses SQLite in multi-node mode, so `test_helper.exs` and `TestPeers` set `config :pinata, :sqlite_in_multi_node, true`, which nothing else may set). CI runs the whole suite once single-node on SQLite (job `check`) and once `multi` on PostgreSQL (job `test-postgres`). The variable is for tests only, so it is not in the user documentation.

## Adding a replay test

1. Convert the Capture to a Transcript (above) and review it.
2. Add or extend its function in `Replay.Setups`.
3. Write the test: call the setup function, `Replay.Transcript.read!/1` the file, `Replay.assert_replay/2` with `stop:` and `endpoints: Replay.Topology.endpoints()`. See `server/test/replay/milestone1_test.exs`.
4. Mask every field the server cannot reproduce, each with a reason (global list for a field of the packet itself, `masks:` for one test).
5. Defer what a later milestone builds with a Deferral (`deferrals:`, milestone and reason), and end the replay with a Replay cut where the capture continues with something the rebuild cannot do yet.

## Peer nodes

`TestPeers.start()` (`test/support/test_peers.ex`) starts three `:peer` nodes: `PINATA_PARTS=login`, `world_manager` and `zone`, each on a client port from `TestPorts.free/1`, chosen after the three peer VMs have booted and before `:pinata` starts on them (Login, WorldManager, Zone in that order). They share one settings file (`pinata-peers-<os pid>-<unique integer>.toml`), the database of the test VM, and the cookie; Login and Zone are connected to the WorldManager node, not to the test VM, so the control connection is standard I/O. The result holds the peer pids (`login`, `wm`, `zone`), the ports (`login_port`, `wm_port`, `zone_port`) and `nodes` (the node names). `TestClock` is loaded on all peers so a test can move their clocks. `test/world_manager/hand_off_test.exs` runs every test in both topologies: `:single` (the application of the test VM, `TestPorts.app()`) and `:peers` (its own `TestPeers`). `start/0` returns only when the Zone peer has joined the WorldManager peer (the map table answers for `"Rou"`). The peers have no `cluster.nodes`, so they are multi-node nodes and run `Cluster.DataDigest`.

One multi-mode run on SQLite once failed with "Ecto repo Persistence.Repo.SQLite not started" in every test after one point; it could not be reproduced (20 repeated runs). That error means the application of the test VM was stopped. `test/start_test.exs` and `test/persistence/migrations_test.exs` stop it and start it again in `on_exit`; if that start fails, the rest of the run fails. When it happens again, the first failure of the run settles the cause: it shows the reason `Application.start/1` returned.

## Digest test

`test/cluster/data_digest_test.exs` starts peers, then a real node (Zone port from `TestPorts.free(1)`) (`elixir --name ... -e`, the code paths of the test VM, `PINATA_PARTS=zone`, `cluster.nodes` naming the WorldManager peer) with a data directory that differs. It asserts exit status 1, the message and both digests in the output, and that the WorldManager peer is still alive. The log level of the WorldManager peer is set to `:none`, so its expected refusal error does not show in the test output. The node halts itself with status 3 after 30 seconds if it is never refused. The differing directory holds only the tables of `Zone.game_data/0`, copied from the test data directory, and one extra file.

## Asserting server log lines

The test VM logs at `:warning` (the test settings file sets `log.level`), so tests stay quiet. A test that asserts on an `info` or `debug` line captures with `TestLog.capture/1` (`test/support/test_log.ex`): it raises the level to `:debug` for the captured function and restores `:warning` afterwards, and the module is `async: false`. Assert level, part and reason on the captured line in one match, for example `log =~ "[warning] Net: connection closed: packet rate exceeded, peer 127.0.0.1:"`; the line of a server-side close is written before the socket is closed, so it is in the capture once the client has seen the close. A line that goes with an answer on a connection that stays open is a `{:log, ...}` effect before the `{:send, ...}` effect, so it is in the capture once the client has read the answer (`WorldManager.Handler`, the `0x145` refusals of `0x1001`). Lines of the peer nodes cannot be captured in the test VM; assert them on a listener started in the test VM.

## Smoke test

`test/support/smoke.exs` is a script, not an ExUnit test (`test_helper.exs` loads only `support/**/*.ex`). Its one argument is the Login port. It plays login, world select and the character list against `127.0.0.1` with `TestClient`, as the account `smoke` with the password `smoke-password`: Login on the given port, WorldManager on the port of the world-select answer. It retries up to 15 times 2 seconds apart (the nodes need a moment to start and connect) and exits with status 1 when the last try fails. Two CI jobs run it with the Login port 9010:

- `compose-smoke` (Linux) against the Docker Compose example. `compose.yaml` names the published image `ghcr.io/wbpascal/pinata:<version>`, so the job first builds the current commit under exactly that name (taken from `compose.yaml`), and Compose pulls nothing. Locally, in `server/` with a data directory in `data` (the tag is the one in `compose.yaml`):

  ```
  docker build -t ghcr.io/wbpascal/pinata:0.1.0 .
  docker compose up -d
  printf 'smoke-password\n' | docker compose exec -T login /app/bin/pinata eval 'Persistence.Release.create_account("smoke")'
  MIX_ENV=test mix run --no-start test/support/smoke.exs 9010
  docker compose down -v
  ```

- `windows-smoke` against a release built on Windows in single-node mode with SQLite (see "Windows").

The job `otel-smoke` (Linux) runs the release with OpenTelemetry ([`telemetry.md`](telemetry.md)). With export off and `OTEL_TRACES_EXPORTER=otlp` set it checks with the script `test/support/otel_apps.exs` that the three OpenTelemetry applications run, that `Pinata.Figures.print()` answers and that the node output has no line containing `OTLP`, `opentelemetry` or `CA(s)`. Then it starts an OpenTelemetry Collector container (`otel/opentelemetry-collector`, configuration `test/support/otel-collector.yaml`, debug exporter), starts the release with `telemetry.otlp_enabled = true` and `trace_ratio = 1.0`, runs the smoke script, enters one map with the script `test/support/otel_enter.exs` so that it ticks, flushes both providers and waits until the Collector log holds the span `pinata.packet` and the metrics `pinata.packet.duration` and `pinata.tick.duration`. The job runs both scripts with `bin/pinata rpc "Code.eval_file(…)"`, and `test/workflow_test.exs` loads both, so a change to `Zone.Player` or `Zone.MapInstance.enter/2` fails `mix check`; the same test compares the job names of `server.yml` with the table "CI jobs" in `server/AGENTS.md`. Locally, in `server/` after `MIX_ENV=prod mix release`, with the data directory in `data`, run the commands of the job's steps with `R=_build/prod/rel/pinata` and a temporary directory for `$RUNNER_TEMP`; afterwards remove `data`, `otel.toml` and the container (`docker rm -f otelcol`).

The job `load-smoke` (Linux) starts the release in single-node mode and runs `mix pinata.load` with 50 players for 10 s; it fails when a player does not reach the world, disconnects or crashes, or the node writes an `error` line. `test/load_test.exs` runs the same code (`Load.run/1`) against the test application. See [`load-run.md`](load-run.md), "CI smoke run".

`test/compose_doc_test.exs` checks that `docs/user/multi-node.md` contains `compose.yaml` and `compose.toml` verbatim.

## Changelog step

The `changelog` job of `.github/workflows/server.yml` runs on pull requests only. It passes when the PR adds at least one line to `CHANGELOG.md` (the diff between the merge commit and its first parent, the base) or when the PR description has a line starting with `Changelog: none`; it checks nothing else (the rest is the changelog checklist of `server/AGENTS.md`). The description reaches `.github/scripts/changelog-check.sh` only through the environment variable `PR_BODY`. The workflow also runs on `edited`, so a description edited after a failed step runs it again; every job runs then, so that no skipped job stands in for an earlier failure of the same commit. The job first runs `.github/scripts/changelog-check-test.sh`, which tries the script in a throw-away repository: no line and no `Changelog: none` fails, `Changelog: none` in the middle of a line fails, the line (also with CRLF line ends, as GitHub stores a description) passes, an added changelog line passes, a description of about 60,000 characters whose first line is `Changelog: none` passes (20 times, as the failure it guards against, a SIGPIPE under `pipefail`, is a race), and shell syntax in the description is not run.

## Release workflow

`.github/workflows/release.yml` publishes a version (terms in `GLOSSARY.md`). It runs on a pushed tag `v*` and by hand (`workflow_dispatch`); a manual run does everything except publish. Its jobs:

- `consistency`: `elixir test/support/release_check.exs <out dir> [<tag>]` (needs only Elixir). The version is the one in `server/mix.exs`; the job fails when the image tag in `compose.yaml` (`ghcr.io/wbpascal/pinata:<tag>`) differs from it. On a tag run it also fails when the tag is not `v<version>`, when the root `CHANGELOG.md` has no `## <version> ...` section, or when that section's heading ends in `(unreleased)`. It writes the release text: the title is the section heading without `## ` and the unreleased mark, the body the section's text up to the next `## ` heading, verbatim. A manual run writes that text into the job summary. The logic is `ReleaseCheck` (`test/support/release_check.ex`); `test/release_check_test.exs` runs it under `mix check` with every failure case, the last section, and a heading with the same leading digits (`0.1.0` and `0.1.01`), and checks the repository's own files.
- `archive`, one leg per platform, each on its own pinned runner and built natively: Linux x86_64 (`ubuntu-24.04`), Linux arm64 (`ubuntu-24.04-arm`), macOS arm64 (`macos-15`), Windows x86_64 (`windows-2025`). It runs `mix deps.get` and `MIX_ENV=prod mix release`, copies the release to `pinata-<version>/` and packs it as `pinata-<version>-<os>-<cpu>.tar.gz` (`.zip` on Windows, with 7-Zip), and keeps it as a workflow artifact. Then it smoke-tests the packed archive, not `_build`: unpacks it into an empty directory, checks the single top-level directory (and on Linux and macOS that `bin/pinata` is executable), imports the 2016 `9Data` set (Git LFS) with the release's `eval` into a separate working directory, starts the node in single-node mode with SQLite (`bin/pinata start` in the background), waits for port 9010, creates the account `smoke` with `eval` and a piped password, runs `test/support/smoke.exs 9010` and stops the node with `bin/pinata stop`. On Windows the start, account and stop steps are those of `windows-smoke`.
- `image`, one leg per CPU on its native runner (`ubuntu-24.04` for amd64, `ubuntu-24.04-arm` for arm64): builds `server/Dockerfile` as `ghcr.io/wbpascal/pinata:<version>` with the label `org.opencontainers.image.source` (it links the package to the repository), smoke-tests it through the Compose example as `compose-smoke` does, and keeps it as an artifact (`docker save`).
- `publish`, tag runs only, the last job and the only one with `contents: write` and `packages: write`. Its `needs` are `consistency`, `archive` and `image`, so it does not run when any of the six smoke tests (four archives, two images) fails. It pushes both images and joins them under the tags `<version>` and `latest` (`docker buildx imagetools create`); `latest` moves only when the index for both CPUs exists. Then it creates the GitHub release for the tag, published directly: the title and body from the changelog section, and six assets, the four archives, `compose.yaml` and `compose.toml`. Before this job nothing is pushed to the registry and no GitHub release exists.

## Windows

Windows is supported in single-node mode with SQLite ([`install.md`](../user/install.md), section "Windows"). Two CI jobs in `.github/workflows/server.yml` run on a pinned Windows runner (`windows-2025`), with the same triggers as the Linux jobs:

- `check-windows`: sets `core.longpaths` before the checkout (some `Files/` paths are longer than Windows allows by default), pulls the `9Data` LFS files, and runs `mix deps.get`, `mix check` and `mix deps.audit` in `server/`, with its own Dialyzer PLT cache. It runs on SQLite in single-node topology only; PostgreSQL and the multi-node topology stay with `test-postgres` on Linux.
- `windows-smoke`: builds the release (`MIX_ENV=prod mix release`), imports the 2016 `9Data` set given as a backslash path with `bin\pinata eval`, starts the node with `bin\pinata start` in the background, creates the account `smoke` with `bin\pinata eval`, runs `test/support/smoke.exs 9010` and stops the node with `bin\pinata stop`.

The checkout is LF on every platform: `.gitattributes` sets `* text=auto eol=lf`, and `Files/** -text` keeps the original data byte-identical. The transcript reader and the generated-file comparisons rely on LF.

Two tags exclude tests where they cannot work; `test_helper.exs` decides and prints the reason:

| Tag | Excluded when | Tests |
|---|---|---|
| `:symlink` | creating a probe symlink fails: Windows without the symlink privilege (Developer Mode off, shell not elevated) | `test/game_data/import_test.exs` "symlinks in the source are not followed", `test/game_data/game_data_test.exs` "does not enter symlinked directories" |
| `:unix_file_modes` | always on Windows: `File.chmod/2` does not take away the read right there | `test/game_data/import_test.exs` "an unreadable file in the source fails the import" |

GitHub's Windows runners run elevated, so the `:symlink` tests run in `check-windows`.

`test/game_data/import_test.exs` "a source path with backslashes or pattern characters imports the same files" runs on every platform: on Windows it gives the source as a backslash path, elsewhere the folder name holds a backslash; both, and `[` or `{`, used to be read as wildcard syntax.

## Limits

- Connections are closed at the end of the replay, or after the packets listed in `close_after:`.
- The endpoint comes from the connection kind, not from the address the server sends.
- A `bits` field masks its whole byte.
- Two world-select refusals with status 0 in one replay fail the handle map: both captured keys are uninitialised memory and both would bind to the rebuild's zero key. No transcript has two.
- The handle map has no sentinel values and random game values are not handled.
