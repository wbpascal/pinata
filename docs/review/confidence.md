# Confidence review (X02)

How far each part of the reconstruction can be trusted, what was re-checked, and what only a capture can settle.
Sources: every pseudocode and knowledge file in the tree, `docs/protocol/capture-validation.md` (P02),
`docs/pseudocode/README.md` §5 (X01's list of superseded statements) and the git history. Corrections that X02 itself
finds go to `docs/knowledge/X02.md` §0; the capture scenarios that follow from the ratings are in
`docs/plan/capture-scenarios.md`.

| § | Content | State |
|---|---|---|
| 1 | Error classes: what went wrong so far, with counts | done (part 1) |
| 2 | Rating of every pseudocode section and knowledge struct table | open (parts 2–3) |
| 3 | Adversarial re-check of the load-bearing claims | open (parts 4–7) |
| 4 | Coverage gaps of items finished without a review part | open (part 10) |

## 1. Error classes

### 1.1 What was collected

| Source | Statements |
|---|---|
| `docs/pseudocode/README.md` §5.1–§5.8 (X01 part 3: every knowledge "Corrections" section, S01 §3.3, P02 batch 1, passages in later items) | 207 rows |
| P02 batch 2 (`docs/knowledge/P02.md` "Corrections", `capture-validation.md` §13), written after X01 collected §5 and missing there | 32 rows |
| **Classified in §1.2** | **239** |
| Bug-register entries a later item changed (README §5.9) plus L00-B6 (P02) | 23 (22 + 1); 7 of them are also rows above |
| Review parts: 35 commits on `docs/pseudocode` / `docs/knowledge` name a review; ten state their count | 103 findings in those ten (8, 17, 10, 8, 12, 9, 7, 8, 15, 9), fixed in place and not classified |

Of the 239 rows, 42 are additions (an open point answered, an *(inferred)* statement confirmed, a rename) and 3 are
decoder fixes. **194 are statements that were wrong or incomplete.**

Three facts about them decide how §2 rates and what §3 re-checks:

- **A plain statement is not a safe statement.** Of the 207 README §5 rows, only 30 superseded statements carried a
  hedge (*(inferred)*, "not traced", "open", "probably"). The other 177 were written as read in the code. The
  evidence level "plain = read in the code" therefore rates **medium** at best (plan rule), and **low** where one of
  the classes below applies.
- **Most errors were found by reading more code, not by captures.** README §5: 132 rows by a later item reading the
  callee or the caller, 32 by D06 re-reading the DB wrappers against both backups, 22 from the 2016 PDBs, 21 from
  captures. Batch 2 added 32 rows from seven short captures (most of them traced back to the code after the capture showed the bytes). So a capture of a path finds what reading
  did not (mostly classes U, T, L, F), and following one more call level finds classes N, S, B, R.
- **Old items carry most of the errors.** Items written before the 2016 PDBs were available (S01, 2026-11-13: L00,
  W01–W04, Z01–Z08, D01–D05) own 166 of the 194 (175 with C01 and P01's README and generated files). The items after it read `<bin>-pdb` exports with official names
  and typed members; their recorded errors are few (Z09 5, Z12 4, W05 4, Z13 1, Z15 1), but they were also tested
  less: nothing later re-read them, and batch 1 / 2 touch them only at the edges.

### 1.2 The classes

Counts: rows of README §5 + rows of P02 batch 2. "Find more" is how §2 detects further instances that nobody has
corrected yet (part 2 turns these into the rating rules).

| Class | Meaning | Count | Examples | Find more |
|---|---|---|---|---|
| **N** name guess | a callee, global or table given a name of ours and then treated as if it did what the name says; the body was not read | 33 (32 + 1) | Z01 §6 `sp_ConnectFromWhere` "asks the WM 0x082A" (sends a GM notice); Z01 §8.4 "tutorial save" (= `SendCoolTimes2DB` 0x4023); Z03 §8.1 `questDiary.MobKill` (= `CT_KillMob`, a title counter); Z03 `g_HitRateScale` (= the start script's security factor) | names of ours (`Xxx_Yyy`, "(ours)") in pre-S01 docs that `docs/knowledge/S01-renames.tsv` maps to an official name with another meaning; a call described in one line with no `@ FUN_` of the callee |
| **B** branch / condition / code | a condition missed, the wrong branch or return value, a result code read wrong | 26 (23 + 3) | Login / WM handlers "ignore" a bad packet (they return 0 and the parser closes the session); Z01 §6 tail of 0x1803 "unconditional" (P02-B4); Z08 0x7C13 codes 0xDC0–0xDC2; D02 0x0844 / 0x10CA "zeros on error" (nothing is sent) | "always", "unconditional", "ignored", "no-op", "returns" in handler text; code lists without the client text; handlers whose `return 0` path was not followed to the parser |
| **F** field meaning | the meaning or unit of a field guessed from its size, position or one value | 24 (20 + 4) | `g_Now` "milliseconds" (0.1 s); 0x0810 "minutes" (seconds); 0x441E "counters" (`time_t` period starts); 0x340A `attrLen` (an offset); 0x180C `always99` (GameLog store type); Z07 §4.1 enum reversed | annotation fields named `unk…`, `?`, or typed differently from `pdb2016-layouts.json`; units in prose ("ms", "minutes") without the divisor's `@ FUN_`; a field explained by one observed value |
| **U** unwritten bytes / missed bug | the wire content assumed clean: uninitialised or stale bytes, length off by one, a missing check not noticed | 18 (10 + 8) | P02-B1 … B21 (0x182A byte, 0x302D / 0x3C08 extra byte, 0x305C 100 stale bytes, WM blobs 2 / 4 bytes too long); Z04 §3.3 party money crash (Z09-B22); 0x2032 gather without a time check | sends from a global or stack buffer with a fixed length; lengths built from a callee's return value; "zeroed" claims; every packet no capture has shown yet |
| **S** offset / member / index | a struct member, vtable slot, table index or capacity misidentified | 17 | Z03 §2 `obj+0x1e78` "ran once" (invalid-position flag); Z03 §6.1 "296 slots" (28); `g_LevelExp` base (off by 8: `nextexp[lv − 1]`); W05 class mask "bit 0 = Fig" (bit n = class n); vt 0xc70 "GM-invincible" | `p+0x…` / `vt 0x…` in pre-S01 docs not listed in `S01-player-offsets.tsv`; indices "± 1"; capacities quoted without the allocating call |
| **D** DB backup version | a procedure body, parameter order or bind taken from the backup that does not match the 2016 call | 16 | `p_Char_Create`, quest filters (`=` not `<>`), `p_Guild_Member_SetGrade`, wedding timers: all w00, not `Character.bak`; `@nRet` bound as input (D06-B8); `usp_GuildTournament_setRegist` does charge the fee | *(db-backup)* statements citing `Character.bak` for one of the 27 procedures D06 §8.5 lists as different; any SQL in D01–D05 not re-read by D06 |
| **R** reachability / caller | live code called dead or dead code called live; the wrong caller or trigger | 13 (10 + 3) | Z03 §3.5 mob melee `so_attack` (dead in 2016); Z02-B5 0x2035 "legacy" (live); `ws_save2worldmanager` "on logout" (only `so_LinkTo`); 0x0806 handler unreachable; 0xBC06 / 0xA001 have no sender; 0x080A is the answer to AccountLog's 0x0809 | "dead", "legacy", "never sent", "no sender", "called on … and …"; paths reached only through a vtable (`coverage.py` does not see them); opcodes with a handler but no sender in any `handlers.json` `sends` |
| **L** layout | field order, width, size, a missing header or prefix | 9 (4 + 5) | 0x0C36 result before handle; 0x0802 six fields; Login → WM 0x0C16 is 10 bytes; `pdb2016-layouts.json` for CharDB ↔ zone packets lacks the 6-byte ref; 0x2802 entry order; 0x7037 three extra bytes | annotation size ≠ PDB struct size (± 6 ref, ± 2 / 4 WM blob tail); server-internal packets about a player without `ref`; raw-header sends (`{len, opLo, opHi}`) |
| **O** opcode identity | the wrong opcode or packet name; a "packet" that is none | 8 (7 + 1) | 0x1002 = LOGINFAIL (REQ + 1 guess); WM 0x1407 sends 0x1413, not 0x1408; W04 0x940A answers with opcode 0x9407; 0x10D2 has two layouts; zone "0x0E0D" is a byte array | names in `handlers.json` without a pdb2016 opcode name; replies built with a raw header; one opcode sent by two functions |
| **C** client not checked | a statement about the client that its handler contradicts, or a client handler said to be missing | 8 | Z07 §5.3 "no handler for 0x1094" (there is one); D04 texts for 0x949 / 0x952 ("DB Error"); Z02 §6.2 0x201C always answered by 0x201D; C01: 0x2011 "ignored" | client statements without a client `FUN_`; error codes whose text was taken from `client-error-codes.json` without reading the handler's own switch |
| **T** order / timing / direction | message order, who sends first, startup order, timing | 7 (4 + 3) | zone seed on accept; heartbeat runs server → client; listeners (OPTool first); W01 §7.2 0x101C send order; per-character updates arrive out of order on four links (P02-B12) | sequences written in prose across two processes; README §2 flows; every "then" between packets of different functions |
| **M** formula | arithmetic read wrong | 4 | Z03 §4.1 stat total (division after every factor, L14 scales the flat part); Z03 §5.6 hit roll (one random number), empower bonus (keep time, not rate); Login token (MD5) | formulas with several factors or `/ 1000`; table index arithmetic; anything the decompiler shows as float or 64-bit math |
| **P** 2017 for 2016 | a 2017 PDB fact used for 2016 | 4 | W04 `MobKillAnnounceType` 0–9 (2016: 0–7); Z05 0x34A9 (2017 struct is truncated); D05 `nType` "2017-only" (they exist in 2016) | *(pdb2017)* markers; `S01.md` §2.3 (differences 2016 vs 2017) |
| **X** bug diagnosis | a register entry withdrawn, superseded or narrowed (counted from README §5.9 + L00-B6: 4 withdrawn, 6 superseded, 9 narrowed, 4 extended) | 23 | W01-B5, D01-B10, D02-B19, L00-B6 are not bugs; Z02-B5 / B12 too strong | bug rows whose effect is *(inferred)* and whose handler has no capture |
| A addition | an open point answered or an inference confirmed; not an error | 42 | | |
| Z decoder | tooling (`pcap_decode.py`, annotation types) | 3 | | |

How the rows map to classes (`n` = the n-th row of that README subsection):

**§5.1:** 1T 2T 3A 4O 5O 6O 7Z
**§5.2:** 1T 2N 3B 4B 5B 6B 7B 8N 9L 10M 11L 12A 13A 14C 15F 16B 17N
**§5.3:** 1N 2B 3B 4B 5B 6F 7X 8A 9A 10O 11F 12N 13C 14N 15A 16F 17F 18O 19A 20U 21P 22N 23A 24S 25L 26B 27F 28R 29A 30P 31S 32T 33S 34S 35O
**§5.4:** 1F 2N 3N 4A 5R 6N 7N 8B 9N 10F 11S 12A 13F 14F 15B 16A 17N 18N 19R 20B 21C 22A 23S 24R 25U 26A 27A 28U 29X 30N
**§5.5:** 1S 2S 3S 4U 5R 6M 7S 8A 9R 10S 11U 12B 13A 14S 15N 16M 17M 18B 19N 20S 21S 22N 23N 24F 25N 26B 27A 28N 29S 30R 31N 32S 33R
**§5.6:** 1U 2N 3A 4A 5U 6X 7U 8N 9N 10F 11S 12A 13N 14P 15U 16F 17F 18N 19F 20A 21C 22A 23N 24R 25A 26A 27A 28F 29F 30A 31N 32B 33A 34B 35B 36X 37N 38A 39B 40A 41F 42N 43A 44A 45F
**§5.7:** 1A 2A 3B 4D 5F 6L 7X 8A 9D 10U 11D 12D 13D 14D 15D 16D 17A 18D 19X 20D 21A 22B 23D 24A 25R 26D 27C 28A 29D 30D 31D 32C 33A 34A 35D 36P 37N
**§5.8:** 1C 2C 3O

P02 batch 2 (order of `docs/knowledge/P02.md` "Corrections", rows not in README §5): L00 0x0C16 **L**; L00-B6 **X**;
D01 0x080A trigger **R**; W04 0x7037 **L**; D02 0x0844 / 0x10CA **B**; D02 P02-B7 … B9 **U**; D02 0x10D2 **O**; W01
blob tails **U**; W01 0x101C order **T**; Z01 `ws_save2worldmanager` list and callers **R**; Z01 0x180C `always99`
**F**; link round robin **T**; W03 0x987A **U**; Z13 `PacketOrder` **U**; Z04 `attrLen` / `bind` **F**; Z05 0x305C
**U**; Z05 0x3C08 **U**; D03 0x0446 **U**; S01 layouts without ref (two rows) **L L**; Z03 death "by the dead bit"
**F**; Z03 SkillDamage flag **U**; Z03 0x240C / 0x2452 types **Z**; Z09 hunt-log flush **B**; Z04 0x500B recipients
**B**; Z01 0x4001 / 0x401A **F**; D02 0x400B **L**; Z02 `FUN_005cc2a0` **N**; Z12 0x4025 sender **A**; P02's own WM
pass timing **T** and 0x10B3 "not sent" **R**; decoder struct types **Z**.

### 1.3 Errors per owning item

Owner = the first item named in the row's "Older place". Errors = all classes except A and Z.

| Owner | Errors | By class |
|---|---|---|
| Z03 | 28 | N6 S9 F2 B3 R2 M3 U3 |
| W01 | 20 | N4 F4 O2 B4 T1 C1 P1 U2 X1 |
| L00 | 17 | N3 F1 L3 B6 T1 M1 C1 X1 |
| Z01 | 15 | N5 S1 F5 B1 R2 T1 |
| D02 | 15 | L1 O1 B1 D9 U2 X1 |
| Z02 | 13 | N4 S1 B2 R2 C1 U2 X1 |
| Z04 | 11 | N3 S1 F2 B1 U3 X1 |
| Z07 | 7 | N2 F3 R1 C1 |
| Z08 | 7 | N1 F2 B3 X1 |
| P01 (README, generated files) | 6 | F1 O3 T2 |
| W03 | 6 | S1 F1 L1 B1 R1 U1 |
| D01 | 6 | F1 L1 B1 R1 D1 X1 |
| Z05 | 5 | N1 P1 U3 |
| Z09 | 5 | N2 F1 B2 |
| D03 | 5 | B1 R1 D2 U1 |
| D04 | 5 | C2 D3 |
| W05 | 4 | S3 T1 |
| Z12 | 4 | N1 S1 R2 |
| W04 | 3 | L1 O1 P1 |
| D05 | 3 | N1 D1 P1 |
| C01 | 3 | O1 C2 |
| S01, P02 | 2 each | L2; R1 T1 |
| Z13, Z15 | 1 each | U1; F1 |

No recorded error: W02, Z06, Z10, Z11, Z14, Z16–Z30 (except the rows above), D06, D07, S02, L01. For these the
absence means "not re-read by anyone", not "confirmed": P02 lists what the captures confirm per item
(`capture-validation.md` §13, last paragraph), and that is the only positive evidence.

### 1.4 What follows for the ratings (§2) and the re-check (§3)

1. **Rating rule.** *high* needs a capture row (`capture-validation.md`) or a cited client handler that uses the
   fields. *medium* = read in code, none of the classes applies. *low* = *(inferred)* / *(pdb2017)* only, or a class
   applies by its "Find more" test. A section a later item superseded (README §5, P02) is rated by the corrected
   statement and points to it.
2. **Pre-S01 documents start one step lower for names and offsets** (classes N and S, 50 of 194): L00, W01–W04,
   Z01–Z08, D01–D05. A call or member they name is *low* until an official name (`S01-renames.tsv`,
   `S01-player-offsets.tsv`) or a later item's § confirms it. Character and GameLog have no PDB at all: every
   name in D02–D05 and D07 is ours.
3. **Wire content is not trusted without a capture** (class U, 18 rows; 16 of the 21 P02 bugs are unwritten bytes or a wrong length): a layout read from a
   send site gives the fields, not the unwritten bytes or the length. A client-facing or link packet that no capture
   shows stays *medium* even when the client handler agrees.
4. **Re-check order for §3** (worst first, by errors found per claim that other items cite): Z03 (28; S and N: the
   combat context and abstate tables), W01 (20; B and F: session states, hand-over), L00 (17; B: return paths),
   Z01 (15; N and F: login burst, saves), D02 (15; D: procedure versions), Z02 and Z04. Inside each, first the
   statements that match a "Find more" test and that §5 has not already corrected.
5. **Scenarios** (`capture-scenarios.md`) aim at the classes only a capture settles: U (every packet not yet seen),
   T (order across processes), L (sizes), F (units and enum values, with known UI values), C (which text the client
   shows), and B where a result code can be forced by a DB or SHN setup.

## 2. Ratings per document

Open (parts 2–3).

## 3. Adversarial re-check

Open (parts 4–7).

## 4. Coverage gaps of items without a review part

Open (part 10). Status files without a "Review" section: C01, C02, D01, D02, L00, P01, P03, W01, W02, Z01, Z02,
Z03, Z04, Z05, Z07, Z08.
