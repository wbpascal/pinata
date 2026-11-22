# Flow: leave the world

How a character in the world is saved and removed from its map instance (`Zone.Handler`, `Zone.MapInstance`,
`Persistence.save_character/4`, `Cluster.Sessions.leave_world/1`, `Cluster.Sessions.take_over/1`,
`WorldManager.Handler`). There is one leave path in the Zone connection: remove the player from the map instance,
then save it. Whatever ends the stay runs it, except a crashed map process (nothing to remove, nothing saved) and a
killed Zone connection process (it cannot run code; the map instance removes the player on its `:DOWN`).

```mermaid
sequenceDiagram
    participant C as Client
    participant M as WorldManager connection (session)
    participant Z as Zone connection
    participant I as Map instance
    participant P as Persistence
    participant L as Login connection (second login)
    alt 0x0C18 {1}: back to the character list
        C->>M: 0x0C18 {1}
        M->>Z: leave_world (call, 5 s)
        Z->>I: leave(handle)
        I-->>Z: the player as it was on the map
        Z->>P: save_character(world, id, map/x/y/hp/sp, {:leave, minutes})
        Z-->>M: :ok (after the save); Z stays open in step :left
        Note over M: zone :none, a new 0x1001 is accepted
        C->>M: 0x0C1F
        M->>C: 0x0C14 character list
        C->>Z: close (1 s later)
    else the session ends (0x0C18 {0}, lost socket, replaced)
        Note over M: process ends
        M-->>Z: :DOWN (or session_replaced)
        Z->>I: leave(handle)
        Z->>P: save_character(..., {:leave, minutes})
        Note over Z: connection closed: session ended / session replaced
    else the Zone socket closes
        C->>Z: close
        Z->>I: leave(handle)
        Z->>P: save_character(..., {:leave, minutes})
        Z-->>M: :DOWN, zone :none; the session stays open
    else a second login of the account
        C->>L: 0x0C04 (or 0x0C37, 0x0C0F at WorldManager)
        L->>M: session_replaced (monitored)
        L->>Z: session_replaced (monitored)
        M->>C: 0x0C17 {0x683}, close
        Z->>I: leave(handle)
        Z->>P: save_character(..., {:leave, minutes})
        Z-->>L: :DOWN
        M-->>L: :DOWN
        L->>C: login answer (after both ended; 5 s at most, then 0x0C09 {0x45} or 0x0C15 {0x46})
    else the map instance stops in order (shutdown)
        I->>Z: map_stopped (the player)
        Note over I: ends
        Z->>P: save_character(snapshot, {:leave, minutes})
        Note over Z: connection closed: map instance stopped
    else the map process crashes
        I-->>Z: :DOWN
        Note over Z: connection closed: map instance lost (warning), nothing saved
        Note over I: started again empty by Zone.MapSupervisor
    end
```

A Zone part stopped in order (`Zone.Supervisor` terminated, a node stop) stops its listener first: each Zone
connection writes `connection closed: listener stopped` and runs the leave path while its map instance still runs.

## Rules

- **What is saved.** `login_map`, `login_x`, `login_y`, `hp`, `sp` from the player on the map, and `kq_date` (the
  time of the save, as the original's `p_Char_SaveLocation`; the character list shows it). A leave also adds the
  whole minutes since the accepted map entry to `play_minutes` and sets `logout_at`. One `update_all` of these
  columns ([`persistence.md`](../persistence.md), "Save").
- **Auto-save.** From `0x1803` on, the Zone connection saves its player every 10 minutes (a real timer,
  `Process.send_after/3`, re-armed at each save). It reads the player from the map instance (`player/2`) and saves
  without play minutes and logout time.
- **The second login waits.** `take_over/1` monitors the old session and its Zone connection, tells both, and returns
  when both have ended, so the character is saved when the new login is answered. After 5 s it refuses: Login answers
  `0x0C09 {0x45}`, WorldManager `0x0C15 {0x46}` (the codes of a database failure), with one `error` line.
- **No logout timers.** `0x1071` (exit countdown started) and `0x1072` (cancelled) are accepted without effect; the
  character leaves at once (the original keeps it for up to 13 s). `0x0C18` on the Zone connection is ignored: the
  session drives the leave.
- **Sight.** `0x1805` to the players in sight is sent where the map instance removes a player (`remove/2`), with issue
  109; nobody sees another player yet.

## A save that fails

| When | Server log | Effect |
|---|---|---|
| auto-save, row gone | `error`, `Zone: auto-save failed: character <id>, character not found` | the player stays |
| auto-save, database | `error` from `Persistence` and `Zone: auto-save failed: character <id>, database failure` | the player stays |
| auto-save, player not on the map | `error`, `Zone: auto-save failed: character <id>, not on the map` | none |
| leave, row gone or database | `error`, `Zone: save at leave failed: character <id>, <reason>` | the player is removed anyway; `0x0C18 {1}` still goes on to the list |
| leave, saved | `info`, `Zone: left the world: character <id>, map <map>` | |
| WorldManager: the Zone connection does not answer the leave in 5 s | `error`, `WorldManager: the Zone connection did not confirm the leave within 5 s` | the session keeps the Zone connection: `0x1001` answers `0x1002 {0x145}` until it ends |
