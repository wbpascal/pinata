#!/usr/bin/env python3
"""X02 part 10: what `coverage.py <ID>` reports for the items without a review part, and what it cannot see.

usage: python3 -I docs/plan/status/X02-cov.py items        per-item table (tool depth 3, depth 6, no depth limit)
       python3 -I docs/plan/status/X02-cov.py weak         reachable functions cited only in lists / open-point sections
       python3 -I docs/plan/status/X02-cov.py rest [n]     per binary: functions no doc cites at all (n largest, PDB names)
       python3 -I docs/plan/status/X02-cov.py game <bin> [n]   uncited functions with a PDB class name (`Class::Method`), per class + n largest
       python3 -I docs/plan/status/X02-cov.py who <ID>     handlers of <ID> its own docs do not cite: which item cites them

Reuses tools/protocol-re/coverage.py (same reach rules: HUB, TINY, LIB, registered handlers not expanded).
"""
import os, re, sys, importlib.util, collections
R = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../.."))
spec = importlib.util.spec_from_file_location("coverage", f"{R}/tools/protocol-re/coverage.py")
cv = importlib.util.module_from_spec(spec); spec.loader.exec_module(cv)
IDS = "C01 C02 D01 D02 L00 P01 P03 W01 W02 Z01 Z02 Z03 Z04 Z05 Z07 Z08".split()
its = cv.items(); cit = cv.cited(its); _bins = {}
def B(b):
    if b not in _bins: _bins[b] = cv.Bin(b)
    return _bins[b]
def pdbnames(b):
    p = f"{cv.E}/{b}-pdb/decomp.c"
    if not os.path.exists(p): return {}
    return dict(re.findall(r"^//==== FUNC ([0-9a-f]{8}) (\S+)", open(p, errors="replace").read(), re.M))
def measure(iid, depth):
    cv.DEPTH = depth
    it = its[iid]
    return cv.measure(iid, it, {b: B(b) for b in it["handlers"]}, cit)

def cmd_items():
    print("| Item | Handlers cited by the item | Reachable, depth 3 | Gaps | Reachable, depth 6 | Gaps | Reachable, no limit | Gaps |")
    print("|---|---|---|---|---|---|---|---|")
    allg = {}
    for iid in IDS:
        if not its.get(iid, {}).get("handlers"):
            print(f"| {iid} | no scope table | – | – | – | – | – | – |"); continue
        row = []
        for d in (3, 6, 99):
            r = measure(iid, d); row.append(r)
        allg[iid] = row[2]["gaps"]
        print(f"| {iid} | {row[0]['hdoc']}/{row[0]['h']} | " + " | ".join(f"{r['n']} | {len(r['gaps'])}" for r in row) + " |")
    for iid, g in allg.items():
        if not g: continue
        nm = {}
        print(f"\n{iid}: {len(g)} uncited functions below depth 3 (largest first):")
        for b, a, parent in sorted(g, key=lambda x: -B(x[0]).size[x[1]]):
            nm.setdefault(b, pdbnames(b))
            print(f"  {b} FUN_{a} {B(b).size[a]} lines {nm[b].get(a, '')} <- FUN_{parent}")

def sections():
    """addr -> list of (item, doc, heading, kind) for every citation; kind: 'at' (@ FUN_), 'list' (line with >= 5 addresses), 'text'."""
    out = collections.defaultdict(list)
    for iid, p in cv.docs():
        head = ""
        for line in open(p, encoding="utf-8", errors="replace"):
            if line.startswith("#"): head = line.strip("# \n")
            ads = cv.ADDR.findall(line)
            if not ads: continue
            for a in set(ads):
                kind = "at" if re.search(r"@ `?(?:FUN_)?" + a, line) or (line.startswith("#") ) else "list" if len(set(ads)) >= 5 else "text"
                out[a].append((iid, os.path.basename(p), head, kind))
    return out
OPEN = re.compile(r"not reconstructed|uncertain|coverage boundary|open (questions|points)|remaining|not covered", re.I)

def cmd_weak():
    sec = sections()
    print("| Item | Reachable (depth 3) | Cited with `@` or in a heading | Text only | List lines only | Only under an open-points heading |")
    print("|---|---|---|---|---|---|")
    detail = []
    for iid in IDS:
        it = its.get(iid, {})
        if not it.get("handlers"): continue
        cv.DEPTH = 3
        c = collections.Counter()
        for b, hs in it["handlers"].items():
            fam = {i for i in its if b in its[i]["bins"]}
            for a, parent in B(b).reach(hs).items():
                if parent is None or B(b).size.get(a, 0) < cv.TINY or B(b).indeg.get(a, 0) > cv.HUB or a in B(b).registered or a in B(b).lib: continue
                cs = [x for x in sec.get(a, []) if x[0] in fam]
                if not cs: c["none"] += 1; continue
                if all(OPEN.search(x[2]) for x in cs): k = "open"
                elif any(x[3] == "at" for x in cs): k = "at"
                elif any(x[3] == "text" for x in cs): k = "text"
                else: k = "list"
                c[k] += 1
                if k in ("open", "list"): detail.append((iid, b, a, B(b).size[a], k, sorted({x[1] + ' "' + x[2][:40] + '"' for x in cs})[:2]))
        n = sum(c.values())
        print(f"| {iid} | {n} | {c['at']} | {c['text']} | {c['list']} | {c['open']} |")
    nm = {}
    print()
    for iid, b, a, sz, k, where in sorted(detail, key=lambda x: (x[0], -x[3])):
        nm.setdefault(b, pdbnames(b))
        print(f"{iid} {b} FUN_{a} {sz} lines {k} {nm[b].get(a, '')} :: {'; '.join(where)}")

def cmd_rest(n=15):
    print("| Binary | Functions (≥ 6 lines, not library) | Cited by some doc | Not cited | Lines not cited / all |")
    print("|---|---|---|---|---|")
    tops = {}
    for b in cv.SERVER_BINS:
        bb = B(b); anyone = set().union(*cit.get(b, {}).values())
        fs = [a for a in bb.size if bb.size[a] >= cv.TINY and a not in bb.lib]
        un = [a for a in fs if a not in anyone]
        print(f"| {b} | {len(fs)} | {len(fs) - len(un)} | {len(un)} | {sum(bb.size[a] for a in un)} / {sum(bb.size[a] for a in fs)} |")
        tops[b] = sorted(un, key=lambda a: -bb.size[a])
    for b, un in tops.items():
        nm = pdbnames(b)
        cls = collections.Counter()
        for a in un:
            x = nm.get(a, "")
            cls[x.rsplit("::", 1)[0] if "::" in x else ("(free function)" if x and not x.startswith("FUN_") else "(no name)")] += B(b).size[a]
        print(f"\n{b}: classes by uncited lines: " + ", ".join(f"{k} {v}" for k, v in cls.most_common(12)))
        for a in un[:n]: print(f"  FUN_{a} {B(b).size[a]} lines {nm.get(a, '')} (callers {B(b).indeg.get(a, 0)})")

def cmd_game(b, n=40):
    bb = B(b); nm = pdbnames(b); anyone = set().union(*cit[b].values())
    allf = [a for a in bb.size if bb.size[a] >= cv.TINY and a not in bb.lib and "::" in nm.get(a, "") and not nm[a].startswith("TiXml")]
    un = [a for a in allf if a not in anyone]
    c, l = collections.Counter(), collections.Counter()
    for a in un:
        k = nm[a].rsplit("::", 1)[0]; c[k] += 1; l[k] += bb.size[a]
    print(f"{b}: {len(allf)} class-named functions, {len(un)} not cited ({sum(bb.size[a] for a in un)} of {sum(bb.size[a] for a in allf)} lines); "
          f"{sum(1 for a in un if bb.indeg.get(a, 0) == 0)} of them have no direct caller (virtual / table-dispatched)")
    print("| Class | Functions not cited | Lines |\n|---|---|---|")
    for k, v in l.most_common(25): print(f"| `{k}` | {c[k]} | {v} |")
    if len(l) > 25: print(f"| ({len(l) - 25} more classes) | {sum(c[k] for k, _ in l.most_common()[25:])} | {sum(v for _, v in l.most_common()[25:])} |")
    for a in sorted(un, key=lambda a: -bb.size[a])[:n]: print(f"FUN_{a} {bb.size[a]} {nm[a]} callers {bb.indeg.get(a, 0)}")

def cmd_who(iid):
    for b, hs in its[iid]["handlers"].items():
        own = cit.get(b, {}).get(iid, set()); c = collections.Counter(); none = []
        for a in sorted(hs - own):
            w = sorted(i for i, s in cit[b].items() if a in s and i != "X01")
            c[" ".join(w) or "nobody"] += 1
            if not w: none.append(a)
        print(b, dict(c), none)

if __name__ == "__main__":
    a = sys.argv[1:] or ["items"]
    {"items": cmd_items, "weak": cmd_weak, "rest": lambda: cmd_rest(int(a[1]) if len(a) > 1 else 15), "who": lambda: cmd_who(a[1]),
     "game": lambda: cmd_game(a[1], int(a[2]) if len(a) > 2 else 40)}[a[0]]()
