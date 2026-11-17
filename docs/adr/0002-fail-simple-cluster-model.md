# Fail-simple cluster model: static map assignment, no failover

Parts find each other through OTP built-ins: `:global` names for Login (`{:login}`) and each world's WorldManager (`{:world_manager, world_id}`), and one `:pg` group of Zone nodes per world (`{:zones, world_id}`). Node discovery goes only through libcluster (static hosts by default, no topology in single-node mode). We chose this over a registry dependency because the names are few and coarse, and it runs unchanged on one node.

WorldManager owns the map table. It waits until a configured number of Zone nodes has joined (default 1), then assigns every map in one pass by rendezvous hashing over those nodes. A Zone node that joins later takes only maps that are not running; a running map never moves.

Nothing fails over:

- **Zone node lost:** its players are disconnected (their sockets were on that node), WorldManager drops their sessions and reassigns only that node's maps to the remaining Zone nodes. Character state since the last save is lost, as after a crash of an original zone.
- **WorldManager lost:** every Zone node saves and disconnects all its players, then waits for WorldManager to return and registers again.
- **Login lost:** players in game are unaffected; new logins fail until it restarts.

We accepted this because it matches what the original server does on a crash, and because failover and live map moves can only be designed well against a running multi-node server.

## Consequences

- Rendezvous hashing spreads maps by count, not by load: two crowded maps can land on one Zone node. A per-map pin in configuration is the intended first remedy.
- Failover and load balancing by moving maps are tracked as separate issues outside the rebuild map:
  [failover](https://github.com/wbpascal/pinata/issues/20), [moving maps](https://github.com/wbpascal/pinata/issues/21).
