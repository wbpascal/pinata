# Cluster registry, node discovery and hash ring options on OTP 29 / Elixir 1.20

Research for issue #8. Checked on 2026-11-17 against primary sources (OTP 29.1.2 docs and source,
Elixir 1.20.5 docs and source, each library's repository, Hex package metadata). Every claim carries
its source; a claim without one is marked *(inferred)*. What could not be verified is listed in
[section 7](#7-not-verified).

## 1. Short answer

| Concern | Lightest option that fits | Why | Alternative if it stops fitting |
|---|---|---|---|
| Unique registry across nodes | `:global` (OTP Kernel) | No dependency, works unchanged on a non-distributed node, registration is atomic across nodes, so no duplicate winners to clean up | Syn 3.4.2 (no dependencies, eventually consistent, fast writes) |
| Groups ("all zone nodes") | `:pg` (OTP Kernel) | No dependency, membership follows node up/down | Syn process groups |
| Node discovery | Static node list from the server configuration, connected by a small process or by libcluster 3.6.0 `Cluster.Strategy.Epmd` | Topology is fixed and small; libcluster is tested on Elixir 1.20.5 / OTP 29.1.2 | libcluster Gossip / Kubernetes strategies, `dns_cluster` |
| Map to zone node hashing | Hand-rolled rendezvous hash on `:erlang.phash2/2` (about 3 lines) or libring 1.8.0 `HashRing` as a plain data structure | Computed once at start-up; `phash2` is guaranteed stable across machines and ERTS versions | ExHashRing 7.0.0 only if lookup rates need ETS and history |
| One release or several | Umbrella with one app per part and several entries under `releases:` | The only layout the Mix release docs describe for "subsets of applications" | Single app with several releases, parts switched on by runtime configuration |

Horde is not recommended here: its CRDT dependency (`delta_crdt`) has had no release since 2024-04 and
has open unbounded-growth and data-loss reports (section 2.4).

Versions at the time of writing: Erlang/OTP 29.1.2 is the latest OTP
([erlang.org/downloads](https://www.erlang.org/downloads)); Elixir 1.20.5 (2026-10-29) is the latest
Elixir ([releases](https://github.com/elixir-lang/elixir/releases)); Elixir 1.20 supports OTP 27 to 29
([compatibility table](https://elixir.hexdocs.pm/compatibility-and-deprecations.html)).

## 2. Cluster-aware unique process registry

### 2.1 Elixir `Registry` (baseline, not cluster-aware)

"A local, decentralized and scalable key-value process storage"
([registry.ex, v1.20.5](https://github.com/elixir-lang/elixir/blob/v1.20.5/lib/elixir/lib/registry.ex)).
It never sees other nodes. It stays the right tool for names that are only looked up inside one node
(players inside a zone) *(inferred)*.

### 2.2 `:global` (OTP Kernel)

Source: [global docs, OTP 29.1.2](https://www.erlang.org/doc/apps/kernel/global.html),
[Kernel configuration](https://www.erlang.org/doc/apps/kernel/kernel_app.html).

- **Model:** consistent. "Both the registration and lock services are atomic"; a name "is either
  registered on all nodes or none". `register_name` is "completely synchronous". Lookups are local:
  "the translation of a name to a pid is fast, as it is always done locally".
- **Node loss:** "If a node that runs a globally registered process goes down, the name is globally
  unregistered." A dead process is unregistered on all nodes.
- **Netsplit:** since OTP 25 `global` "will by default prevent overlapping partitions" by "actively
  disconnecting from nodes that reports that they have lost connections to other nodes"
  (`prevent_overlapping_partitions`, "enabled by default"). The result is fully connected islands. Each
  island unregisters the names owned by the other. The docs strongly advise against switching this off.
- **Heal:** when nodes connect, name clashes go to the resolve function. The default
  `random_exit_name/3` "randomly selects one of the pids for registration and kills the other one".
  A custom function can pick the winner; if it crashes or returns something else "the name is
  unregistered". So a singleton that was restarted on both sides during a split loses one copy at heal.
- **Requirements:** a fully connected network (`connect_all`, default `true`); the services are not
  "reliably delivered" without both `connect_all` and `prevent_overlapping_partitions`.
- **Cost:** every registration is a cluster-wide synchronous operation. Syn's README describes the
  consequence: `global` "chooses Consistency over Availability, therefore it can become difficult to
  scale when registration rates are elevated and the cluster becomes larger"
  ([Syn README](https://github.com/ostinelli/syn/blob/master/README.md)). The OTP docs give no numbers.
  Fit for coarse names (Login, WorldManager, one service per zone node, a few hundred maps), not for
  one name per player *(inferred)*.
- **One node:** part of Kernel, always started. Verified locally on Elixir 1.20.5 / OTP 29 with the node
  **not** distributed (`nonode@nohost`): `register_name`, `whereis_name` and `{:via, :global, name}`
  work, a duplicate `start_link` returns `{:error, {:already_started, pid}}`, and the node stays
  non-distributed (no epmd, no listening socket). No extra process, no dependency.
- **OTP 29:** no `global` entry in the Kernel 11.x release notes
  ([Kernel release notes](https://www.erlang.org/doc/apps/kernel/notes.html)); the only version note
  in the module is `disconnect/0` (OTP 25.1).

### 2.3 `:pg` (OTP Kernel): groups, not unique names

Source: [pg docs, OTP 29.1.2](https://www.erlang.org/doc/apps/kernel/pg.html).

- **Model:** "Process Groups implement strong eventual consistency"; the membership view "may
  temporarily diverge". No uniqueness: a group holds any number of processes, a process "can join a
  group many times". It cannot replace a unique registry; it answers "which zone nodes are up".
- **Node loss and netsplit:** a terminated member "is automatically removed". "Membership view is not
  transitive": nodes that are not directly connected do not see each other's groups. The docs do not
  spell out the heal step; members reappear when the scope processes see each other again *(inferred)*.
- **Change notifications:** `monitor_scope/1` and `monitor/2` (since OTP 25.1) deliver `join` / `leave`
  messages, which is enough to drive a ring that follows membership.
- **Scope crash:** "Local membership is not preserved if scope process exits and restarts."
- **One node:** the default scope is not started (`start_pg` "Defaults to `false`"; verified:
  `Process.whereis(:pg)` is `nil`). A scope is one process and one ETS table, started with
  `:pg.start_link(scope)` under the application's own supervisor; verified working on `nonode@nohost`.
- **OTP 29:** `pg:which_groups/1` returned groups without members in OTP 29.0, fixed in Kernel 11.0.4
  (OTP 29.1.2, OTP-20303). Pin 29.1.2 or later.

### 2.4 Horde 0.10.0

Source: [README](https://github.com/derekkraan/horde/blob/master/README.md),
[`Horde.Registry`](https://github.com/derekkraan/horde/blob/master/lib/horde/registry.ex),
[CHANGELOG](https://github.com/derekkraan/horde/blob/master/CHANGELOG.md),
[Hex](https://hex.pm/packages/horde).

- **Model:** `Horde.Registry` and `Horde.DynamicSupervisor` on a delta-CRDT; "eventually (as opposed
  to immediately) consistent". API close to Elixir's `Registry`, without `keys: :duplicate` and
  partitions. `members: :auto` follows the visible nodes.
- **Conflicts:** two simultaneous registrations of one name both return `{:ok, pid}`; later the loser
  gets an exit signal `{:name_conflict, {name, value}, registry_name, winning_pid}`. The same happens
  when registries are joined and "when a cluster is recovering from a netsplit".
- **Netsplit:** "both sides of the partition will continue to operate" (default
  `Horde.UniformDistribution`); `Horde.UniformQuorumDistribution` shuts down the side with less than
  half of the cluster. "You may end up with duplicate processes in your cluster."
- **Node loss:** `Horde.DynamicSupervisor` "will redistribute processes among the remaining nodes".
- **One node:** four direct runtime dependencies (`delta_crdt`, `libring`, `telemetry`, `telemetry_poller`;
  `delta_crdt` adds `merkle_map`) and a CRDT process per registry syncing every 300 ms by default
  ([mix.exs](https://github.com/derekkraan/horde/blob/master/mix.exs), `sync_interval` default in
  `registry.ex`). Heaviest option for single-node use.
- **Maintenance:** 0.10.0 released 2025-11-03, last commits 2026-10-05, still pre-1.0. CI runs Elixir
  1.18 to 1.20 on OTP 27 to 29, with `-kernel prevent_overlapping_partitions false` set for the test
  run ([ci.yml](https://github.com/derekkraan/horde/blob/master/.github/workflows/ci.yml)).
- **Risks:** `delta_crdt` 0.6.5 dates from 2024-04-16 and its last commit from 2024-05-28
  ([Hex](https://hex.pm/packages/delta_crdt), [repo](https://github.com/derekkraan/delta_crdt_ex));
  open there: unbounded causal-context growth (#73), data loss on truncated sync (PR #72), compile
  warnings on Elixir 1.19 (PR #70). Open in Horde: sync traffic growing without bound on long-lived
  clusters ([#300](https://github.com/derekkraan/horde/issues/300)) and `Registry.lookup/2` blocking
  while a remote node hangs ([#303](https://github.com/derekkraan/horde/issues/303)).

### 2.5 Syn 3.4.2

Source: [README](https://github.com/ostinelli/syn/blob/master/README.md),
[INTERNALS](https://github.com/ostinelli/syn/blob/master/INTERNALS.md),
[`syn_event_handler`](https://syn.hexdocs.pm/syn_event_handler.html),
[Hex](https://hex.pm/packages/syn).

- **Model:** registry plus process groups, "Availability has been chosen over Consistency and Syn
  implements strong eventual consistency". Each node is the authority for its own processes; all data
  of a scope is replicated to every node of the scope, so lookups are local ETS reads.
- **Node loss:** "The data related to the remote node that left the subcluster is removed locally on
  every node."
- **Netsplit heal:** by default Syn keeps the most recently registered process (by
  `erlang:system_time/0`, which the docs call "imprecise, as system clocks are not perfectly aligned")
  and kills the other with `{syn_resolve_kill, Name, Meta}`. A `resolve_registry_conflict/4` callback
  can choose instead; it runs on the two nodes that hold the conflicting processes and then nothing is
  killed automatically.
- **One node:** zero dependencies (`{deps, []}` in
  [rebar.config](https://github.com/ostinelli/syn/blob/master/rebar.config)); per scope two
  `gen_server` processes and four ETS tables. Whether it runs on a non-distributed node was not tested
  (section 7).
- **Maintenance:** active. 3.4.0 (2026-02), 3.4.1 (2026-03), 3.4.2 (2026-06-22), commits up to
  2026-10-18. CI covers OTP 27 and 28 only, not 29
  ([ci.yml](https://github.com/ostinelli/syn/blob/master/.github/workflows/ci.yml)).
- **Risk:** open [#96](https://github.com/ostinelli/syn/issues/96): after a *partial* split a live
  registration can stay missing on a third node (fix proposed in PR #97, not merged).

### 2.6 Others

- **Swarm:** last release 3.4.0 on 2019-01-16 ([Hex](https://hex.pm/packages/swarm)). Treat as
  unmaintained.
- **Highlander / HighlanderPG:** recommended by Horde's README for "a single process as a singleton in
  your cluster". Not examined further.

### 2.7 Comparison

| | `:global` | `:pg` | Horde 0.10.0 | Syn 3.4.2 |
|---|---|---|---|---|
| Unique names | yes, atomic | no (groups) | yes, eventual | yes, eventual |
| Duplicate winners possible | only across a split | n/a | yes, also without a split | yes, also without a split |
| After heal | resolve fun, default kills a random one | views merge | loser exits with `:name_conflict` | newest stays, other killed (or callback) |
| Node loss | names unregistered | members removed | entries removed, supervisor restarts children elsewhere | entries removed |
| Dependencies | none | none | 5 packages | none |
| One-node overhead | none | 1 process + 1 ETS per scope | CRDT processes, 300 ms sync timer | 2 processes + 4 ETS per scope |
| Tested on OTP 29 | ships with it | ships with it (use 29.1.2+) | yes (CI) | no (CI: 27, 28) |
| Last release | OTP 29.1.2 | OTP 29.1.2 | 2025-11-03 | 2026-06-22 |

## 3. Node discovery and connection

### 3.1 Plain OTP

Source: [Distributed Erlang](https://www.erlang.org/doc/system/distributed.html),
[Kernel configuration](https://www.erlang.org/doc/apps/kernel/kernel_app.html),
[`kernel_config.erl`](https://github.com/erlang/otp/blob/OTP-29.1.2/lib/kernel/src/kernel_config.erl).

- A node is a runtime "that has been given a name" (`-name` / `-sname`); without one `node()` is
  `nonode@nohost`. "Connections are by default transitive", so "there is always a fully connected
  network". Connecting to one known node is enough to join the mesh.
- `sys.config`: `sync_nodes_mandatory` ("must be alive for this node to start properly"),
  `sync_nodes_optional` ("can be alive"), `sync_nodes_timeout` (how long to wait; "If this parameter is
  undefined, no node synchronization is performed"). It is handled once while Kernel starts
  (`kernel_config.erl`); nothing reconnects a node that joins or returns later *(inferred from the
  code being a boot step)*. So it needs a companion that retries, or every node must list every other.
- Failure detection: `net_ticktime` defaults to 60 s ("approximate time a connected node may be
  unresponsive until it is considered down"). A hung zone node is noticed after about a minute unless
  this is lowered.
- Security: "Starting a distributed node without also specifying `-proto_dist inet_tls` will expose the
  node to attacks that may give the attacker complete access to the node and by extension the cluster."
  Distribution is clear text by default. Multi-node mode needs a private network or TLS distribution.
- OTP 29 changes in this area are small: an internal EPMD message rename (OTP-19734), a new
  `log_missed_net_ticks` flag (OTP-20117), a `net_kernel` state leak fix in 29.1.2 (OTP-20265)
  ([Kernel release notes](https://www.erlang.org/doc/apps/kernel/notes.html)).

### 3.2 libcluster 3.6.0

Source: [README](https://github.com/bitwalker/libcluster/blob/main/README.md),
[CHANGELOG](https://github.com/bitwalker/libcluster/blob/main/CHANGELOG.md),
[`Cluster.Strategy.Epmd`](https://github.com/bitwalker/libcluster/blob/main/lib/strategy/epmd.ex),
[Hex](https://hex.pm/packages/libcluster).

- "Automatic cluster formation/healing" through pluggable strategies: `Epmd` (configured host list),
  `LocalEpmd`, `ErlangHosts`, `Gossip` (multicast UDP), three Kubernetes strategies, `Rancher`.
- `Epmd` connects the configured `hosts` when its worker starts; with a `timeout` it repeats the
  connection attempt on that interval, the default `:infinity` means once. With an empty host list
  `start_link` returns `:ignore`, so no process runs.
- It only connects and disconnects nodes. Netsplit behaviour is that of whatever sits on top
  (`:global`, `:pg`, Syn). The README warns that the DNS strategies can "disconnect previously
  discovered peers" after a failed lookup.
- **One node:** runtime dependencies `jason` and `telemetry`
  ([mix.exs](https://github.com/bitwalker/libcluster/blob/main/mix.exs)); with no topologies or an
  empty `Epmd` host list nothing runs. It does not start distribution by itself: the node must be
  started with a name.
- **Maintenance:** revived. 3.5.0 (2025-01-09), then 3.5.1 (2026-11-01) and 3.6.0 (2026-11-03). 3.5.1
  "Restore[s] CI on Ubuntu 24.04 with Elixir 1.13/OTP 24.3 through Elixir 1.20/OTP 29"; the current
  matrix includes Elixir 1.20.5 / OTP 29.1.2.

### 3.3 dns_cluster 0.3.1

Phoenix team, released 2026-10-01; discovers nodes through one DNS name
([README](https://github.com/phoenixframework/dns_cluster/blob/main/README.md),
[Hex](https://hex.pm/packages/dns_cluster)). `query: :ignore` turns it off. Useful only when a DNS name
lists the nodes (containers); not for a fixed list of hosts.

### 3.4 Comparison

| | `sys.config` sync_nodes | Own connector process | libcluster `Epmd` | dns_cluster |
|---|---|---|---|---|
| Input | node list in `sys.config` | node list in server config | node list in app config | DNS name |
| Reconnect after loss | no *(inferred)* | as written | yes, with `timeout` set | yes, polls |
| Dependencies | none | none | libcluster, jason, telemetry | dns_cluster |
| One-node cost | none | none | none (worker `:ignore`) | none (`:ignore`) |
| OTP 29 | ships with it | ships with it | CI-tested | not checked |

With three to six nodes named in the server's own configuration, a connector is about 15 lines
(`Node.connect/1` on a timer, `:net_kernel.monitor_nodes/1` for logging). libcluster buys retry and a
later move to Gossip or Kubernetes without code changes *(inferred)*.

## 4. Consistent hashing of maps onto zone nodes

Requirement from the map: the assignment is computed at start-up. Then the ring is a pure function of
(map name, list of zone nodes) and every node must compute the same answer. That holds only if all
nodes hash the **configured** zone list, not the list of nodes that happen to be connected at that
moment *(inferred)*.

### 4.1 libring 1.8.0

Source: [README](https://github.com/bitwalker/libring/blob/main/README.md),
[CHANGELOG](https://github.com/bitwalker/libring/blob/main/CHANGELOG.md),
[Hex](https://hex.pm/packages/libring).

- "A consistent hash ring in Elixir, with no external runtime dependencies." Virtual nodes placed with
  `:erlang.phash2/2`, stored in `:gb_trees`; "Placement is deterministic". Default weight 128 per node.
- `HashRing` is a plain data structure (`new/0`, `add_nodes/2`, `key_to_node/2`, `key_to_nodes/3`):
  "best suited for when you have a single process which will need to access the ring". No process
  needed; it can sit in `:persistent_term` or a module attribute *(inferred)*.
- `HashRing.Managed` keeps the ring in ETS behind a GenServer and can follow cluster membership
  (`monitor_nodes: true`). The README warns that this "reflects Erlang connectivity, which does not
  guarantee that a peer's applications or services are ready to receive work".
- **Node loss:** only the keys of the lost node move (consistent hashing). With a managed, monitored
  ring this happens automatically, on each node separately; during a netsplit both sides own every key.
- **Maintenance:** revived. 1.7.0 (2024-09-17), 1.8.0 (2026-11-03) with fixes to `key_to_nodes/3` and
  managed rings. CI tests Elixir 1.20.5 / OTP 29.1.2. 1.8.0 changes replica selection for atom keys
  ("Existing atom-key replica selections can change"); primary-owner lookups for non-atom keys are
  unchanged.

### 4.2 ExHashRing 7.0.0 (Discord)

Source: [README](https://github.com/discord/ex_hash_ring/blob/master/README.md),
[Hex](https://hex.pm/packages/ex_hash_ring).

- Each ring is a GenServer with an ETS table ("Lookup optimized ring storage"), 512 replicas per node
  by default, key overrides (pin a key to a node) and ring history ("stable lookups over time").
- No runtime dependencies. Node names are strings (open PR #19 asks to accept other types).
- **Maintenance:** 7.0.0 on 2025-04-03 is the last release and the last commit. CI stops at Elixir 1.18
  / OTP 27. No evidence for or against OTP 29.
- Built for very high lookup rates on changing rings. A ring computed once at start-up uses none of
  that *(inferred)*.

### 4.3 Hand-rolled

- `:erlang.phash2/2`: "The hash value for the same Erlang term is guaranteed to be the same regardless
  of machine architecture and ERTS version"
  ([erlang.erl, OTP 29.1.2](https://github.com/erlang/otp/blob/OTP-29.1.2/erts/preloaded/src/erlang.erl)).
  All nodes agree without coordination, also across OTP upgrades.
- Rendezvous (highest random weight) hashing needs no ring structure:
  `Enum.max_by(zone_nodes, &:erlang.phash2({map, &1}))`. Verified locally on Elixir 1.20.5 / OTP 29:
  200 map names over 4 nodes spread 47 / 45 / 59 / 49, and removing one node moved exactly its 49 maps
  and no others. Cost is O(nodes) per lookup, irrelevant for a handful of zones and a table built once.
- No weights and no pinning unless written; both are a few lines (a pin table checked first covers
  "this map must run on that zone").

### 4.4 Comparison

| | libring `HashRing` | ExHashRing | Rendezvous on `phash2` |
|---|---|---|---|
| Code owned | none | none | about 3 lines + a test |
| Processes | none (data structure) | 1 GenServer + ETS per ring | none |
| Weights / pinning | weights | weights (replicas), overrides | to be written |
| Follows membership | optional (`Managed`) | manual | manual |
| Dependencies | libring | ex_hash_ring | none |
| Tested on OTP 29 | yes (CI) | no (CI ends at OTP 27) | verified locally |
| Last release | 2026-11-03 | 2025-04-03 | n/a |

## 5. One release or several from the same OTP applications

Source: [`mix release` docs, Elixir 1.20.5](https://mix.hexdocs.pm/Mix.Tasks.Release.html)
([source](https://github.com/elixir-lang/elixir/blob/v1.20.5/lib/mix/lib/mix/tasks/release.ex)).

- Any project can define several releases: "You can specify multiple releases where the key is the
  release name"; with more than one, `mix release` needs a name or `default_release:`. Stated purpose:
  "You can assemble different releases with different configuration per application or even with
  different applications altogether."
- Per release, `:applications` maps an application to a start mode: `:permanent` (default),
  `:transient`, `:temporary`, `:load` ("only loaded"), `:none` ("part of the release but it is neither
  loaded nor started"). A changed mode applies to the application's dependencies too, the highest
  priority parent wins.
- **Umbrella (the documented way to ship subsets):** "Releases are well integrated with umbrella
  projects, allowing you to release one or more subsets of your umbrella children." The umbrella must
  "explicitly list your release and the starting point for each release". The docs' own example is
  this ticket's case: three releases (`web_and_event_processing`, `web_only`,
  `event_processing_only`) from two entry-point apps sharing a core app. "You don't need to define all
  applications in `:applications`, only the entry points." Assembling from the root "allows you to
  include two applications that do not depend on each other as part of the same release".
- **Single app with several releases:** allowed, but every release contains the same application with
  the same supervision tree. Which parts start must then be decided at runtime, for example in
  `config/runtime.exs` ("executed whenever your Mix project or your release starts") from an
  environment variable. `RELEASE_NAME` is set before `env.sh` runs, so it can drive that. The docs
  describe the pieces, not this pattern *(inferred)*.
- **Distribution per release:** `RELEASE_DISTRIBUTION` is `name`, `sname` or `none` ("distribution is
  not started automatically"), default `sname`; `RELEASE_NODE` and `RELEASE_COOKIE` set name and
  cookie; all can be set in `rel/env.sh.eex`. A single-node offline release with
  `RELEASE_DISTRIBUTION=none` starts no distribution and no epmd; `bin/NAME remote` and `rpc` then do
  not work *(inferred: they connect over distribution)*. Without epmd but with distribution:
  `-start_epmd false -erl_epmd_port PORT` in `vm.args.eex` ("epmd-less deployment").
- **Footprint knobs:** `RELEASE_MODE=interactive` loads code on demand ("reduce memory usage on
  boot"); `:strip_beams` defaults to `true`; a release includes ERTS, so the target needs no Erlang
  but must match architecture, OS and ABI.

Mapping to the parts: an umbrella with `login`, `world_manager`, `zone` and the shared libraries gives
`releases: [all: [login, world_manager, zone], login: [...], world_manager: [...], zone: [...]]` with
no runtime switch, and the compiler enforces that parts do not call each other's modules unless a
dependency says so *(inferred)*.

## 6. Consequences for the design decision

All *(inferred)* from the facts above.

1. With `:global` plus `:pg` and a start-up ring the multi-node mode adds **no runtime dependency** and
   single-node mode runs the same code path on `nonode@nohost`.
2. Netsplit policy is the real decision, not the library. A fixed topology (each part runs only on its
   configured node, nothing fails over) cannot create duplicates: during a split the other side simply
   lacks the name, and at heal there is nothing to resolve. Automatic failover of WorldManager or of
   maps is what would make `random_exit_name` or CRDT conflict handling matter.
3. Keep per-player and per-object names in a node-local `Registry` and address them through the owning
   map or zone process. This keeps `:global` registration rates low and avoids needing Syn or Horde.
4. Set `net_ticktime` deliberately: the default 60 s is the time a hung zone node stays "up".
5. Pin OTP 29.1.2 or later (pg and net_kernel fixes).

## 7. Not verified

- **Third-party libraries were not compiled or run locally** on Elixir 1.20.5 / OTP 29 (installing
  them was not permitted in this session). OTP 29 status therefore rests on each project's CI matrix:
  confirmed for libcluster, libring and Horde; **absent for Syn (27, 28) and ExHashRing (up to 27)**.
  `delta_crdt` has no CI matrix that could be read.
- Whether Syn and `Horde.Registry` work on a non-distributed node, and their real memory cost with one
  node. The one-node rows for them come from documentation and source only.
- `sync_nodes_*` never reconnecting later, and `:pg` re-merging after a heal: neither is stated in the
  docs.
- No measured `:global` registration throughput; the OTP docs give none.
- dns_cluster and Highlander compatibility with OTP 29 were not checked.

Local checks that were run (standard library only, Elixir 1.20.5 / OTP 29, `nonode@nohost`): `:global`
register / lookup / via / duplicate rejection, `:pg` scope start and join, rendezvous hash spread and
minimal movement.
