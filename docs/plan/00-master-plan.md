# Master plan: reconstructing the server in pseudocode

Goal: a behavioural reconstruction of every server process (Login, World manager, Zone, Account,
AccountLog, Character, GameLog) as structured pseudocode. Each block cites the original function, and each
packet is cross-checked with the 2016 client. Format and depth follow `docs/pseudocode/login-server.md`
(Login is **done**).

## How to run a work item

Start a fresh agent session in this repository and give it one plan file:

> Execute the work item described in `docs/plan/items/Z03.md`.

`CLAUDE.md` is loaded automatically. It holds the shared conventions, the data locations
(`re-data/exports`, `re-data/ghidra`) and the facts already established, so no session re-decompiles or
re-derives anything. If a session runs out of budget, start another one with the same sentence. It
resumes from `docs/plan/status/<ID>.md`.

Items in the same phase can run in parallel: they write disjoint files (see "Shared files" in
`CLAUDE.md`). Dependencies are soft. An item can start before its dependencies finish, but it will
produce better results after them, so respect the order when you can.

## Phases and items

Sizes count the handlers in scope and their decompiled lines. Callee logic adds 2–10× more.

### Phase 1: foundations (run these first; all can run in parallel)

| ID | Item | Depends | Handlers | Lines |
|---|---|---|---|---|
| [C01](items/C01.md) | Client packet-handler inventory (names and meaning of server→client packets) | – | client | – |
| [C02](items/C02.md) | 2017 client PDB: official opcode names, `PROTO_NC_*` structs, shared types, client function names | C01 (soft) | – | – |
| [W01](items/W01.md) | World manager core: sessions, world login, characters, zone handoff | – | see file | |
| [Z01](items/Z01.md) | Zone core: process, maps, objects, player session, map login/logout | – | see file | |
| [P01](items/P01.md) | Packet capture decoder + validator (pure Python, self-testing; needs no captures yet) | – | – | – |
| [P03](items/P03.md) | Wireshark Lua dissector generated from the docs (live decrypted, named packets while recording) | P01 (soft) | – | – |

C01 has the highest leverage: every later item uses its client cross-reference. Run it first if you
can only run one item at a time. C02 (added after C01, W01, Z01, P01, P03 were done) comes next: the 2017
PDB names 1347 opcodes that are unnamed today and gives field names for ~2300 packet structs, so run it
before the phase-2 items.

### Follow-ups for items done before the 2017 PDB arrived

Evaluated 2026-11-11 by comparing the PDB with each item's output. C02 measures and lists the differences
(`docs/knowledge/C02.md`); the owner then fixes its own files in a short follow-up session ("Execute the
follow-up for W01 listed in `docs/knowledge/C02.md`").

| Item | Benefit | What changes |
|---|---|---|
| C01 | **High** | 645 of 901 client-handled opcodes are unnamed and get the PDB name; 2017 `On_NC_*` handlers (705) and 30909 function names can be ported to the 2016 client (C02 does the port); client class layouts. The 8 `client` names all agree |
| W01 | **High** | 133 of its 182 scope opcodes are unnamed today and get official names; 174 have a PROTO struct with field names. 27 of its 35 hand layouts match; 8 differ only by the `ref` prefix / 2-byte prefix (confirm). 3 name conflicts (`0x0871`, `0x1409`, `0x10d2`) to settle |
| L00 | Medium | 32 of 41 login handlers are unnamed; 23 hand layouts get official names and field names (`0x0C5A` `sUserName[260]`, so the `unused` at 256 is the name's tail; `0x0C66` is a 1-byte struct). `login-server.md` "(ours)" names can be replaced |
| Z01 | Medium | 54 of 65 scope names already agree; 4 conflicts are shared-handler naming (`0x9884`/`0x9885`, `0x0865`, `0x1095`); 24 of 30 hand layouts match, 6 differ by the `ref` prefix. SHN row structs (134 `::DataVersion`) can cross-check its table loaders. ShinePlayer is a server class and not in the PDB |
| P03 | Medium | Dissector shows generated "guess" fields for most packets; PDB layouts give named fields for ~2300 packets once C02 adds them as a source to `make_dissector.py` |
| P01 | Low | Decoder picks up names automatically after `regen.sh`; same layout-source change as P03 |

### Phase 2: subsystems (any order once their dependencies are done; up to ~4 in parallel works well)

| ID | Item | Depends |
|---|---|---|
| [W02](items/W02.md) | WM: party and raid | W01 |
| [W03](items/W03.md) | WM: guild and guild academy | W01 |
| [W04](items/W04.md) | WM: friends, chat routing, KQ, holy promise, instances, misc | W01 |
| [Z02](items/Z02.md) | Zone: movement, chat, emotes, sight, NPC menus, scenario | Z01 |
| [Z03](items/Z03.md) | Zone: combat, skills, abstates, damage | Z01 |
| [Z04](items/Z04.md) | Zone: items, inventory, equipment, upgrades | Z01 |
| [Z05](items/Z05.md) | Zone: ITEMDB protocol (item persistence) | Z04 |
| [Z06](items/Z06.md) | Zone: trade, booths, gambling, dice | Z04 |
| [Z07](items/Z07.md) | Zone: stats, progression, pets, mounts, mini-house, cards | Z01 |
| [Z08](items/Z08.md) | Zone: quests, KQ, instances, guild/party/friend zone side | Z01 |
| [Z09](items/Z09.md) | Zone: world simulation (mobs, AI, spawns, drops, scripts, timers) | Z01, Z03 |
| [Z10](items/Z10.md) | Zone: certification and the downloaded start script (stage order, run/walk factors, kill switch?) | Z01 |
| [Z11](items/Z11.md) | Zone: GM ampersand (&) commands (added by Z02: 119 `AmpersandCommand_ac_*` functions) | Z01, Z02 |
| [D01](items/D01.md) | Account + AccountLog servers (resolves open Login error conditions) | – |
| [D02](items/D02.md) | Character server: characters, avatars, save/load | – |
| [D03](items/D03.md) | Character server: items, economy, pets, house | D02 |
| [D04](items/D04.md) | Character server: social, guild, quests, skills | D02 |
| [D05](items/D05.md) | GameLog server | – |
| [P02](items/P02.md) | Capture validation: confirm/correct layouts and message order with real traffic. **Recurring:** run after each batch of captures and after each phase | P01, captures |

The DB items (D01–D05) don't depend on the zone/WM items and can fill gaps in parallel runs.

### Phase 3

| ID | Item | Depends |
|---|---|---|
| [X01](items/X01.md) | Integration: architecture overview, feature → message index, glossary, contradictions, regen | all |

Exact handler counts and line sizes per item: `docs/plan/items/_summary.json` and the scope table at the top
of each item file.

## Packet captures

Static analysis tells us what the code *can* send. Captures confirm what it *does* send. How to record
them, which scenarios, and privacy notes: [`capture-guide.md`](capture-guide.md). Put captures and their
notes in `re-data/captures/`, then run P02. Capture-confirmed facts are the strongest evidence level
(see `CLAUDE.md`). P02 reports contradictions per owning work item, so the owner can fix them in a
follow-up session.

## Suggested order with limited budget

1. C01 → W01 → Z01, plus P01 and P03 (both cheap; install the dissector, record capture scenarios 1–5, run P02 early)
1b. C02, then the follow-ups above (C01, W01, L00 first)
2. Z02, Z03, Z04, W02 (core gameplay)
3. Z07, Z08, Z05, Z06, W03, W04
4. D02, D01, D03, D04, D05, Z09, Z10, Z11
5. P02 again with fuller captures, then X01

Large items (Z04, Z05, Z08, D03, D04) will probably need two or three sessions each. Starting a new session
with the same plan file resumes from the status file.

## Output layout

```
docs/pseudocode/login-server.md           done (reference format)
docs/pseudocode/wm/W0x-*.md               world manager
docs/pseudocode/zone/Z0x-*.md             zone
docs/pseudocode/db/D0x-*.md               database servers
docs/pseudocode/README.md                 X01: overview + index
docs/knowledge/<ID>.md                    cross-item facts (structs, offsets, subsystem notes)
docs/plan/status/<ID>.md                  progress logs
tools/protocol-re/names/<bin>/<ID>.json   discovered names (merged by clean.py)
docs/protocol/annotations/<ID>.json       verified packet layouts (merged by packets.py / regen.sh)
re-data/client-handlers.json              C01: client opcode → handler map
docs/protocol/pdb-layouts.json            C02: PROTO_NC_* layouts from the 2017 PDB
```

## Regenerating the plans

The item definitions live in `tools/protocol-re/make_plans.py`. To change scope or wording, edit that file
and run `python3 -I tools/protocol-re/make_plans.py`. Don't hand-edit `docs/plan/items/*.md`.
