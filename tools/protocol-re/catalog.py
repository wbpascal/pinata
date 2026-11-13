"""Merge per-server handlers.json into one opcode catalog + markdown tables.
usage: python3 -I catalog.py <outdir> <docs_dir>
"""
import json, sys
from collections import Counter, defaultdict

out, docs = sys.argv[1], sys.argv[2]
SERVERS = ["login", "wm", "zone", "account", "accountlog", "character", "gamelog"]
CLIENT = {("login", "CParserClient"), ("wm", "CParserClient"), ("zone", "ShineObjectClass::ShinePlayer")}
import os
srcdir = {s: (f"{out}2/{s}" if os.path.exists(f"{out}2/{s}/handlers.json") else f"{out}/{s}") for s in SERVERS}
H = {s: json.load(open(f"{srcdir[s]}/handlers.json")) for s in SERVERS}
print(srcdir)

names = defaultdict(Counter)   # op -> name -> score
recv = defaultdict(list)       # op -> [(server, parser, handler)]
for s, j in H.items():
    for t in j["tables"]:
        for e in t["entries"]:
            recv[e["op"]].append((s, t["parser"], e["handler"]))
            if e.get("name"):
                names[e["op"]][e["name"]] += 10 if e.get("name_src") == "handler" else 3

# send-site literals: a function that sends exactly one opcode and mentions exactly one NC name
# that is no handler's own name -> that name probably belongs to the sent opcode
import re as _re
_hnames = {n for c in names.values() for n, k in c.items() if k >= 10}
sent_lit = defaultdict(Counter)
for s in SERVERS:
    lp = f"{srcdir[s]}/layouts.json"
    if not os.path.exists(lp): continue
    L = json.load(open(lp))
    by_func = defaultdict(set)
    for op_s, sites in L["s2c"].items():
        for site in sites: by_func[site["func"]].add(int(op_s, 16))
    body_of = {}
    for m in _re.finditer(r"^//==== FUNC ([0-9a-f]{8}) \S+\n(.*?)(?=^//==== FUNC |\Z)",
                          open(f"{srcdir[s]}/decomp.c", errors="replace").read(), _re.S | _re.M):
        if f"FUN_{m.group(1)}" in by_func: body_of[f"FUN_{m.group(1)}"] = m.group(2)
    for f, ops in by_func.items():
        lits = {n for n in _re.findall(r'"[^"]*?(NC_[A-Z0-9_]*[A-Z0-9])', body_of.get(f, "")) if n not in _hnames}
        if len(ops) == 1 and len(lits) == 1:
            sent_lit[next(iter(ops))][lits.pop()] += 1

# client side (work item C01): which client function handles each opcode, and names the client itself proves
_chp = os.path.join(out, "..", "client-handlers.json")
CH = {int(k, 16): v for k, v in json.load(open(_chp)).items()} if os.path.exists(_chp) else {}


# 2017 client PDB (work item C02): official enum names, ranked below handler/client names and above
# inferred/log-literal names; pdb-name-verdicts.json settles the conflicts checked in the 2016 code
_pp = os.path.join(docs, "pdb-layouts.json")
PDBE = {int(k, 16): v for k, v in json.load(open(_pp))["opcodes"].items()} if os.path.exists(_pp) else {}
PDB = {op: v["name"] for op, v in PDBE.items()}
_vp = os.path.join(docs, "pdb-name-verdicts.json")
VERDICT = {int(k, 16): v for k, v in json.load(open(_vp))["verdicts"].items()} if os.path.exists(_vp) else {}


# 2016 server PDBs (work item S01, Files/Server/NA2016 = same builds): official enum names of the exact build,
# ranked above every other source; a name the 2016 code itself uses wins when it is one of the value's enum aliases
_p16 = os.path.join(docs, "pdb2016-layouts.json")
PDB16E = {int(k, 16): v for k, v in json.load(open(_p16))["opcodes"].items()} if os.path.exists(_p16) else {}


def codename(op):
    """name the 2016 code (handler profiler/log string) or the client proves for op, else None"""
    if names[op] and names[op].most_common(1)[0][1] >= 10:
        return names[op].most_common(1)[0][0]
    c = CH.get(op, {})
    return c["name"] if (c.get("name_source") or "").startswith("client") else None


def opname(op):
    if op in PDB16E:
        e, cn = PDB16E[op], codename(op)
        return (cn if cn in e.get("aliases", []) else e["name"]), "pdb2016"
    return opname_code(op)


def opname_code(op):
    if VERDICT.get(op, {}).get("use") == "pdb2017":
        return PDB[op], "pdb2017"
    c = CH.get(op, {})
    if (c.get("name_source") or "").startswith("client") and \
            not (names[op] and names[op].most_common(1)[0][1] >= 10):
        return c["name"], c["name_source"].split(":")[0]
    if names[op] and names[op].most_common(1)[0][1] >= 10:
        return names[op].most_common(1)[0][0], "handler"
    if op in PDB:
        return PDB[op], "pdb2017"
    if not names[op] and sent_lit.get(op):
        return sent_lit[op].most_common(1)[0][0], "send-site log literal"
    if names[op]:
        n, k = names[op].most_common(1)[0]
        return n, ("handler" if k >= 10 else "log literal, unverified")
    prev = names.get(op - 1)
    if prev:
        n = prev.most_common(1)[0][0]
        if n.endswith("_REQ"):
            return n[:-4] + "_ACK", "inferred(REQ+1)"
    return None, None

def internal(op):
    return any((s, p) not in CLIENT for s, p, _ in recv[op])

def client_recv(op):
    return [x for x in recv[op] if (x[0], x[1]) in CLIENT]

cat = {}
for s in SERVERS:
    for t in H[s]["tables"]:
        for e in t["entries"]:
            for op_s, dep in e["sends"].items():
                cat.setdefault(int(op_s, 16), set())
for op in set(recv) | set(cat) | set(CH):
    n, src = opname(op)
    cat[op] = {"op": f"0x{op:04x}", "dept": op >> 10, "cmd": op & 0x3ff, "name": n, "name_source": src,
               "received_by": [f"{s}:{p}:{h}" for s, p, h in recv[op]]}
    if op in PDB and n not in [PDB[op]] + PDBE[op].get("aliases", []):
        cat[op]["pdb2017"] = PDB[op]   # official 2017 name, differs from the 2016 name chosen above
    if src == "pdb2016":
        cn = codename(op)
        if cn and cn not in [n] + PDB16E[op].get("aliases", []):
            cat[op]["code_name"] = cn  # name the 2016 binary / client uses (profiler or log string), not the enum's
    if CH.get(op, {}).get("scene"):
        cat[op]["client"] = [f"{h['scene']}:{h['func'] or 'inline@' + h['dispatcher']}"
                             for h in [CH[op]] + CH[op]["other_handlers"]]

def fmt(op):
    c = cat.get(op, {})
    return f"`0x{op:04x}` {c.get('name') or '?'}" + (" †" if c.get("name_source") not in (None, "pdb2016", "handler", "client") else "")

md = {}
for s, p in sorted(CLIENT):
    t = next(t for t in H[s]["tables"] if t["parser"] == p)
    rows = []
    for e in sorted(t["entries"], key=lambda e: e["op"]):
        n, src = opname(e["op"])
        to_client, to_server = [], []
        for op_s, dep in e["sends"].items():
            op = int(op_s, 16)
            if op == e["op"]: continue
            (to_server if internal(op) or (client_recv(op) and not names[op]) else to_client).append(
                fmt(op) + ("" if dep == 0 else " ¹"))
        hints = []
        if e.get("len_checks"): hints.append("len " + ", ".join(e["len_checks"]))
        if e.get("reads"): hints.append("reads " + " ".join(f"+{k}:{v}" for k, v in e["reads"].items()))
        rows.append(f"| `0x{e['op']:04x}` | {e['dept']}/{e['cmd']} | {n or '?'}{'' if src in ('pdb2016', 'handler', None) else ' *(' + src + ')*'}{' (2016 code: ' + cat[e['op']]['code_name'] + ')' if 'code_name' in cat[e['op']] else ''} "
                    f"| `{e['handler']}` | {'<br>'.join(to_client) or '–'} | {'<br>'.join(to_server) or '–'} | {'; '.join(hints) or ''} |")
    # server-session handlers whose processing sends client-bound opcodes (relayed replies / pushes)
    relay = []
    for t2 in H[s]["tables"]:
        if (s, t2["parser"]) in CLIENT: continue
        for e in sorted(t2["entries"], key=lambda e: e["op"]):
            cb = [fmt(int(o, 16)) + ("" if d == 0 else " ¹") for o, d in e["sends"].items()
                  if not internal(int(o, 16)) and int(o, 16) != e["op"]]
            if cb:
                n, src = opname(e["op"])
                relay.append(f"| {t2['parser']} | `0x{e['op']:04x}` {n or '?'} | `{e['handler']}` | {'<br>'.join(cb)} |")
    md[s] = (rows, relay)

for s, (rows, relay) in md.items():
    with open(f"{docs}/opcodes-{s}.md", "w") as f:
        f.write(f"# {s}: client → server handlers (generated)\n\n"
                "Generated by `catalog.py` from Ghidra decompilation. Columns:\n"
                "- **Sends → client**: opcodes this handler (or a direct callee, marked ¹) writes that no server parser receives.\n"
                "- **Sends → servers**: opcodes received by some server-to-server parser (DB, WM, zone link).\n"
                "- **Name**: official enum name from the 2016 server PDBs (`pdb2016`, work item S01) when the value is in them; else the handler's own name.\n"
                "- **†**: name neither from the 2016 server PDBs nor from that opcode's own handler (2017 client PDB `pdb2017`, inferred as REQ+1 = ACK, or a log literal).\n- **Hints**: length checks on the packet size and packet byte offsets read (offset is from payload start, after the opcode).\n"
                "  Heuristic: verify against the handler before relying on it.\n\n"
                "| Opcode | Dept/Cmd | Name | Handler | Sends → client | Sends → servers | Hints |\n|---|---|---|---|---|---|---|\n")
        f.write("\n".join(rows) + "\n")
        f.write("\n## Client-bound packets sent while handling server-to-server messages\n\n"
                "These are replies relayed from DB/WM/zone links, or pushes. Same heuristics as above.\n\n"
                "| Received on | Trigger opcode | Handler | Sends (likely → client) |\n|---|---|---|---|\n")
        f.write("\n".join(relay) + "\n")

json.dump(sorted(cat.values(), key=lambda c: c["op"]), open(f"{docs}/opcodes.json", "w"), indent=1)
print({s: (len(r[0]), len(r[1])) for s, r in md.items()}, "catalog", len(cat),
      "named", sum(1 for c in cat.values() if c["name"]), "pdb2016", sum(1 for c in cat.values() if c["name_source"] == "pdb2016"),
      "code_name differs", sum(1 for c in cat.values() if "code_name" in c))
