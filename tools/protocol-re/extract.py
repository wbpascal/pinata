"""Extract protocol handler tables + per-handler sent opcodes from Ghidra decomp export.
usage: python3 -I extract.py <outdir/server>   -> writes handlers.json, prints summary
"""
import json, re, sys
from collections import Counter, defaultdict

d = sys.argv[1]
src = open(f"{d}/decomp.c", encoding="utf-8", errors="replace").read()
funcs = {}
for m in re.finditer(r"^//==== FUNC ([0-9a-f]{8}) (\S+)\n(.*?)(?=^//==== FUNC |\Z)", src, re.S | re.M):
    funcs[int(m.group(1), 16)] = (m.group(2), m.group(3))

strs = [l.rstrip("\n").split("\t") for l in open(f"{d}/strings.tsv", encoding="utf-8", errors="replace")]

def fn_ref(needle):
    for s in strs:
        if len(s) > 2 and needle in s[1]:
            for r in s[2].split(","):
                if "@" in r:
                    return r.split("@")[1]
    return None

store = fn_ref("Duplicate protocol set")
sendid = fn_ref("CSendPacket::ID")  # login/wm; zone writes opcode into a global buffer instead
num = r"(0x[0-9a-fA-F]+|\d+)"
def ival(s): return int(s, 16) if s.lower().startswith("0x") else int(s)

# handler tables: a registration block belongs to the most recent template class seen in address order
tables, cur = {}, None
for addr in sorted(funcs):
    name, body = funcs[addr]
    m = re.search(r"PROTOCOLFUNCTIONTEMPLETE<(?:int|void)_\(__thiscall_([\w:]+)::\*\)\((\w+)\*", body)
    if not m:  # DB servers: parser class only visible as "<Class>::vftable" assignment
        m2 = re.search(r"\*param_1 = (C(?:Parser|PFs)\w*)::vftable;", body)
        if m2: m = re.match(r"(.*)()", m2.group(1) + "")  # group(1)=class, group(2)=''
    if m:
        cur = m.group(1)
        t = tables.setdefault(cur, {"parser": cur, "arg": m.group(2), "ctors": [], "entries": []})
    ents = re.findall(store + r"\((?:[^,()]+,)?" + num + "," + num + r",&?(\w+)\)", body)
    if ents and cur and addr != int(store[4:], 16):
        tables[cur]["ctors"].append(f"{addr:08x}")
        tables[cur]["entries"] += [{"dept": ival(a), "cmd": ival(b), "op": ival(a) << 10 | ival(b), "handler": h}
                                   for a, b, h in ents]

# self-check: every pft_Store call site must be captured by exactly one table
calls = sum(len(re.findall(r"\b" + store + r"\(", b)) for a, (_, b) in funcs.items() if f"FUN_{a:08x}" != store)
got = sum(len(t["entries"]) for t in tables.values())
assert got == calls, f"captured {got} registrations, but {calls} {store}() call sites exist"

zbuf = Counter(re.findall(r"\*\(undefined2 \*\)(PTR_DAT_\w+) = 0x[0-9a-f]+;", src)).most_common(1)
zbuf = zbuf[0][0] if zbuf else None

def sends_in(body):
    out = set()
    if sendid:
        out |= {ival(x) for x in re.findall(sendid + r"\((?:[A-Za-z_&(][^,]*,)?" + num + ",", body)}
    # packed raw header: <len byte var> = N; <next var> = 0x....OOOO (low 16 bits = opcode)
    for ln, pk in re.findall(r"\w+ = " + num + r";\n\s*\w+ = (0x[0-9a-f]{4,8});", body):
        if 2 < ival(ln) < 256 and ival(pk) & 0xffff >= 0x400:
            out.add(ival(pk) & 0xffff)
    lo, hi = {}, {}
    for v, i, val in re.findall(r"(\w+)\[([12])\] = " + num + ";", body):
        (lo if i == "1" else hi)[v] = ival(val)
    out |= {hi[v] << 8 | lo[v] for v in lo if v in hi and lo[v] < 256 and hi[v] < 256}
    # raw header packed in one dword: byte0 = length, bytes1-2 = opcode; variable must be sent by address
    for v, val in re.findall(r"(\w+) = (?:\(\w+ \*\))?0x([0-9a-f]{6,8});", body):
        x = int(val, 16); ln, op = x & 0xff, (x >> 8) & 0xffff
        if 2 <= ln <= 0x40 and 1 <= op >> 10 <= 63 and re.search(r"&" + v + r"\b", body):
            out.add(op)
    if zbuf and zbuf in body:
        alias = {zbuf} | set(re.findall(r"(\w+) = " + zbuf + ";", body))
        for v, val in re.findall(r"\*\(undefined2 \*\)(\w+) = " + num + ";", body):
            if v in alias:
                out.add(ival(val))
        # 4-byte store at buffer start: low 16 bits are the opcode
        for v, val in re.findall(r"\*\((?:undefined4|undefined \*\*|int|uint) \*\)(\w+) = (?:&DAT_|\(\w+\))?((?:0x)?[0-9a-f]{5,8});", body):
            if v in alias:
                out.add(int(val, 16) & 0xffff)
    out.discard(0)
    return out

def nc_names(body):
    return re.findall(r'"(?:[\w:]*::)?(?:\w+_)?(NC_[A-Z0-9_]+?)(?:\s|"|:)', body)

def addr_of(n):
    m = re.match(r"(?:FUN|LAB)_([0-9a-f]{8})", n)
    return int(m.group(1), 16) if m else None

def walk(h, depth=1):
    res, seen, frontier = {}, set(), [(addr_of(h), 0)]
    while frontier:
        a, dep = frontier.pop(0)
        if a is None or a in seen or a not in funcs: continue
        seen.add(a)
        body = funcs[a][1]
        for op in sends_in(body):
            res.setdefault(op, dep)
        if dep < depth:
            for c in sorted(set(re.findall(r"FUN_([0-9a-f]{8})\(", body))):
                frontier.append((int(c, 16), dep + 1))
    return res

TSZ = {"char": 1, "byte": 1, "undefined1": 1, "short": 2, "ushort": 2, "undefined2": 2,
       "int": 4, "uint": 4, "undefined4": 4, "float": 4, "undefined8": 8, "longlong": 8, "ulonglong": 8}

def payload_hints(body):
    """Packet field reads, as payload offsets (packet arg points at the opcode; payload = +2)."""
    sig = body.split("{", 1)[0]
    # thiscall with explicit this: (this, packet, len, ...) else (session, packet, len)
    pk, ln = ("param_1", "param_2") if "void *this" in sig else ("param_2", "param_3")
    m = re.search(r"\b(int|ushort \*|short \*|byte \*|char \*|NETCOMMAND \*|undefined2 \*) ?" + pk + r"\b", sig)
    out = {}
    lens = sorted({f"{op} {v}" for op, v in re.findall(ln + r" (!=|==|<|>|<=|>=) " + num + r"\b", body)})
    if lens: out["len_checks"] = lens
    if not m: return out
    scale = 2 if m.group(1).replace(" ", "") in ("ushort*", "short*", "undefined2*") else 1
    reads = {}
    def add(o, t):
        if o >= 2: reads.setdefault(o - 2, t)
    for t, cast, off in re.findall(r"\*\((\w+) \*\)\((\(int\))?" + pk + r" \+ " + num + r"\)", body):
        add(ival(off) * (1 if cast else scale), t)
    for cast, off in re.findall(r"\((?:char|uchar|byte|undefined1|undefined4) \*\)\((\(int\))?" + pk + r" \+ " + num + r"\)", body):
        add(ival(off) * (1 if cast else scale), "ptr")
    if scale == 2:
        for cast, idx in re.findall(r"(\(byte\)|\(char\))?" + pk + r"\[" + num + r"\]", body):
            add(ival(idx) * 2, "byte" if cast else "ushort")
    if reads: out["reads"] = {str(k): v for k, v in sorted(reads.items())}
    return out

# op -> name: function whose profiler/log name is NC_X and which writes exactly that-ish opcode
opnames = defaultdict(Counter)
for t in tables.values():
    for e in t["entries"]:
        a = addr_of(e["handler"])
        if a in funcs:
            # prefer the handler's own name (sp_/fc_/pf_ prefixed profiler or log string), else first NC_ literal
            own = re.findall(r'"[^"]*?\b(?:sp|fc|gds|wms|zls|so|opts|gls)_(NC_[A-Z0-9_]+)', funcs[a][1])
            n = own or nc_names(funcs[a][1])
            e["name"] = n[0] if n else None
            e["name_src"] = "handler" if own else ("literal" if n else None)
            if e["name"]:
                opnames[e["op"]][e["name"]] += 10 if e["name_src"] == "handler" else 3
        e["sends"] = {f"0x{op:04x}": dep for op, dep in sorted(walk(e["handler"]).items())}
        if a in funcs:
            e.update(payload_hints(funcs[a][1]))

json.dump({"store": store, "sendid": sendid, "zbuf": zbuf, "tables": list(tables.values()),
           "opnames": {f"0x{k:04x}": dict(v) for k, v in sorted(opnames.items())}},
          open(f"{d}/handlers.json", "w"), indent=1)
for t in tables.values():
    named = sum(1 for e in t["entries"] if e.get("name"))
    print(f"{t['parser']:<40} {len(t['entries']):4} handlers, {named} named")
print("opnames:", len(opnames), "send buffer:", zbuf)
