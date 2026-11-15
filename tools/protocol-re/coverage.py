#!/usr/bin/env python3
"""Coverage of a work item: which functions reachable from its scope handlers no doc cites yet.

usage: coverage.py <ID> [--all]     summary + uncovered functions (the review step's gap list)
       coverage.py --overview      rewrite docs/plan/progress.md (per server component; derived only from the tree)

Reachable = functions referenced (FUN_ tokens in decomp.c) up to DEPTH calls deep from the item's scope handlers, same
binary. Deeper code is mostly shared infrastructure (map iteration, Lua VM) that belongs to the core items.
Not expanded: functions referenced by more than HUB others (shared utilities, containers, logging) and handlers
registered for other items. Covered = cited as FUN_xxxxxxxx (or the bare 8-digit address) in any doc of an item whose scope includes that binary.
Functions shorter than TINY lines are traversed but not counted (accessors, thunks). Library code (LIB, matched on the
PDB name where a <bin>-pdb export exists) is neither expanded nor counted.
"""
import glob, json, os, re, sys
from collections import deque

R = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
E, ITEMS, HUB, TINY, DEPTH = f"{R}/re-data/exports", f"{R}/docs/plan/items", 25, 6, 3
SERVER_BINS = ["login", "wm", "zone", "account", "accountlog", "character", "gamelog"]
FUN = re.compile(r"FUN_([0-9a-f]{8})")
ADDR = re.compile(r"(?<![0-9A-Za-z_])(?:FUN_)?([0-9a-f]{8})(?![0-9A-Za-z])")  # docs also cite "0063d070" in address lists
# library code by its PDB name (<bin>-pdb export): STL / container templates, CRT, compiler-generated, packet struct copies
LIB = re.compile(r"^(std::|stdext::|List<|ListFunctionCall<|_|`|PROTO_\w*::operator=$)")


def items():
    """Item ID -> {order, bins, handlers{bin: set(addr)}, title} parsed from the generated plan files."""
    order = [s[0] for s in json.load(open(f"{ITEMS}/_summary.json"))]
    out = {}
    for i, iid in enumerate(order):
        txt = open(f"{ITEMS}/{iid}.md").read()
        hs, cur = {}, None
        for line in txt.splitlines():
            m = re.match(r"### `(\w+)` ·", line)
            if m: cur = m.group(1); hs.setdefault(cur, set()); continue
            m = re.match(r"\| `0x[0-9a-f]+` .*\| `FUN_([0-9a-f]{8})` \|", line)
            if m and cur: hs[cur].add(m.group(1))
        out[iid] = dict(order=i, handlers=hs, bins=set(hs) or set(SERVER_BINS),
                        title=re.search(r"^# \S+: (.*)$", txt, re.M).group(1))
    out.setdefault("L00", dict(order=-1, handlers={}, bins={"login"}, title="Login server"))
    return out


def docs():
    """(item ID, path) for every pseudocode and knowledge doc. The item is the file-name prefix."""
    for p in glob.glob(f"{R}/docs/pseudocode/**/*.md", recursive=True) + glob.glob(f"{R}/docs/knowledge/*.md"):
        b = os.path.basename(p)
        m = re.match(r"([A-Z]\d\d)\b", b)
        iid = m.group(1) if m else "L00" if b == "login-server.md" else "X01" if b == "README.md" else None
        if iid: yield iid, p


class Bin:
    def __init__(self, name):
        src = open(f"{E}/{name}/decomp.c", encoding="utf-8", errors="replace").read()
        self.calls, self.size = {}, {}
        for m in re.finditer(r"^//==== FUNC ([0-9a-f]{8}) \S+\n(.*?)(?=^//==== FUNC |\Z)", src, re.S | re.M):
            a = m.group(1)
            self.calls[a] = set(FUN.findall(m.group(2))) - {a}
            self.size[a] = m.group(2).count("\n")
        self.indeg = {}
        for cs in self.calls.values():
            for c in cs: self.indeg[c] = self.indeg.get(c, 0) + 1
        H = json.load(open(f"{E}/{name}/handlers.json"))
        self.registered = {e["handler"][-8:] for t in H["tables"] for e in t["entries"]}
        pdb = f"{E}/{name}-pdb/decomp.c"
        self.lib = set() if not os.path.exists(pdb) else {
            m.group(1) for m in re.finditer(r"^//==== FUNC ([0-9a-f]{8}) (\S+)", open(pdb, errors="replace").read(), re.M)
            if LIB.match(m.group(2))}
        self.names = {}
        for f in sorted(glob.glob(f"{R}/tools/protocol-re/names/{name}/*.json")):
            self.names.update({k[4:]: v for k, v in json.load(open(f)).items() if k.startswith("FUN_")})

    def reach(self, roots):
        """addr -> parent (None for roots); BFS so the parent chain is a shortest path from a handler."""
        seen, q = {r: None for r in roots if r in self.calls}, deque((r, 0) for r in roots)
        while q:
            a, d = q.popleft()
            if d == DEPTH or a not in roots and (self.indeg.get(a, 0) > HUB or a in self.registered or a in self.lib): continue
            for c in sorted(self.calls.get(a, ())):
                if c in self.calls and c not in seen:
                    seen[c] = a; q.append((c, d + 1))
        return seen


def cited(its):
    """bin -> item -> set(addr) cited in that item's docs (only for the bins in the item's scope)."""
    out = {}
    for iid, p in docs():
        addrs = set(ADDR.findall(open(p, encoding="utf-8", errors="replace").read()))
        for b in its.get(iid, {}).get("bins", SERVER_BINS):
            out.setdefault(b, {}).setdefault(iid, set()).update(addrs)
    return out


def measure(iid, it, bins, cit):
    """Counts for one item, plus its uncovered functions [(bin, addr, parent)]."""
    r = dict(h=0, hdoc=0, n=0, own=0, other=0, gaps=[])
    for b, hs in it["handlers"].items():
        B = bins[b]
        own = cit.get(b, {}).get(iid, set())
        anyone = set().union(*cit.get(b, {}).values()) if cit.get(b) else set()
        r["h"] += len(hs); r["hdoc"] += len(hs & own)
        for a, parent in B.reach(hs).items():
            if parent is None or B.size.get(a, 0) < TINY or B.indeg.get(a, 0) > HUB or a in B.registered or a in B.lib:
                continue
            r["n"] += 1
            if a in own: r["own"] += 1
            elif a in anyone: r["other"] += 1
            else: r["gaps"].append((b, a, parent))
    return r


def path(B, reach, a):
    p = []
    while a is not None: p.append(B.names.get(a, "FUN_" + a)); a = reach[a]
    return " <- ".join(p[:4]) + (" <- …" if len(p) > 4 else "")


def pct(x, n): return f"{100 * x // n} %" if n else "–"


COMPONENTS = {"login": "Login server", "wm": "World manager", "zone": "Zone server", "account": "Account DB server",
              "accountlog": "AccountLog DB server", "character": "Character DB server", "gamelog": "GameLog DB server"}


def state(iid):
    """done / started / open, from the status file's first lines (or the item's docs existing)."""
    p = f"{R}/docs/plan/status/{iid}.md"
    if os.path.exists(p):
        return "done" if re.search(r"\bdone\b", "".join(open(p).readlines()[:8]), re.I) else "started"
    return "started" if any(i == iid for i, _ in docs()) else "open"


def bar(x, n, w=20):
    f = round(w * x / n) if n else 0
    return "█" * f + "░" * (w - f)


def overview(its):
    """docs/plan/progress.md: per server component, over all its registered handlers (independent of item scopes)."""
    cit, mark = cited(its), {"done": "✓", "started": "◐", "open": "·"}
    owner = {}  # component -> [item IDs]; items without scope by ID letter, the rest are cross-cutting
    for iid, it in sorted(its.items(), key=lambda kv: (kv[0][0] != "L", kv[1]["order"])):
        comps = list(it["handlers"]) or {"L": ["login"], "W": ["wm"], "Z": ["zone"]}.get(iid[0], ["other"])
        for c in comps: owner.setdefault(c, []).append(iid)
    rows, T = [], [0, 0, 0, 0]
    for b, label in COMPONENTS.items():
        B = Bin(b)
        anyone = set().union(*cit.get(b, {}).values()) if cit.get(b) else set()
        hs = B.registered & set(B.calls)
        n = cov = 0
        for a, parent in B.reach(hs).items():
            if parent is None or B.size.get(a, 0) < TINY or B.indeg.get(a, 0) > HUB or a in B.registered or a in B.lib:
                continue
            n += 1; cov += a in anyone
        hd = len(hs & anyone)
        for i, v in enumerate((hd, len(hs), cov, n)): T[i] += v
        items_ = " ".join(f"{i}{mark[state(i)]}" for i in owner.get(b, []))
        rows.append(f"| {label} | `{bar(hd + cov, len(hs) + n)}` | {hd}/{len(hs)} ({pct(hd, len(hs))}) "
                    f"| {cov}/{n} ({pct(cov, n)}) | {n - cov} | {items_} |")
    rows.append(f"| **All servers** | `{bar(T[0] + T[2], T[1] + T[3])}` | **{T[0]}/{T[1]} ({pct(T[0], T[1])})** "
                f"| **{T[2]}/{T[3]} ({pct(T[2], T[3])})** | {T[3] - T[2]} | |")
    other = " ".join(f"{i}{mark[state(i)]}" for i in owner.get("other", []))
    open(f"{R}/docs/plan/progress.md", "w").write(
        "# Progress per server component\n\n"
        "Generated by `tools/protocol-re/coverage.py --overview` (part of `regen.sh`) from the docs in the tree. Do not edit "
        "or resolve merge conflicts by hand: run the command again; the result is then correct for the merged docs.\n\n"
        "| Component | Progress | Handlers documented | Functions covered | Gaps | Items |\n"
        "|---|---|---|---|---|---|\n" + "\n".join(rows) + "\n\n"
        f"Cross-cutting items (client, captures, databases, integration): {other}\n\n"
        "Items: ✓ done · ◐ started · `·` not started (from `docs/plan/status/<ID>.md`).\n\n"
        "- **Handlers documented**: registered packet handlers of that server whose `FUN_` some doc cites.\n"
        f"- **Functions covered**: functions up to {DEPTH} calls below those handlers that some doc cites (not counted: "
        f"shared helpers with more than {HUB} callers, functions under {TINY} lines, STL / CRT / compiler-generated code by its PDB name). Calls through vtables are not "
        "seen, so these counts are a lower bound of the real code size.\n"
        "- **Progress bar**: handlers + functions together. Per work item: `coverage.py <ID>` lists its gaps.\n")
    print(f"progress.md: handlers {T[0]}/{T[1]}, functions {T[2]}/{T[3]}")


def main():
    its = items()
    if sys.argv[1:] == ["--overview"]:
        overview(its)
        return
    if not sys.argv[1:] or sys.argv[1] not in its: sys.exit(__doc__)
    iid, it = sys.argv[1], its[sys.argv[1]]
    if not it["handlers"]: sys.exit(f"{iid} has no scope table; coverage does not apply")
    bins = {b: Bin(b) for b in it["handlers"]}
    cit = cited(its)
    r = measure(iid, it, bins, cit)
    print(f"{iid}: handlers documented {r['hdoc']}/{r['h']}; reachable {r['n']}: own {r['own']}, other items {r['other']}, "
          f"gaps {len(r['gaps'])} ({pct(r['own'] + r['other'], r['n'])} covered)")
    for b, hs in it["handlers"].items():
        miss = sorted(hs - cit.get(b, {}).get(iid, set()))
        if miss: print(f"undocumented handlers ({b}): " + " ".join("FUN_" + a for a in miss))
    gaps = sorted(r["gaps"], key=lambda g: -bins[g[0]].size[g[1]])
    limit = None if "--all" in sys.argv else 40
    if gaps: print(f"\ngaps, largest first{'' if limit is None or len(gaps) <= limit else f' (first {limit}; --all for every one)'}:")
    reach = {b: bins[b].reach(hs) for b, hs in it["handlers"].items()}
    for b, a, _ in gaps[:limit]:
        print(f"  {b} FUN_{a} {bins[b].size[a]:>4} lines  {path(bins[b], reach[b], a)}")


if __name__ == "__main__":
    main()
