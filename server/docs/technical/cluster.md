# Cluster

How the parts find each other and call each other (ADR 0002: fail simple).

## Names and groups

| Name | What |
|---|---|
| `{:global, {:login}}` | the Login process |
| `{:global, {:world_manager, world_id}}` | `WorldManager.World` of a world; its presence means the world is open |
| `:pg` group `{:zones, world_id}` | Zone processes of a world |
| `:pg` group `{:players, world_id}` | WorldManager connections that logged in (`Cluster.Registry.join_players/2`, `player_count/1`) |
| `:pg` group `{:session, user_no}` | the process that is the session of the account |

The `:pg` scope `Cluster.Registry` is started by `Cluster.Root`. libcluster runs only when `cluster.nodes` is not empty, with `Cluster.Strategy.Epmd` and those hosts. `Cluster.Root` has that name because libcluster owns `Cluster.Supervisor`.

## Sessions

`Cluster.Sessions.take_over/1` makes the calling process the session of an account and sends every older member `{:cluster, :session_replaced}`; the connection handlers answer it with `0x0C17 {0x683}` and close. `Cluster.Sessions.leave/1` ends it: Login's connection calls it when it hands the client to WorldManager, so the later WorldManager login does not cut the Login link.

## Facades

A part reaches another part only through a facade module of `Cluster` (never a direct call). `Cluster.WorldManager.expect_login/2` is a `GenServer.call` of `{:expect_login, request}` to the `WorldManager.World` of the world; the process answers `:ok` and stores the reservation. It exits when the world is not registered. Flow: [`flows/world-select.md`](flows/world-select.md).
