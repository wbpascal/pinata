# Delegating batch work to DeepSeek

Goal: lower the cost of a work item without lowering its quality. The session working the item (Opus) keeps every
judgement; DeepSeek (`deepseek/deepseek-flash` via `omp`) drafts bulk material from input the script prepares. Background:
the W03 / D04 comparison (DeepSeek alone vs Opus alone). DeepSeek's errors there were interpretive: bugs built on
Ghidra's `void` typing, inverted conditions, misread procedure codes, invented opcode names, swapped layouts. Its
coverage of plain packets and helpers was good.

## What to hand off, what to keep

| `deepseek.py` task | Use for | Measured (W03 test) | Verify by |
|---|---|---|---|
| `annotate --ops …` | layout drafts for many packets (acks, DB requests, zone messages) | 6 packets, $0.019, 2 min, all offsets right | the built-in lint (names, PDB offsets); spot-check the send site of any packet with no PDB struct |
| `helpers --funcs …` | one-line behaviour of plumbing functions (helper index, §"helper inventory") | 7 functions, $0.006, behaviours right | read the line; names are kept only if they occur in strings / known names |
| `bugscan --funcs …` | a candidate list, nothing more | 13 candidates, $0.026: 1 real, several wrong, missed a real one | check every candidate in the code before it enters the bug table; never rely on it for completeness |

Keep with Opus: handler pseudocode where control flow matters (conditions, error paths, rollbacks), the bug register
(what is a bug, effect, intent), cross-item questions, final names, the coverage-boundary argument.

## How

```bash
T=tools/protocol-re; S=<scratchpad>
python3 -I $T/deepseek.py annotate --bin wm --ops 0x7408,0x740f,0x7411 --out $S/ann.json   # prints lint findings of the draft
python3 -I $T/deepseek.py helpers  --bin wm --funcs FUN_0044e5f9,FUN_00445660 --out $S/helpers.tsv
python3 -I $T/deepseek.py bugscan  --bin wm --funcs FUN_0041d380,FUN_00445660 --out $S/bugs.tsv
python3 -I $T/lint_item.py W03                                                              # the whole item, before "done"
```

- Batch large: one call per ~60 KB of input (`--chunk`), 4 in parallel (`--jobs`). A whole item's packets fit in a few calls.
- Write drafts to the scratchpad, never into item files. Copy entries only after they pass the lint and your check;
  rename fields to the PDB names where the draft used `-`.
- `deepseek.py` disables omp's model fallback and fails if any answer did not come from DeepSeek; a failure costs nothing extra.
  DeepSeek gets no tools beyond `read` and no repo context: the script sends everything it needs.

## lint_item.py

Catches, by script, every DeepSeek error found by hand in W03/D04 and a few more (0 findings on the Opus outputs):

- `names`: annotation opcode name differs from `opcodes.json` (names from the binaries / PDB) or is confirmed nowhere.
- `layout`: a field starts inside a PDB field, or a PDB field name sits at a different offset (swap, off-by-one); tried with and
  without the 6-byte header. Name-only differences are WARN.
- `void`: a doc line says a callee returns void / nothing / leftover EAX, but the callee's assembly writes EAX before `ret`.
- `bugs`: gaps in bug IDs, fewer inline `(original bug)` tags than bug rows.

Limits: layouts are checked only where a 2017 PDB struct exists (2016 may differ; a real 2016 difference shows as a false
ERROR: confirm in the code and say so in the annotation note). Free-text claims other than "void" are not checked.

## Open question

Cost savings are not measured yet. Measure on the next unstarted item of similar size: Opus alone vs Opus + `deepseek.py`
for annotations and helper lines, compare total cost (omp prints DeepSeek's; Claude's from the session) and rerun the W03-style
checks (bug rows vs asm, annotation diff).
