# Flow: movement

Walk, run and stop between a Zone connection, its map instance and the players in sight (`Zone.Handler`,
`Zone.MapInstance`, `Zone.Mover`, `Zone.Sight`). The rules: [`../movement.md`](../movement.md).

## Accepted move

```mermaid
sequenceDiagram
    participant C as Client (mover)
    participant Z as Zone connection (mover)
    participant I as Map instance
    participant O as Zone connection of a player in sight
    participant OC as Its client
    C->>Z: 0x2017 walk / 0x2019 run {from, to}
    Note over Z: in the world only; before it, no answer
    Z->>I: move(handle, kind, from, to)
    Note over I: step the mover to the millisecond, then the checks
    Note over I: new mover from the server position, remember the move packet
    I->>O: {:cluster, {:packets, [0x2018 / 0x201A {handle, from = server position, to, speed, 0}]}}
    O->>OC: 0x2018 / 0x201A
    I-->>Z: :ok
    Note over Z: nothing for the mover itself
```

## Refusal

```mermaid
sequenceDiagram
    participant C as Client
    participant Z as Zone connection
    participant I as Map instance
    C->>Z: 0x2017 / 0x2019 / 0x2012
    Z->>I: move(...) / stop(...)
    Note over I: from == to, 200 units, no free cell, line blocked (stop: 200 units, no free cell)
    Note over I: stop block check (a pull-back when on a blocked cell)
    I->>Z: {:cluster, {:packets, [0x201B {server position}]}}
    I-->>Z: :ok
    Note over Z: takes the pushed packets from its mailbox right after the call
    Z->>C: 0x201B
```

## Stop

```mermaid
sequenceDiagram
    participant C as Client
    participant Z as Zone connection
    participant I as Map instance
    participant O as Zone connection of a player in sight
    C->>Z: 0x2012 {loc}
    Z->>I: stop(handle, loc)
    Note over I: step the mover to the millisecond; loc within 200 units with a free cell
    Note over I: mover ends, the remembered move is forgotten
    I->>O: {:cluster, {:packets, [0x2013 {handle, server position}]}}
    I-->>Z: :ok
```

## Tick step with appear and disappear

```mermaid
sequenceDiagram
    participant T as Clock
    participant I as Map instance
    participant Z as Zone connection (mover)
    participant N as Zone connection of a player coming into sight
    participant L as Zone connection of a player leaving sight
    T->>I: {:tick, ref} every 100 ms
    Note over I: each moving player in handle order: slices of at most 100 ms, block check, step/3
    I->>N: [0x1C06 at the position before the step, 0x2018 / 0x201A from that position]
    I->>Z: [0x1C06 of the player coming into sight] / [0x1C08 of an NPC]
    I->>L: [0x1C0E {mover}]
    I->>Z: [0x1C0E {player leaving}]
```

## Pull-back

```mermaid
sequenceDiagram
    participant I as Map instance
    participant Z as Zone connection (mover)
    participant O as Zone connection of a player in sight
    Note over I: a slice point is blocked, the last good position is more than 30 units away, all four probes blocked
    Note over I: position := last good position (step/3, sight rule), mover ends, move forgotten
    I->>O: {:cluster, {:packets, [0x2013 {handle, position}]}}
    I->>Z: {:cluster, {:packets, [0x204A {position}]}}
```
