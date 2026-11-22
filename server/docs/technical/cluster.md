# Cluster

How the parts find each other and call each other (ADR 0002: fail simple).

## Names and groups

| Name | What |
|---|---|
| `{:global, {:login}}` | `Login.Tokens`, the login token process |
| `{:global, {:world_manager, world_id}}` | `WorldManager.World` of a world; its presence means the world is open |
| `:pg` group `{:zones, world_id}` | the `Zone.Maps` process of each Zone node of a world |
| `:pg` group `{:players, world_id}` | WorldManager connections that logged in (`Cluster.Registry.join_players/2`, `player_count/1`) |
| `:pg` group `{:session, user_no}` | the process that is the session of the account |
| `:pg` group `{:wm_handle, handle}` | the sessions with this session handle (`worldmanager` of `0x0C14`) |

The `:pg` scope `Cluster.Registry` is started by `Cluster.Root`. libcluster runs only when `cluster.nodes` is not empty, with `Cluster.Strategy.Epmd` and those hosts. `Cluster.Root` has that name because libcluster owns `Cluster.Supervisor`.

## Map table

WorldManager keeps which Zone node runs which map of its world (ADR 0002; `WorldManager.World`). A Zone node joins every world of `settings.world` with `Cluster.WorldManager.join_zone(world, zone_pid, {public_host, zone.port}, names)`: `names` are all plain field maps it can run (WorldManager does not load `FieldList`). The answer is the names it must run. The first joiner gets every map it offers; a later joiner only the maps no Zone node runs. A running map never moves.

When a Zone node is lost (monitor), each of its maps goes to the remaining Zone node that offered it with the highest `:erlang.phash2({map name, zone pid})` (rendezvous hashing), and each such node gets one `{:run_maps, world, names}` message; a map nobody else offered stays out of the table. `WorldManager.World.zone_of/2` returns `{:ok, %{node, host, port}}` of the Zone node that runs a map, or `:error`; character select and map change use it. The wait for a configured number of Zone nodes of ADR 0002 is fixed at 1: there is no setting. `public_host` of a Zone node must be an IPv4 address in text form (it goes to the client in a 16-byte field).

## Sessions

`Cluster.Sessions.take_over/1` makes the calling process the session of an account and sends every older member `{:cluster, :session_replaced}`; the connection handlers answer it with `0x0C17 {0x683}` and close. `Cluster.Sessions.leave/1` ends it: Login's connection calls it when it hands the client to WorldManager, so the later WorldManager login does not cut the Login link. A token login (`0x0C37`) calls `take_over/1` too.

`Cluster.Sessions.register_handle/1` puts the calling WorldManager session into the group `{:wm_handle, handle}` at world login. `Cluster.Sessions.redeem/2` is called by a Zone connection on `0x1801`: it calls every member with `{:cluster, {:redeem, name, node(), self()}}` (`handle_call/2` of the handler; an exit counts as no session). The first success returns `{:ok, session_pid, entry}`; otherwise the first refusal that is not `:no_session`, else `{:error, :no_session}`. A handle repeats after 65536 logins; the character name and the node decide. Flow: [`flows/enter-world.md`](flows/enter-world.md).

`Cluster.Sessions.map_login_done/1` is sent by the Zone connection to the session after `0x1803` (`{:cluster, :map_login_done}`, a message, no reply); the session answers it with the WorldManager burst ([`flows/map-entry.md`](flows/map-entry.md)).

## Facades

A part reaches another part only through a facade module of `Cluster` (never a direct call). `Cluster.WorldManager.join_zone/4` is a `GenServer.call` of `{:join_zone, zone, address, offered}`, described under "Map table". `Cluster.WorldManager.expect_login/2` is a `GenServer.call` of `{:expect_login, request}` to the `WorldManager.World` of the world; the process answers `:ok` and stores the reservation. It exits when the world is not registered. Flow: [`flows/world-select.md`](flows/world-select.md). `Cluster.Login.create_token/2` is a `GenServer.call` of `{:create_token, user_no, user_name}` to `Login.Tokens`; it returns `{:ok, token}` or `{:error, :pending}` and exits when Login is not registered. Flow: [`flows/return-to-world-list.md`](flows/return-to-world-list.md).

## Node log

`Cluster.NodeLog` (registered under its module name) runs on every node in multi-node mode and is not started in single-node mode; `Cluster.Root` starts it. It monitors node connections (`:net_kernel.monitor_nodes/1`) and logs `Cluster: node <node> connected` (info) on `nodeup` and `Cluster: node <node> lost` (warning) on `nodedown`. The world lines are written by `Login.WorldWatch` (see `processes.md`).

## Data directory digest

`Cluster.DataDigest` (registered under its module name) runs on every node in multi-node mode and is not started in single-node mode (ADR 0006; `Pinata.Application` computes `GameData.digest/1` and passes it with `authority?: true` when the node runs the WorldManager part). It monitors node connections (`:net_kernel.monitor_nodes/1`) and sends the cast `{:digest, node, digest, authority?}` to the process of the same name on every node that is connected when it starts and on every `nodeup`. The receiver decides:

| Receiver | Sender | Equal digests | Different digests |
|---|---|---|---|
| any | any | nothing | |
| no WorldManager part | WorldManager node | | prints both digests to standard error ("Data directory digest mismatch, the node stops:") and calls `System.stop(1)` |
| WorldManager part | no WorldManager part | | logs an error naming the node and both digests, answers with its own digest, so the other node stops even when it missed the first announcement |
| same kind of node | | | nothing: two WorldManager nodes, or two Login or Zone nodes, do not check each other |

```mermaid
sequenceDiagram
    participant Z as Zone node (other data)
    participant W as WorldManager node
    Z->>W: connect
    Z-)W: {:digest, zone, digest_z, false}
    W-)Z: {:digest, wm, digest_w, true}
    Note over W: logs an error, answers
    Note over Z: prints both digests, System.stop(1)
```

Limits: the check is asynchronous, so a node runs unchecked until it sees a WorldManager node; the refused node is not disconnected on the network level (it stops itself); a node that never connects to a WorldManager node is never checked. The check is not a security measure.
