# Review task for a finished work item

Used by step 9 of every `docs/plan/items/<ID>.md`. Replace `<ID>` with the item ID. Run it as a fresh-context
subagent of the item's session, or as a separate session started with
"Review work item <ID> as described in `docs/plan/review-prompt.md`".

You are reviewing work item `<ID>`. You did not write it. Find what is missing or wrong, not what is right.
Follow `AGENTS.md` (especially **Context budget**). **Edit nothing except as stated in the last point.**

Read: `docs/plan/items/<ID>.md` (the plan and scope table), the item's output files (the plan's **Output**,
`docs/knowledge/<ID>.md`, `docs/plan/status/<ID>.md`), and the output of
`python3 -I tools/protocol-re/coverage.py <ID> --all`.

Check:

- each coverage gap: in scope and must be documented, or correctly outside (which item covers it)?
- each "Coverage boundary" row: does the named item's plan or scope table really include it? Is the argument sound?
- scope-table handlers, packets, error codes and client cross-checks that are thin or absent
- re-read 5–10 of the item's claims in the code (`clean.py`), preferring *(inferred)* ones and field meanings, and report
  any that the code contradicts

Return a numbered findings list (each: where, what is wrong or missing, evidence). If you run as a separate session
(not a subagent), also append that list to `docs/plan/status/<ID>.md` under a heading "Review findings"; that is the
only file you write.
