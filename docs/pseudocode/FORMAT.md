# Pseudocode format (short reference)

Distilled from `login-server.md`, the reference example. Read this instead of the whole file. For one more worked
example, use `python3 -I tools/protocol-re/sect.py docs/pseudocode/login-server.md 4`.

## Document skeleton

```
# <Server>: <area> (<item ID>)
<source binary, how to view the code (clean.py), evidence markers used, links to packets/annotations>
## 1. <Subsystem>: data structures, tables loaded, timers, invariants
## 2. <Handlers group> (<Parser class>, registered @ FUN_…)
…
## Original-server bugs
## N. Not reconstructed / uncertain
## N+1. Coverage boundary
```

Number the sections (`## 5.`, `### 5.2`), because other items cite them as `§5.2`.

## Handler block

````
```pseudo
0x0C5A NC_USER_US_LOGIN_REQ { char sUserName[260]; char sPassword[36]; Name5 spawnapps }   (exact length 0x13E)   @ FUN_00406450
    if len != 0x13E: return
    Send to AccountDB 0x0C5B NC_USER_US_PASSWORD_CHECK_REQ {   # size 0x152
        u16  clientHandle  = s.handle
        char sUserName[260] = payload.sUserName (copies max 256; bytes 256..259 never read)
        char sUserIP[20]    = sprintf("%03d.%03d.%03d.%03d", s.ip)
    }
    # answer arrives as AccountDB 0x0C5C (§5.1)

0x0C65 NC_USER_CLIENT_VERSION_CHECK_REQ { char sVersionKey[64] }:   @ FUN_004060d0
    …
    Send 0x0C66 NC_USER_CLIENT_WRONGVERSION_CHECK_ACK {}
    # (original bug) L00-B1: one uninitialised byte on the wire
```
````

Per handler: opcode + official name + payload fields, `@ FUN_…` of every function the logic comes from, length and
input checks, state changes, every packet sent (to whom, with field values), error codes with meaning and the client
text (`docs/protocol/client-error-codes.json`), timers. Mark *(inferred)*, *(pdb2017)*, *(db-backup)*, *(captured)*
as defined in `AGENTS.md`.

## Original-server bugs

Tag the behaviour in place with `(original bug) <ID>-B<n>` and add one row per bug here:

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| L00-B3 | 0x0C0B | accepts world status 5 (full); only < 5 is refused | DB/log/WM messages are sent for a world the client then refuses | refuse status 5 too (`< 6`) |

## Not reconstructed / uncertain

Bullets: what is unknown, why, and where to look next (functions, tables, other servers).

## Coverage boundary

Everything you found but did not cover, each with the argument why it is outside this item. Running out of context is
not a reason; that goes to the status file as remaining work. A finished item (status `**State:** done`) is a valid
"Covered by" only if its output already documents the thing (cite the §): fix small gaps in your own output,
create a follow-up item for larger ones (plan step 8). (Rows below are made-up examples of the form.)

| Found (function / packet / table / behaviour) | Covered by | Argument |
|---|---|---|
| `FUN_004a1230` mob drop roll | Z09 (scope: "drops") | reached from 0x2401 only after the kill; drop logic is world simulation |
| zone↔WM `0x3C12` relay | new item Z18 (added by this item) | no item lists dept 0x0F; does not fit any existing scope |
