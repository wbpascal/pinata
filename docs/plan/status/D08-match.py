#!/usr/bin/env python3
"""D08: match functions of two DB-server exports by identical normalized decompiled body.

usage (repo root): python3 -I docs/plan/status/D08-match.py <bin-a> <bin-b> [lo hi]
  prints per function of <bin-a> (in [lo, hi), hex): address, lines, PDB name from <bin-a>-pdb, matching address(es) of <bin-b>
  ("-" = no identical body; several = identical-code folds in <bin-b>). Example: account gamelog 401000 41b000"""
import re, sys, collections, os
sys.path.insert(0, os.path.dirname(__file__))
E = "re-data/exports"
def load(p):
    d = {}; cur=None; buf=[]
    for line in open(p, errors="replace"):
        m = re.match(r"^//==== FUNC ([0-9a-f]{8}) (\S+)", line)
        if m:
            if cur: d[cur] = "".join(buf)
            cur = m.group(1); buf=[]
        else: buf.append(line)
    if cur: d[cur] = "".join(buf)
    return d
def names(p):
    return dict(re.findall(r"^//==== FUNC ([0-9a-f]{8}) (\S+)", open(p, errors="replace").read(), re.M))
def norm(s):
    s = re.sub(r"//.*", "", s)
    s = re.sub(r"\b(FUN|DAT|LAB|PTR|switchD|caseD|s|u|_s|thunk_FUN)_[0-9A-Za-z_]+", "X", s)
    s = re.sub(r"0x4[0-9a-f]{5}\b", "A", s)
    s = re.sub(r"0x6[0-9a-f]{5}\b", "A", s)
    s = re.sub(r"\b(local|uVar|iVar|pcVar|bVar|pvVar|puVar|piVar|cVar|in_stack|pSVar|pCVar|this_|unaff|extraout|DVar|sVar|lVar|ppVar|uStack|iStack|auStack|pIVar|BVar|IVar|SVar|param)[0-9a-zA-Z_]*", "V", s)
    s = re.sub(r"\s+", " ", s)
    return s.strip()
a, b = sys.argv[1], sys.argv[2]
lo = int(sys.argv[3], 16) if len(sys.argv) > 3 else 0; hi = int(sys.argv[4], 16) if len(sys.argv) > 4 else 1<<32
A = load(f"{E}/{a}/decomp.c"); B = load(f"{E}/{b}/decomp.c")
an = names(f"{E}/{a}-pdb/decomp.c") if os.path.exists(f"{E}/{a}-pdb/decomp.c") else {}
idx = collections.defaultdict(list)
for addr, body in B.items(): idx[norm(body)].append(addr)
for addr in sorted(A):
    if not (lo <= int(addr, 16) < hi): continue
    n = norm(A[addr]); lines = A[addr].count("\n")
    m = idx.get(n, [])
    print(f"{addr}\t{lines}\t{an.get(addr,'?')}\t{','.join(m) if m else '-'}")
