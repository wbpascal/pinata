# One process per map instance on a fixed tick

A map instance is one process that owns everything on the map (players' game state, monsters, NPCs, drops) and handles it sequentially. We chose this over a process per player or monster because every interaction on a map (attack, pick up, trade, area skill) stays a plain function call on one state, with the original server's sequential semantics and a packet order that captures can pin down. We chose it over one process per Zone node, which is what the original does, because maps then run in parallel on all cores. The cost: one crowded map is limited to one core.

What hangs off that choice:

- **Connection process.** Each client socket has one process that does only framing, the cipher, packet decoding and encoding, and send buffering. It also does everything before a player is on a map (handshake, map-login checks, session check with WorldManager, loading the character) and hands the map process a fully loaded player. A slow client or a slow database blocks one connection, never a map.
- **Players are data.** A player is a plain struct inside the map process with an optional connection. A bot is the same struct without one. Changing maps hands the struct to the target map process, on the same node or another; saving writes it.
- **Fixed tick.** A map instance advances movement, monster behaviour, combat, regeneration and expiry every 100 ms, the original's timer resolution. Client packets are handled on arrival, not queued for the tick. Time comes only from the injected `Clock`, so a replay test drives the ticks. An empty map instance does not tick. We chose a tick over per-object timers because it is deterministic under replay.
- **Handles per map instance.** Each map instance allocates handles from the original's ranges on its own. The original allocated per zone process; a client only sees handles of its own map, so it cannot tell. The player range (8000 to 9499) makes 1500 players the hard limit of one map instance.
- **Handlers are pure.** A packet handler or tick step takes the map state and returns the new state and a list of effects (send, broadcast, save, call WorldManager, audit event). Only the map process carries effects out; work that can be slow runs outside it and reports back by message.

## Consequences

- A map process that crashes restarts empty; its players are disconnected with the state of their last save. Saves therefore also happen on important events, not only every 600 s.
- A packet that names an object on another map cannot use a handle. None is known in client-facing packets (party packets use character names); if one turns up, it becomes a lookup.
- 100 ms is coarse for movement, and one core may not be enough for a crowded map. Both are tracked outside the rebuild map and wait for load figures:
  [a finer tick](https://github.com/wbpascal/pinata/issues/26), [one map on several cores](https://github.com/wbpascal/pinata/issues/25).
