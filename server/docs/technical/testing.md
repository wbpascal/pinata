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

`server/test/support/` holds test-only code: `TestClock`, `TestClient`, `TestPorts`, `Replay` and the `Replay.*` modules. `server/test/test_helper.exs` loads it. It is not part of the application, so the `boundary` compiler and Dialyzer do not see it.

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
| `before:` | a map of packet index to a zero-arity function, run before the harness sends that client packet; no replay uses it at present |
| `timeout:` | milliseconds to wait for a server packet, default 2000 |

**Pacing.** Client packets are sent in capture order. Each one is sent after all earlier server packets of the Transcript arrived. Order is compared per connection only. A connection is opened right before its first line. All connections are closed when the replay ends.

**Clock.** The harness puts `TestClock` in as the clock source and sets it to the capture timestamp before each connection open and each client packet. The clock source is global, so replay tests are not async.

**Stop point.** Packets with an index above `stop:` are not played. Each Replay test plays everything of its capture that milestone 1 covers:

| Capture | Played | Not played yet |
|---|---|---|
| `login-logout` | `:end` | – |
| `login-errors` | `:end`, with the second login that cuts the first (`0x0C17`) | – |
| `create-char` | `:end`, creation and delete included | – |
| `37_login-heartbeat-refusals-delete` | 1 to 70: both creations (indices 31/32 and 39/40), the delete between them and the way back to the world list. Then one connection per test: `login#3` (71 to 90) with the world closed, `login#4` (91 to 108) with the world full, `login#5` (109 to 115) with account B blocked, `login#6` (116 to 122) with account B not login-able | – |
| `37b_char-select-rename-refusals` | 1 to 26: the character list, the refused create (`0x1404 {0x181}`) and five heartbeats | from 27 on: rename (`0x140F`), character login and the Zone connections, milestone 2 |

`milestone1_test.exs` can replay one connection of a capture (it keeps only the packets of that `conn`, the indices stay). The world is closed by stopping its WorldManager process and full with 2375 players in the `:pg` group; the flags of account B are set through `before:`. The `37b` test adds three masks of its own: the rename-right fields of `0x0C14` (`need_change_id`, `change_id_init`, `change_id_row_no`), because the rename right of `Test2` belongs to milestone 2.

`0x140F` and `0xB409` of `37b` are not replayed (the fixed P02-B42 and the deferred rename right change the answers). `test/world_manager/character_rename_test.exs` covers them with the request bytes of the transcript.

**Timer-driven opcodes.** `0x0804` (heartbeat) and `0x080E` (game time) come from timers. `S` lines with these opcodes are not expected, and received packets with these opcodes are dropped. Client lines are always sent, so the `0x080E` answer to the client's `0x080D` is not compared by a replay; `test/world_manager/character_list_test.exs` checks its bytes.

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

A Mask is `{packet_module, path, reason}`. The field is zeroed in both payloads before the comparison. The reason is required: an empty reason or an unknown field raises `ArgumentError`. `Replay.Masks.global/0` is the one list of masks every replay uses (the seed, the payload byte of `0x0C66` L00-B1, the `ip` of `0x0C0C`, and `delinfo` (P02-B1) and `kq_date_unused` (P02-B7) of the AVATAR in `0x0C14`, `kq_date_unused` of the AVATAR in `0x1406`); a test adds its own with `masks:`. A path is a field name or a list of names through nested structs and arrays (`[:items, :id]` is the `id` of every element).

Paths resolve to byte ranges through `mod.__packet__().layout`, a list of `{name, offset, size, sub}` per field (offset in the payload; for an array the offset of its count and size `nil`). A `bits` field masks its whole byte.

## Handle map

A handle is `{packet_module, path, namespace, reason}`: a value the server picks anew in each run (identifiers, item keys). In a server packet, the first time a captured value is seen it is bound to the received value; later the received value must equal the bound one, and one received value cannot belong to two captured values. A violation is a `:handle` failure. In a client packet the captured value is replaced by the bound one; a captured value that was never bound is a `:handle` failure. `Replay.Masks.handles/0` is the global list: the login token (`:login_token`, `0x0C34` and `0x0C37`), the world key (`:world_key`: `validate` of `0x0C0C` and of the client's `0x0C0F`, so the client logs in to WorldManager with the key of this run; on a refusal the rebuild's zero key is bound to the uninitialised bytes of the capture, P02-B23) the `worldmanager` session handle of `0x0C14` (`:wm_session`) and the `chrregnum` of the AVATAR in `0x1406` (`:character`, the id comes from the database sequence). `TestClock.local_time/1` is UTC+1, the zone of all captures.

## Setup functions

`Replay.Setups` has one function per capture. It builds the state the capture starts from, with public `Persistence` operations where one exists, a test-only factory otherwise, never a database dump. Each one empties the accounts table and creates the account `admin` (the client sends the MD5 text of the password, as in every transcript). `login_logout/0` and `create_char/0` also create the character "Test1235" of their capture, `login_heartbeat_refusals_delete/0` the characters "Test1235" and "Test2" (through `Factory`, the test-only inserts of characters and equipped items in `test/support/factory.ex`); later issues add more.

## Topology

`PINATA_TEST_TOPOLOGY` selects where the replay connects; `Replay.Topology.start/0` reads it once from `test_helper.exs` (after the support files are compiled, before `ExUnit.start/0`) and keeps the result in `persistent_term`. `single` (default) uses the application `test_helper.exs` starts, on the ports of `TestPorts.app()`. `multi` starts `TestPeers.start()`: Login, WorldManager and Zone each on a `:peer` node, client ports from `TestPorts` (see Ports); the peers stop at exit. Another value raises. The test VM still runs its own application in `multi`, but nothing connects to it.

`Replay.Topology.call(part, module, function, args)` (`part` is `:login`, `:wm` or `:zone`) runs a call in this VM for `single` and on the peer for `multi`; a test that reaches into the server (the "world closed" and "world full" tests of `milestone1_test.exs`) goes through it. `Replay.Topology.all/3` calls in this VM and on every peer; the harness sets the clock source and the `TestClock` time that way, because each node has its own clock. The world-select port of the capture (9110) cannot match a port from the operating system, so `Replay` masks `port` of `UserWorldselectAck` for any WorldManager endpoint other than 9110.

The topology runs on any database (the peers use the `DATABASE_URL` of the test VM; SQLite is a file shared by all VMs; `Settings` refuses SQLite in multi-node mode, so `test_helper.exs` and `TestPeers` set `config :pinata, :sqlite_in_multi_node, true`, which nothing else may set). CI runs the whole suite once single-node on SQLite (job `check`) and once `multi` on PostgreSQL (job `test-postgres`). The variable is for tests only, so it is not in the user documentation.

## Adding a replay test

1. Convert the Capture to a Transcript (above) and review it.
2. Add or extend its function in `Replay.Setups`.
3. Write the test: call the setup function, `Replay.Transcript.read!/1` the file, `Replay.assert_replay/2` with `stop:` and `endpoints: Replay.Topology.endpoints()`. See `server/test/replay/milestone1_test.exs`.
4. Mask every field the server cannot reproduce, each with a reason (global list for a field of the packet itself, `masks:` for one test).

## Peer nodes

`TestPeers.start()` (`test/support/test_peers.ex`) starts three `:peer` nodes: `PINATA_PARTS=login`, `world_manager` and `zone`, each on a client port from `TestPorts.free/1`, chosen after the three peer VMs have booted and before `:pinata` starts on them (Login, WorldManager, Zone in that order). They share one settings file (`pinata-peers-<os pid>-<unique integer>.toml`), the database of the test VM, and the cookie; Login and Zone are connected to the WorldManager node, not to the test VM, so the control connection is standard I/O. The result holds the peer pids (`login`, `wm`, `zone`), the ports (`login_port`, `wm_port`, `zone_port`) and `nodes` (the node names). `TestClock` is loaded on all peers so a test can move their clocks. `test/world_manager/hand_off_test.exs` runs every test in both topologies: `:single` (the application of the test VM, `TestPorts.app()`) and `:peers` (its own `TestPeers`). The peers have no `cluster.nodes`, so they are multi-node nodes and run `Cluster.DataDigest`.

One multi-mode run on SQLite once failed with "Ecto repo Persistence.Repo.SQLite not started" in every test after one point; it could not be reproduced (20 repeated runs). That error means the application of the test VM was stopped. `test/start_test.exs` and `test/persistence/migrations_test.exs` stop it and start it again in `on_exit`; if that start fails, the rest of the run fails. When it happens again, the first failure of the run settles the cause: it shows the reason `Application.start/1` returned.

## Digest test

`test/cluster/data_digest_test.exs` starts peers, then a real node (Zone port from `TestPorts.free(1)`) (`elixir --name ... -e`, the code paths of the test VM, `PINATA_PARTS=zone`, `cluster.nodes` naming the WorldManager peer) with a data directory that differs. It asserts exit status 1, the message and both digests in the output, and that the WorldManager peer is still alive. The log level of the WorldManager peer is set to `:none`, so its expected refusal error does not show in the test output. The node halts itself with status 3 after 30 seconds if it is never refused. While `Zone.game_data/0` is `[]` any different directory works; when Zone declares tables, copy the test data directory and change one file.

## Asserting server log lines

The test VM logs at `:warning` (the test settings file sets `log.level`), so tests stay quiet. A test that asserts on an `info` or `debug` line captures with `TestLog.capture/1` (`test/support/test_log.ex`): it raises the level to `:debug` for the captured function and restores `:warning` afterwards, and the module is `async: false`. Assert level, part and reason on the captured line in one match, for example `log =~ "[warning] Net: connection closed: packet rate exceeded, peer 127.0.0.1:"`; the line of a server-side close is written before the socket is closed, so it is in the capture once the client has seen the close. Lines of the peer nodes cannot be captured in the test VM; assert them on a listener started in the test VM.

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
