"""Render per-packet field documentation from layouts.json + handlers.json + opcodes.json.

usage: python3 -I packets.py <export_root> <docs_dir>     (export_root contains <server>/layouts.json)
writes <docs_dir>/packets-<server>.md for login, wm, zone
"""
import json, os, re, sys

root, docs = sys.argv[1], sys.argv[2]
cat = {c["op"]: c for c in json.load(open(f"{docs}/opcodes.json"))}
import glob
ANN = json.load(open(f"{docs}/annotations.json"))
# per-work-item annotation files (docs/protocol/annotations/*.json) are merged on top, same schema
for f in sorted(glob.glob(f"{docs}/annotations/*.json")):
    extra = json.load(open(f))
    ANN["structs"].update(extra.get("structs", {}))
    for srv, pk in extra.get("packets", {}).items():
        ANN["packets"].setdefault(srv, {}).update(pk)
# 2017 client PDB layouts (work item C02): shown when no hand annotation exists, above the generated guess
_pp = f"{docs}/pdb-layouts.json"
PDB = json.load(open(_pp)) if os.path.exists(_pp) else {"opcodes": {}, "structs": {}}
CLIENT = {"login": "CParserClient", "wm": "CParserClient", "zone": "ShineObjectClass::ShinePlayer"}
TITLE = {"login": "Login server", "wm": "World manager", "zone": "Zone server"}


def internal(op):
    rb = cat.get(op, {}).get("received_by", [])
    return any(r.split(":")[1] not in CLIENT.values() for r in rb)


def name(op, server=None):
    c = cat.get(op, {})
    a = ANN["packets"].get(server, {}).get(op, {}) if server else {}
    n = c.get("name") or (a.get("name") + " (hand-named)" if a.get("name") else "?")
    return n + (" †" if c.get("name_source") not in (None, "handler", "client") else "")


def tidy(e, in_op, pk):
    """make a decompiler expression readable"""
    e = re.sub(r"^\[FUN_[0-9a-f]+\] ", "", e)
    e = re.sub(r"\*\((\w+) \*\)\(\(int\)this \+ (0x[0-9a-f]+)\)", r"this[\2]", e)
    e = re.sub(r"\*\((\w+) \*\)\(this \+ (0x[0-9a-f]+)\)", r"this[\2]", e)
    if in_op and pk:
        def rel(m, scale):
            o = int(m.group(2), 16) if m.group(2).startswith("0x") else int(m.group(2))
            return f"in({in_op})+{o * scale - 2}"
        e = re.sub(r"\*\((\w+) \*\)\(\(int\)" + pk + r" \+ (0x[0-9a-f]+|\d+)\)", lambda m: rel(m, 1), e)
        e = re.sub(r"\*\((\w+) \*\)\(" + pk + r" \+ (0x[0-9a-f]+|\d+)\)", lambda m: rel(m, 1), e)
        e = re.sub(r"\((\w+)\)" + pk + r"\[(0x[0-9a-f]+|\d+)\]", lambda m: rel(m, 2), e)
        e = re.sub(r"\b()" + pk + r"\[(0x[0-9a-f]+|\d+)\]", lambda m: rel(m, 2), e)
    e = e.replace("(uint)", "").replace("(int)", "")
    return e.replace("|", "\\|")


def fmtv(f):
    vals = f["values"]
    out = []
    for v in vals[:6]:
        out.append(f"`{v}`" if -10 < v < 10 else f"`{v}` (0x{v & 0xffffffff:x})")
    return out


def verified(server, op, direction):
    a = ANN["packets"].get(server, {}).get(op)
    if not a or a["dir"] != direction: return []
    rows = ["**Verified layout**" + (f" (basis: {a['basis']})" if a.get("basis") else "") + "\n"]
    if a["fields"]:
        rows.append("| Off | Type | Field | Notes |\n|---|---|---|---|")
        rows += [f"| {o} | {t} | {n} | {x} |" for o, t, n, x in a["fields"]]
    else:
        rows.append("Empty payload.")
    if a.get("notes"): rows.append(f"\n{a['notes']}")
    return rows + [""]


def pdb_layout(op, sizes):
    """PDB struct table for an opcode without a hand annotation; sizes = 2016 payload sizes seen in the code"""
    e = PDB["opcodes"].get(op)
    if not e or "size" not in e: return []
    fits = lambda c, z: z == c["size"] or c["variable"] and z >= c["size"] or not c["fields"] and z == 1  # sizeof(empty) = 1
    cand = [e] + e.get("alts", [])          # alias names sharing the value: take the one the 2016 sizes fit
    p = next((c for c in cand if any(fits(c, z) for z in sizes)), e)
    var = " + variable tail" if p["variable"] else ""
    rows = [f"**2017 PDB layout** *(pdb2017, unverified for 2016)*: `{p['struct']}`" +
            (" (struct shared under the base name, inferred)" if p.get("struct_alias") else "") + f", {p['size']} bytes{var}" +
            ("".join(f" · alias `{c['name']}` = `{c['struct']}` ({c['size']} bytes)" for c in cand if c is not p))]
    bad = sorted({z for z in sizes if not fits(p, z)})
    if bad:
        rows[0] += f" · ⚠ 2016 code uses {', '.join(map(str, bad))} bytes: version drift or extraction error"
    rows += ["", "| Off | Type | Field | Notes |", "|---|---|---|---|"]
    rows += [f"| {o} | {t} | {n} | {x.replace('|', '/')} |" for o, t, n, x in p["fields"]] or ["| | | (empty) | |"]
    used = {f[1].split("[")[0] for f in p["fields"]} & set(PDB["structs"])
    for sn in sorted(used):
        st = PDB["structs"][sn]
        rows.append(f"\nElement `{sn}` ({st['size']} bytes): " + ", ".join(f"+{o} {t} {n}" for o, t, n, _ in st["fields"]))
    return rows + [""]


def render(server):
    L = json.load(open(f"{root}/{server}/layouts.json"))
    H = json.load(open(f"{root}/{server}/handlers.json"))
    src = open(f"{root}/{server}/decomp.c", encoding="utf-8", errors="replace").read()
    # function -> (incoming opcode, packet param, profiler/log name)
    fin = {}
    for t in H["tables"]:
        for e in t["entries"]:
            fin[e["handler"].replace("LAB_", "FUN_")] = (f"0x{e['op']:04x}", t["parser"])
    prof = {}
    for m in re.finditer(r"^//==== FUNC ([0-9a-f]{8}) \S+\n(.*?)(?=^//==== FUNC |\Z)", src, re.S | re.M):
        body = m.group(2)
        n = re.search(r'"((?:\w+::)+\w*NC_\w+|(?:\w+::)+\w+)"', body)
        sig = body.split("{", 1)[0]
        pk = "param_1" if "void *this" in sig else "param_2"
        prof[f"FUN_{m.group(1)}"] = (n.group(1) if n else None, pk)

    out = [f"# {TITLE[server]}: packet field layouts (generated)\n",
           "Generated by `tools/protocol-re/layouts.py` + `packets.py` from Ghidra decompilation of the shipped binary.",
           "Offsets are **payload** offsets (byte 0 = first byte after the 2-byte opcode). Little-endian.\n",
           "How to read the *Value / source* column:",
           "- `` `123` `` constant written by the server.",
           "- `this[0x…]`: member of the sending object (session or player) at that byte offset.",
           "- `in(0xOPCODE)+N`: copied from byte N of the incoming packet whose handler sent this one (shows data flow).",
           "- Other text: the decompiler expression, shortened.",
           "- Gaps between offsets are bytes the code did not write (padding, or filled in a way the extractor missed).",
           "- **Fill**: part of the payload is produced by a helper; for zone, virtual helpers are resolved assuming a `ShinePlayer` receiver.",
           "- †: name not from the opcode's own 2016 handler (2017 client PDB, REQ+1 = ACK guess, or a log string).\n",
           "- **2017 PDB layout**: the `PROTO_*` struct from the 2017 client PDB (`docs/protocol/pdb-layouts.json`, work item C02),",
           "  shown when no hand-verified layout exists. A 2017 build: confirm against the 2016 code before relying on it.\n",
           "Heuristic extraction: verify a layout against the cited function before relying on it.\n"]

    out.append("## Shared structures (hand-verified)\n")
    for sn, st in ANN["structs"].items():
        if server == "login" and sn != "WORLD" or server != "login" and sn == "WORLD": continue
        out.append(f"### {sn} ({st['size']} bytes)\n\nBasis: {st['basis']}\n\n| Off | Type | Field | Notes |\n|---|---|---|---|")
        out += [f"| {o} | {t} | {n} | {x} |" for o, t, n, x in st["fields"]]
        out.append("")
    # ---------------- C -> S
    out.append("## Client → server\n")
    done = set()
    for op, parsers in sorted(L["c2s"].items()):
        r = parsers.get(CLIENT[server])
        if not r: continue
        out.append(f"### `{op}` {name(op, server)}\n")
        v = verified(server, op, "C→S"); done.add(("C→S", op))
        lc = [int(c[3:], 0) - 2 for c in r["len_checks"] if c[:3] in ("== ", "!= ")]
        out += v or pdb_layout(op, lc)
        out.append(f"Handler `{r['handler']}`" + (f" · packet length check: {', '.join(r['len_checks'])} (length includes the opcode)" if r["len_checks"] else ""))
        if not r["fields"]:
            out.append("\nNo payload fields read directly by the handler.\n")
            continue
        out.append("\n| Off | Type | Checks in handler | Notes |\n|---|---|---|---|")
        for o, f in sorted(r["fields"].items(), key=lambda x: int(x[0])):
            t = f["type"] + (f"[{f['size']}]" if f["type"] == "char*" and f["size"] else "")
            t = t.replace("char*[", "char[")
            notes = ", ".join(sorted(f["names"])) or ""
            if f["copied"]: notes = (notes + "; " if notes else "") + "copied with " + ", ".join(f["copied"])
            out.append(f"| {o} | {t} | {', '.join(f['checks'])} | {notes} |")
        out.append("")

    # ---------------- S -> C
    out.append("## Server → client\n")
    for op, sites in sorted(L["s2c"].items()):
        if internal(op): continue
        out.append(f"### `{op}` {name(op, server)}\n")
        v = verified(server, op, "S→C"); done.add(("S→C", op))
        out += v or pdb_layout(op, [x["size"] for x in sites if x["size"] is not None])
        seen_layouts = set()
        for s in sites[:4]:
            key = json.dumps(sorted((o, f["size"]) for o, f in s["fields"].items()))
            if key in seen_layouts and len(sites) > 1: continue
            seen_layouts.add(key)
            in_op, parser = fin.get(s["func"], (None, None))
            pname, pk = prof.get(s["func"], (None, "param_2"))
            ctx = pname or s["func"]
            when = f"in reply to `{in_op}` {name(in_op)} on {parser}" if in_op else f"from `{ctx}`"
            size = f"{s['size']} bytes" if s["size"] is not None else f"variable ({s.get('size_expr')})"
            out.append(f"Sent {when} (`{s['func']}`" + (f", {ctx}" if in_op and pname else "") + f") · payload {size}" + (" · raw header" if s.get("raw") else ""))
            fills = [f for f in s["fills"] if not f.startswith("+-")]  # +-2 = whole packet handed to a send helper
            if fills:
                out.append("\nFill: " + "; ".join(fills[:4]))
            if s["fields"]:
                out.append("\n| Off | Type | Value / source |\n|---|---|---|")
                for o, f in sorted(s["fields"].items(), key=lambda x: int(x[0])):
                    if s["size"] is not None and int(o) >= s["size"] and s["size"] > 0: continue
                    v = fmtv(f) + [f"`{tidy(e, in_op, pk)}`" for e in f["exprs"][:3]]
                    out.append(f"| {o} | {f['type']} | {'; '.join(v)} |")
            out.append("")
        if len(sites) > 4:
            out.append(f"*{len(sites) - 4} more send sites not shown: " + ", ".join(sorted({s['func'] for s in sites[4:]}))[:300] + "*\n")
    rest = [(a["dir"], op) for op, a in ANN["packets"].get(server, {}).items() if (a["dir"], op) not in done]
    if rest:
        out.append("## Hand-verified packets without a generated section\n")
        for d, op in sorted(rest):
            out.append(f"### `{op}` {name(op, server)} ({d})\n")
            out += verified(server, op, d)
    open(f"{docs}/packets-{server}.md", "w").write("\n".join(out) + "\n")
    n_c2s = sum(1 for p in L["c2s"].values() if CLIENT[server] in p)
    n_s2c = sum(1 for op in L["s2c"] if not internal(op))
    print(f"{server}: {n_c2s} client→server, {n_s2c} server→client packets documented")


for s in ("login", "wm", "zone"):
    render(s)


# self-check: hand-verified S->C field offsets should appear in at least one generated send site
for server in ("login", "wm", "zone"):
    L = json.load(open(f"{root}/{server}/layouts.json"))
    for op, a in ANN["packets"].get(server, {}).items():
        if a["dir"] != "S→C" or op not in L["s2c"] or not a["fields"]: continue
        gen = {int(o) for s in L["s2c"][op] for o in s["fields"]}
        if gen and not any(f[0] in gen for f in a["fields"]):
            print(f"check: {server} {op} verified offsets {[f[0] for f in a['fields']]} not in generated {sorted(gen)[:8]}")
