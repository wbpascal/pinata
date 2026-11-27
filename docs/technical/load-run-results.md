# Load run results

One row per recorded [load run](../../GLOSSARY.md) (procedure: [`load-run.md`](load-run.md)): the machine it ran
on, the database, and the two capacity figures as `Pinata.Figures.print()` showed them at `hold complete`, together
with what the load task saw from outside (login rate, connect failures, disconnects).

| Date | Commit | Scenario | Players | Mode | Machine | Cores | Database | Packet handling time p99 (target 50 ms) | Tick duration p99 (target 100 ms) | Login rate | Connect failures | Disconnects |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 2026-11-26 | 172481b | crowd | 1500 | single node | Windows development machine, AMD Ryzen 9 3900X with 6 of its 12 cores enabled, 24 GB RAM, load task on the same machine | 6 physical (12 threads) | SQLite | > 1000 (p50 > 1000) | > 1000 (p50 > 1000) | about 100 per second | 0 | 400 |
| 2026-11-26 | 172481b | crowd | 1500 | multi node (Compose stack) | Windows development machine, AMD Ryzen 9 3900X with 6 of its 12 cores enabled, 24 GB RAM, load task on the same machine | 6 physical (12 threads) | PostgreSQL | <= 100 | <= 100 | about 20 per second | 213 | 643 |

Figures in ms, as the histogram buckets of `Pinata.Figures` print them (`<= b`: at most the bucket bound `b`;
`> 1000`: the overflow bucket).

## Notes on the runs

### 2026-11-26, the first Crowd runs ([issue 120](https://github.com/wbpascal/pinata/issues/120))

Information only, as decided in [issue 27](https://github.com/wbpascal/pinata/issues/27); both runs miss. The miss is
tracked against ADR 0009 in [issue 150](https://github.com/wbpascal/pinata/issues/150).

- **Single node, SQLite: both figures miss by more than ten times.** Not only the 99th percentile but the median
  of both figures is in the overflow bucket. The map process cannot keep up with 1500 players, and 400 of them were
  disconnected. `Pinata.Figures.print()` at `hold complete`:

  ```
  Packet handling time (ms)
    buckets <=: 0.1 0.25 0.5 1 2.5 5 10 25 50 75 100 250 500 1000 +Inf
    all nodes: count 138484, p50 > 1000, p99 > 1000, buckets 15347 9385 241 76 20 2 1 1 0 0 0 0 0 0 113411
  Tick duration (ms)
    buckets <=: 0.1 0.25 0.5 1 2.5 5 10 25 50 75 100 250 500 1000 +Inf
    all nodes: count 121, p50 > 1000, p99 > 1000, buckets 0 0 0 0 0 0 0 0 0 0 0 0 0 0 121
  ```

  - Every one of the 121 ticks took more than 1 s. A hold of 300 s at 100 ms has room for 3000 ticks; 121 ticks
    are one tick per 2.5 s on average.
  - The packet handling time splits in two: 25,073 packets (18 %) took at most 25 ms, most of them at most
    0.25 ms, and 113,411 (82 %) took more than 1 s, with nothing in between. The span `[:pinata, :packet]` is
    measured in the connection process (`Net.Connection`), so a packet that calls the map instance includes its
    wait in the map process's queue: the fast packets are those the connection answers alone, the slow ones wait
    behind the ticks.
  - The node serves Login, WorldManager and Zone, so the figures are those of the one node.
- **Multi node, PostgreSQL: packet handling time misses, and the crowd was not complete.** A p99 of `<= 100` lies in
  the bucket 75 to 100 ms, above the 50 ms target. The tick duration of `<= 100` meets its target only at the bucket
  bound. These figures do not count as a pass: 213 players failed to connect and 643 were disconnected, so at most
  644 of the 1500 players were in the world at `hold complete`, and the map instance carried less than half the
  crowd it was measured for. The output of `Pinata.Figures.print()` of this run was not kept, so the bucket counts
  and the figures per node are unknown.
- **Login rate.** The multi-node run logged in at about 20 players per second against about 100 on one node. That
  run had `login.auto_create_accounts = true` in `compose.toml` (the procedure creates the accounts beforehand), so
  the Login node hashed each password at the first login; this is the likely cause of the lower rate and may account
  for part of the connect failures.
- **What the figures include.** The load task ran on the same machine and shared its cores with the server (and in
  the multi-node run with Docker and PostgreSQL), so both runs measure a server with fewer free cores than a server
  machine would have. The single-node run also has Login, WorldManager and SQLite on the node that runs the map
  instance. A run with the load task on a second machine separates the two.
