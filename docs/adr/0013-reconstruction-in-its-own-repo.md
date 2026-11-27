# The reconstruction lives in its own repository

The Reconstruction (binaries, Ghidra exports, captures, protocol, pseudocode, knowledge, work items and their tools) moved to [`wbpascal/pinata-re`](https://github.com/wbpascal/pinata-re), which is cloned next to this repository as `../pinata-re`. This repository holds only the server, at its root. The two files the server needs from the reconstruction are copied in by `../pinata-re/tools/sync-server.sh`: the original data tables to `original-data/9Data/` (Git LFS) and `docs/protocol/opcodes.json` to `test/fixtures/opcodes.json`. The commit that refreshes a copy names the `pinata-re` commit it came from.

We chose this because the reconstruction made a clone about 1.7 GB of LFS content, needed long paths on Windows and drew server work, of people and agents, into reverse-engineering files. Three alternatives were rejected. A Git submodule would pin the reconstruction to one commit per server commit, but every clone, worktree and CI job would have to initialise it, and a submodule update in every server PR that cites newer findings is churn with no check behind it. A sparse checkout keeps one repository, but its history and LFS objects stay as large as before, and every clone and CI job needs the same sparse setup. A CI checkout of `pinata-re` instead of copied data would make every CI job and a fresh clone depend on a second repository and on its current state; the 245 MB copy makes the tests and the release jobs self-contained.

## Consequences

- Citations in code and docs (`docs/pseudocode/…`, `docs/protocol/…`, `docs/knowledge/…`, `re-data/captures/…`, `tools/protocol-re/…`, item IDs) keep their paths and resolve in `../pinata-re`. They are not links, and nothing checks them.
- The tests and every CI job pass on a clone without `pinata-re`. Converting a capture into a Transcript, reading the original's behaviour and refreshing the copies need it.
- The copies can lag behind `pinata-re`. A change that needs newer data or opcodes runs the sync script in the same PR.
- `pinata` stays the only issue tracker; the work items of the reconstruction keep their own workflow in `pinata-re`.
- The history before the move stays in this repository: the server's files were moved with `git mv`, so `git log --follow` reaches it, and the reconstruction's files remain in the old commits.
