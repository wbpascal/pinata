# Client input is untrusted; compatibility covers only possible input

The rebuild must speak the unchanged 2016 client protocol, and the original server trusted its client in many places. We decided that every byte from a client connection is untrusted input, and that the server owes byte-compatible behaviour only for input the unmodified 2016 client can produce. For impossible input the server may do whatever is safest, so security checks never conflict with the capture replays of ADR 0008.

**Trust levels.** Untrusted: every client connection, before and after login. Trusted: the administrator, the settings file, the data directory, the database contents and the other nodes of the cluster (ADR 0002). A damaged or hostile data table is not a threat we defend against.

**The trust boundary is the packet handler.** A handler turns client values into checked values (a table row, an owned object, a number in range) before it calls anything else. Modules behind the boundary never receive a text or a number a client wrote, so they need no checks of their own. We chose this over guarding each dangerous function because a guard at the sink must guess every bad form, while a lookup at the boundary accepts only what exists. A second check at a sink is added only where a mistake would be severe (file paths, database statements).

**The client states an intent, never an outcome.** Each handler checks that the packet is valid in the current step of the connection, that the objects it names belong to the sender or are reachable by them, and that the claimed values are possible. Where the original trusted the client, the rebuild checks with a tolerance the unmodified client never exceeds.

**Two answers to a violation.** Impossible input closes the connection, with a server log line and a telemetry event (ADR 0011). A refused request gets the error code of the original server and the connection stays open.

**Original-server bugs.** A bug of the register is reproduced only when the unmodified client depends on it or a capture shows it. An exploitable one (unchecked input, a missing ownership check) is fixed, and the fix cites its bug id.

**Values the server issues** (login token, world key, validation key) come from the cryptographic random source, work once and expire after a short time. The client only echoes them.

**Isolation.** Untrusted input may crash only the process of its own connection, never a shared one such as a map instance (ADR 0009).

## Accepted limits

- The password crosses the network readable by anyone on the path: the client→server cipher is a fixed XOR and the fix needs a changed client. The server adds no tunnel.
- Links between nodes are plain Erlang distribution. Multi-node mode is safe only on a private network with a secret cookie; this is a deployment requirement, not code.

## Consequences

- Compatibility with the original is no argument for an unchecked client value.
- A finding is urgent when a client can reach the code today; one about a path no client reaches is ordinary work.
- `server/docs/user/security.md` tells administrators what follows from the accepted limits, and grows with the server.
