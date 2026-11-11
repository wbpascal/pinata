# Fiesta server reconstruction: shared context for every session

The source code of our server is lost; only binaries remain. We are reconstructing a behavioural
specification (protocol + pseudocode) from those binaries, split into work items. If you were given a
plan file (`docs/plan/items/<ID>.md`), follow it. This file holds the shared conventions.

## Repository map

| Path | What |
|---|---|
| `Files/Server/2016/` | The **2016** server binaries we reconstruct (Login, WorldManager, Zone×4 identical, Account, AccountLog, Character, GameLog) and their config + `9Data/Shine/*.shn` data tables |
| `Files/Client/2016/Fiesta.bin` | The matching game client (PE32). `Files/Client/2016/ressystem/*.shn` = client data tables (texts, items…) |
| `Files/Client/2017/Fiesta.bin` + `Fiesta.pdb` | Slightly newer client (`patch_2017_08_p01`) with its **full private PDB** (GUID matches the exe): official opcode enums, `PROTO_NC_*` packet structs with field names, shared enums/structs, client function names. Read with `tools/protocol-re/pdb.py`; work item C02 |
| `Files/Server/2016/_Database/` | SQL Server backups from private-server installs (Account, AccountLog, StatisticsData, Character + w00_Character, GameLog + w00_GameLog, OperatorTool) and their `Fixes/*.sql`: stored-procedure source, close to but not the 2016 build. Read with `tools/protocol-re/bak.py`; see `docs/plan/db-backups.md` |
| `Files/Server/2015`, `Files/Client/2015` | Older versions. Only for diffing; do not document them |
| `re-data/exports/<bin>/` | **Ghidra exports, already done. Use these, do not re-decompile.** `decomp.c` (all functions, `//==== FUNC <addr> <name>` separators), `strings.tsv` (addr, value, referencing functions), `handlers.json`, `layouts.json` |
| `re-data/captures/` | Packet captures of real client↔server traffic (`.pcap/.pcapng`) + scenario notes (`.md`). Sensitive: test accounts only. Decoder: `tools/protocol-re/pcap_decode.py` (work item P01) |
| `re-data/ghidra/` | Persistent Ghidra 12.1.4 project with all 8 binaries analyzed (`<bin>` = project name). Run extra Ghidra scripts against it with `-process -noanalysis` instead of re-importing |
| `tools/protocol-re/` | Scripts (see below) |
| `tools/protocol-re/names/<bin>/*.json` | Known function/global names, one file per work item, merged automatically |
| `docs/protocol/` | Protocol spec: `README.md` (framing, crypto, flows), `opcodes-*.md`, `packets-*.md` (generated layouts), `opcodes.json`, `client-error-codes.json`, `annotations.json` + `annotations/<ID>.json` (hand-verified layouts) |
| `docs/pseudocode/` | Reconstructed pseudocode. `login-server.md` is the **reference example** for format and depth |
| `docs/knowledge/<ID>.md` | Findings that other items need: struct/member offsets, subsystem facts, open questions |
| `docs/plan/` | Master plan, work item plans, `status/<ID>.md` progress logs |

`<bin>` export names: `login`, `wm`, `zone`, `account`, `accountlog`, `character`, `gamelog`, `client`.

## Tools (run from the repo root)

```bash
T=tools/protocol-re; E=re-data/exports
python3 -I $T/clean.py $E/zone $T/names/zone 452590 451a30   # print functions, noise stripped, known names applied
grep -n "sp_NC_MAP_LOGIN_REQ" $E/zone/strings.tsv            # string -> referencing functions
python3 -I $T/shn.py Files/Server/2016/9Data/Shine/ItemInfo.shn | head  # decode any .shn data table (server or client)
python3 -I $T/bak.py Files/Server/2016/_Database/w00_Character.bak proc p_Char_Create  # stored-procedure source from a DB backup
python3 -I $T/bak.py cover character                        # every {CALL} of a binary vs all DB backups
python3 -I $T/errcodes.py $E/client Files/Client/2016/ressystem   # client error-code -> message table
P=Files/Client/2017/Fiesta.pdb
python3 -I $T/pdb.py $P types '^PROTO_NC_MAP_LOGIN_REQ$'          # 2017 PDB: structs/enums by regex (C-like dump)
python3 -I $T/pdb.py $P types '^PROTOCOL_COMMAND_MAP$'            # official opcode names of one dept (enum value = cmd)
python3 -I $T/pdb.py $P publics 'On_NC_'                         # 2017 client function names + addresses
tools/protocol-re/regen.sh                                   # rebuild ALL generated docs (after adding names/annotations)
tools/protocol-re/reanalyze.sh <bin> <exe>                   # only if an export is missing or broken (slow)
```

- `handlers.json`: every `pft_Store(dept, cmd, handler)` registration per parser class: opcode, handler, name, sends.
- `layouts.json`: generated packet field layouts (`s2c` send sites, `c2s` handler reads).
- REA MCP tools (Ghidra 12.1.4 provider) work for targeted questions (xrefs, callers, data reads). Each
  `open_binary` re-imports and analyzes the binary (zone: several minutes). Prefer the exports for reading
  code. Call `close_binary` when done.
- Reading raw data at an address: Python over the PE file (see `rtti.py` `PE` class), or REA `read_bytes`.

## Facts already established (do not re-derive)

- Packet framing, opcode = `dept<<10 | cmd`, the client→server XOR-499 cipher and seed: `docs/protocol/README.md`.
- Handler registration: `PROTOCOLFUNCTIONTEMPLETE<Class>::pft_Store(dept, cmd, fn)`. Zone handlers are
  `ShineObjectClass::ShinePlayer::sp_NC_*`, and their profiler strings give the original names. WM/Character
  log strings use `fc_NC_*`.
- Zone sends: opcode is written into the global buffer `PTR_DAT_0084d908` (opcode at +0, payload at +2),
  then `FUN_004c8ce0(&buf, totalSize)` sends to the player. Other calls taking `(&buf, size)` broadcast.
- Login/WM sends: `CSendPacket` (`Pkt_SetOpcode(buf, op, payloadSize, src)`, payload at buf+5) or raw byte
  headers `{len, opLo, opHi, payload…}`.
- Zone vtables: `tools/protocol-re/rtti.py` recovers MSVC vftables from RTTI
  (`ShineObjectClass::ShinePlayer` has 986 slots). `(**(code **)(*this + 0x664))(…)` = slot 0x664/4.
- Client: the login screen dispatcher is `FUN_0046f4d0`. Error code → text is `FUN_00416430`. Texts are
  looked up by 32-bit id in `TextData*.shn`. Each client "scene" has its own dispatcher (work item C01 maps them all).
- SHN cipher and layout: `tools/protocol-re/shn.py` (taken from zone `FUN_0062a0b0` / `FUN_0062a780`).
- 2017 PDB: opcode name = member of enum `PROTOCOL_COMMAND_<DEPT>` (cmd) under `NC_<DEPT>` in `PROTOCOL_COMMAND` (dept).
  Packet body = struct `PROTO_<opcode name>`. Server-internal packets about a player carry the 6-byte `ref` prefix
  (`docs/knowledge/Z01.md`), which the PROTO struct does not include. ~10 % of the 2017 names conflict with names
  read from the 2016 binaries, so a PDB fact counts for 2016 only after a 2016 binary agrees.

## Conventions for every work item

1. **Read before investigating.** Check `docs/knowledge/*.md`, `docs/plan/status/*.md`, the names files
   and the existing pseudocode for the symbols you touch. Do not redo work another item has recorded.
2. **Output format** = `docs/pseudocode/login-server.md`:
   - structured pseudocode per handler and subsystem, each block citing `@ FUN_xxxxxxxx`
   - packet fields by name, constants and error codes with meaning
   - state that changes, messages sent to whom, timers
   - a "Not reconstructed / uncertain" section at the end
   - **original-server bugs**: mark every behaviour that looks unintended (wrong opcode or code, unchecked input,
     uninitialised bytes, a code the client does not handle, dead checks, …) with the literal tag `(original bug)`
     where you describe it, and list them all in an "Original-server bugs" section before "Not reconstructed": one
     table row each with ID (`<item>-B<n>`), handler, 2016 behaviour, effect, likely intent. Describe what the code
     does; never "fix" it in the pseudocode. X01 collects these into one register for a rebuild
     (format: `docs/pseudocode/wm/W02-party-raid.md` §9)
3. **Evidence levels** (strongest first): *(captured)*: observed in a real capture
   (`docs/protocol/capture-validation.md`); plain statement = read in the code; *(pdb2017)* = from the 2017
   PDB and not yet confirmed in a 2016 binary; *(db-backup)* = only from the DB backups (`docs/plan/db-backups.md`);
   *(inferred)* = deduced.
   Mark the non-plain ones. Never invent names. Names come from strings in the binaries, the 2017 PDB, the
   client texts, or are clearly marked as ours. If a capture contradicts your reading, the capture wins; re-read the code.
4. **Cross-check with the client** for every client-facing packet: find the client handler (see C01's
   `docs/knowledge/C01.md` once it exists) and record what the client does with each field and error code.
   Error/result codes are resolved with `docs/protocol/client-error-codes.json`.
5. **Shared files are append-by-file, never edit-in-place:**
   - names you discover → `tools/protocol-re/names/<bin>/<ID>.json` (`{"FUN_…": "Name", "DAT_…": "g_Name"}`)
   - verified packet layouts → `docs/protocol/annotations/<ID>.json` (same schema as `annotations.json`)
   - facts for others → `docs/knowledge/<ID>.md`
   Only your own item's files. Then run `tools/protocol-re/regen.sh`.
6. **Progress log:** keep `docs/plan/status/<ID>.md` current (done / in progress / remaining, with handler
   lists). A later session must be able to resume from it alone. Update it before you run low on context.
7. Do not modify the binaries, `re-data/exports/*/decomp.c`, or another item's output files.
