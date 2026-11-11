"""Client (Fiesta.bin) packet-handler inventory -> re-data/client-handlers.json   (work item C01)

usage: python3 -I client_handlers.py <repo root>

Receive path (see docs/knowledge/C01.md):
  PgNet::Recv (FUN_008c7b60) -> Net vtable slot 6 (FUN_006d2fa0, heartbeat/time) and, if that returns 0,
  the current scene's PgFrameWork vtable slot 13 (dispatcher(dept, cmd, size, payload)).
  GameFrameWork's dispatcher first broadcasts to the ITask tree (FUN_006a2030); each ITask subclass
  handles packets in vtable slot 4.
Dispatchers are nested switch/if trees over dept and cmd; this script walks the decompiled text.
"""
import glob, itertools, json, os, re, sys
from collections import defaultdict

R = sys.argv[1] if len(sys.argv) > 1 else "."
sys.path.insert(0, os.path.join(R, "tools/protocol-re"))
from rtti import vtables, PE
from shn import read as shn_read

SRC = open(f"{R}/re-data/exports/client/decomp.c", encoding="utf-8", errors="replace").read()
FUNCS = {m.group(1): m.group(2) for m in
         re.finditer(r"^//==== FUNC ([0-9a-f]{8}) \S+\n(.*?)(?=^//==== FUNC |\Z)", SRC, re.S | re.M)}
TEXTS = {}
for f in ("TextData", "TextData2", "TextData3"):
    for r in shn_read(f"{R}/Files/Client/2016/ressystem/{f}.shn")[1]:
        TEXTS.setdefault(r[0], r[3])
VT = vtables(f"{R}/Files/Client/2016/Fiesta.bin")
BIN = PE(f"{R}/Files/Client/2016/Fiesta.bin")

NUM = r"(?:\(\w+ \*?\))?(0x[0-9a-f]+|\d+)"
def iv(s): return int(s, 16) if s.startswith("0x") else int(s)
SIZES = {"char": 1, "byte": 1, "undefined1": 1, "uchar": 1, "bool": 1, "short": 2, "ushort": 2, "undefined2": 2,
         "wchar_t": 2, "int": 4, "uint": 4, "undefined4": 4, "float": 4, "LONG": 4, "DWORD": 4,
         "longlong": 8, "ulonglong": 8, "undefined8": 8, "double": 8}


def signature(addr):
    """-> [(type, name)] of a function's parameters (including `this`)"""
    b = FUNCS.get(addr, "")
    m = re.search(r"\w+\s*\(([^)]*)\)\s*\{", b, re.S)
    if not m or m.group(1).strip() in ("", "void"): return []
    out = []
    for p in m.group(1).split(","):
        p = p.strip(); mm = re.search(r"(\w+)$", p)
        if not mm: return []
        n = mm.group(1)
        out.append((p[: -len(n)].strip(), n))
    return out


def strip_casts(e):
    e = e.strip()
    while True:
        m = re.match(r"^\((?:\w+\s*\**)\)\s*(.*)$", e)
        if not m: return e
        e = m.group(1).strip()


def split_args(s):
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch == "," and depth == 0: out.append(cur.strip()); cur = ""; continue
        depth += ch == "("; depth -= ch == ")"; cur += ch
    if cur.strip(): out.append(cur.strip())
    return out


def calls(line):
    """-> [(FUN_addr, [args])] for every direct call on the line"""
    res = []
    for m in re.finditer(r"FUN_([0-9a-f]{8})\(", line):
        depth, i = 1, m.end()
        while i < len(line) and depth:
            depth += line[i] == "("; depth -= line[i] == ")"; i += 1
        res.append((m.group(1), split_args(line[m.end(): i - 1])))
    return res


def cond_vals(cond, var, op):
    """values v where cond contains `var <op> v` (only meaningful for pure ||/&& chains)"""
    return [iv(v) for v in re.findall(re.escape(var) + r" " + op + " " + NUM + r"\)", cond + ")")]


def walk(addr, roles, fixed, out, scene, depth=0, seen=None):
    """roles: {'dept': var, 'cmd': var, 'size': var, 'payload': var}; fixed: {'dept': v} already known.
    Fills out[(dept, cmd)] -> list of {'scene','dispatcher','stmts': [...]}"""
    seen = seen or set()
    if addr in seen or depth > 3: return
    seen = seen | {addr}
    body = FUNCS[addr]
    rv = {v: k for k, v in roles.items() if v}
    lines = body.split("\n")
    # frames: [open_depth, {role: [vals]}, kind, pending_after_close]
    frames, d = [], 0
    labels = defaultdict(list)          # label -> statements
    gotos = []                          # (ctx, label)
    cur_label, last_closed, alias, cmd_range = None, None, {}, None
    after = {}                          # extra facts valid until the enclosing frame closes: depth -> {role: vals}

    def ctx():
        c = dict({k: [v] for k, v in fixed.items()})
        for dep in sorted(after):
            if dep <= d: c.update(after[dep])
        for f in frames: c.update(f[1])
        return c

    def record(c, stmt):
        if "dept" in c and "cmd" in c and c["dept"] is not None and c["cmd"] is not None:
            for dv, cv in itertools.product(c["dept"], c["cmd"]):
                out[(dv, cv)].append((scene, addr, stmt, roles.get("payload")))
            return True
        return False

    i = 0
    for raw in lines[1:]:
        s = raw.strip()
        if not s: continue
        opens, closes = s.count("{"), s.count("}")
        # close frames
        if s.startswith("}"):
            d -= 1
            closed = None
            while frames and frames[-1][0] > d:
                closed = frames.pop()
            for k in [k for k in after if k > d]: del after[k]
            last_closed = closed
            if closed and closed[3] and closed[2] == "if":
                # after `if (x != N) { ...return/break }` the rest of the scope has x == N
                after.setdefault(d, {}).update(closed[3])
            continue
        if s == "else {" or s.startswith("else if ("):
            neg = last_closed[3] if last_closed and last_closed[2] == "if" else None
            if neg:  # the else of `x != N` is the `x == N` branch, not the rest of the scope
                for k in list(after):
                    if k == d: [after[k].pop(r, None) for r in neg]
            m = re.match(r"else if \((.*)\)\s*\{$", s)
            f, nn = (dict(neg) if neg and s == "else {" else {}), None
            if m:
                cond = m.group(1)
                for role in ("dept", "cmd"):
                    vs = cond_vals(cond, roles[role], "==") if roles.get(role) else []
                    if vs: f[role] = vs
            d += 1
            frames.append([d, f, "if" if m else "else", nn]); continue
        m = re.match(r"(\w+):$", s)
        if m:
            cur_label = m.group(1); continue
        m = re.match(r"(\w+) = (\w+) (\+ -|-) (0x[0-9a-f]+|\d+);$", s)
        if m and m.group(2) in rv:
            alias[m.group(1)] = (rv[m.group(2)], iv(m.group(4)))
        # MSVC two-level switch Ghidra could not normalize: `if (cmd - LO < N) switch(*(byte*)(&TABLE + cmd + K))`
        # -> the case value is a byte-table entry; resolve it to cmd values from the binary
        m = re.match(r"switch\(\*\(\w+ \*\)\(\(int\)&\w+_([0-9a-f]{8}) \+ (\w+) \+ (-?(?:0x[0-9a-f]+|\d+))\)\) \{$", s)
        if m and rv.get(m.group(2)) and cmd_range and cmd_range[0] == m.group(2):
            d += 1
            base = int(m.group(1), 16) + int(m.group(3), 0)
            frames.append([d, {}, f"switch:{rv[m.group(2)]}:T{base:x}:{cmd_range[1]:x}:{cmd_range[2]:x}", None]); continue
        m = re.match(r"switch\s*\((\w+)\)\s*\{$", s)
        if m:
            d += 1
            role, off = (rv[m.group(1)], 0) if m.group(1) in rv else alias.get(m.group(1), ("", 0))
            frames.append([d, {}, f"switch:{role}:{off}", None]); continue
        mc = re.findall(r"case " + NUM + ":", s)
        if mc or s == "default:":
            for k in [k for k in after if k >= d]: del after[k]  # a new case starts a fresh scope
            for f in reversed(frames):
                if f[2].startswith("switch"):
                    _, role, off, *rng = f[2].split(":")
                    if role:
                        if s == "default:": f[1] = {role: None}
                        else:
                            prev = f[1].get(role) if f[3] == "case" else None
                            if off.startswith("T"):  # byte-table switch: every cmd whose table byte is this case
                                base, lo, hi = int(off[1:], 16), int(rng[0], 16), int(rng[1], 16)
                                ks = {iv(v) for v in mc}
                                vals = [c for c in range(lo, hi) if BIN.b[BIN.off(base + c)] in ks]
                            else:
                                vals = [iv(v) + int(off) for v in mc]
                            f[1] = {role: (prev or []) + vals}
                            f[3] = "case"
                    break
            cur_label = None
            continue
        for f in frames:
            if f[2].startswith("switch") and f[3] == "case": f[3] = None
        m = re.match(r"(?:if|while) \((.*)\)\s*\{$", s)
        if m:
            cond = m.group(1); fact, neg = {}, {}
            mr = re.fullmatch(r"(\w+) - (0x[0-9a-f]+|\d+)U? < (0x[0-9a-f]+|\d+)", cond)
            if mr and rv.get(mr.group(1)) == "cmd":
                lo = iv(mr.group(2)); cmd_range = (mr.group(1), lo, lo + iv(mr.group(3)))
            for role in ("dept", "cmd"):
                v = roles.get(role)
                if not v: continue
                eq, ne = cond_vals(cond, v, "=="), cond_vals(cond, v, "!=")
                if eq and " && " not in cond: fact[role] = eq
                elif eq and " || " not in cond: fact[role] = eq
                if ne and " && " not in cond and len(ne) == 1: neg[role] = ne
            d += 1
            frames.append([d, fact, "if", neg or None]); continue
        if opens > closes:
            d += opens - closes
            frames.append([d, {}, "blk", None]); continue
        # one-line guard `if ((x != N) || (y != M)) return/goto ...;` -> rest of scope has x == N, y == M
        m = re.match(r"if \((.*)\) (?:goto \w+|return[^;]*);$", s)
        if m and " && " not in m.group(1):
            g = {r: cond_vals(m.group(1), roles[r], "!=") for r in ("dept", "cmd") if roles.get(r)}
            g = {r: v for r, v in g.items() if len(v) == 1}
            if g:
                after.setdefault(d, {}).update(g); continue
        # a statement
        c = ctx()
        mg = re.match(r"goto (\w+);", s)
        if mg:
            gotos.append((c, mg.group(1))); continue
        stmt = s
        if cur_label: labels[cur_label].append(stmt)
        if s.startswith(("break;", "return")) and cur_label and not s.startswith("return FUN_"):
            cur_label = None
        if not record(c, stmt):
            # sub-dispatcher: a call forwarding cmd (and maybe dept) with dept known or forwarded
            for fn, args in calls(s):
                a = [strip_casts(x) for x in args]
                if fn in ("006a2030",): continue
                have_cmd = roles.get("cmd") in a
                have_dept = roles.get("dept") in a or ("dept" in c and c["dept"])
                if have_cmd and have_dept and fn in FUNCS:
                    sig = signature(fn)
                    if len(sig) != len(a): continue
                    nroles = {r: sig[a.index(v)][1] for r, v in roles.items() if v and v in a}
                    nfixed = {} if roles.get("dept") in a else {"dept": c["dept"][0]}
                    if len(c.get("dept") or []) > 1:
                        for dv in c["dept"]: walk(fn, nroles, {"dept": dv}, out, scene, depth + 1, seen)
                    else:
                        walk(fn, nroles, nfixed, out, scene, depth + 1, seen)
    for c, lab in gotos:
        for stmt in labels.get(lab, []) or ["/* shared tail " + lab + " */"]:
            record(c, stmt)
        if not labels.get(lab): record(c, "/* label " + lab + " */")


def roles_from_sig(addr, tail=4):
    sig = signature(addr)
    # (this,) dept, cmd, size, payload; Ghidra sometimes drops unused trailing params
    names = [n for _, n in sig][-tail:] if len(sig) >= 5 or sig[:1] and sig[0][1] != "this" else [n for _, n in sig][1:]
    return dict(zip(["dept", "cmd", "size", "payload"], names))


# ---------------------------------------------------------------- dispatchers
SCENES = {}
for cls in ("AccountFrameWork", "LoginWorldNetFrameWork", "ZoneLoginNetFrameWork", "CharSelectFrameWork",
            "CharCreateFrameWork", "GameFrameWork", "LinkFrameWork", "CHairShopFrameWork", "LoadingFrameWork"):
    SCENES[cls] = f"{VT[cls][13]:08x}"
SCENES["Net(pre-dispatch)"] = f"{VT['Net'][6]:08x}"
for cls, v in sorted(VT.items()):  # ITask subclasses: packet handler in vtable slot 4 (ITask's own is a no-op)
    if cls.endswith(("Task", "Cache")) and cls != "ITask" and "::" not in cls and len(v) > 4 \
            and v[4] != VT["ITask"][4]:
        SCENES[f"ITask:{cls}"] = f"{v[4]:08x}"

out = defaultdict(list)
for scene, addr in SCENES.items():
    if addr not in FUNCS or len(FUNCS[addr]) < 80: continue
    walk(addr, roles_from_sig(addr), {}, out, scene)

# ---------------------------------------------------------------- per-handler analysis
GETTERS = {"006acdb0", "008c5db0", "006614b0", "00406260", "00407c70", "00732e30", "0048b2d0"}


def pointee(t):
    t = t.replace("const", "").strip()
    if not t.endswith("*"): return None
    return t[:-1].strip()


def fields_of(fn, pvar, ptype, depth=0, seen=None):
    """payload reads in fn: [(offset, type)] (heuristic), recursing into callees that get the payload"""
    seen = seen or set()
    if fn in seen or fn not in FUNCS or depth > 2: return []
    seen.add(fn)
    return fields_text(FUNCS[fn], pvar, ptype, depth, seen)


def fields_text(b, pvar, ptype, depth=0, seen=None):
    res = []
    base = pointee(ptype)
    esz = SIZES.get(base, 1) if base else 1
    P = re.escape(pvar)
    for m in re.finditer(r"\*\((\w+) \*\)\((?:\(int\))?" + P + r" \+ (0x[0-9a-f]+|\d+)\)", b):
        off = iv(m.group(2)) * (1 if "(int)" in m.group(0) or not base else esz)
        res.append((off, m.group(1)))
    for m in re.finditer(r"(?<![\w&])" + P + r"\[(0x[0-9a-f]+|\d+)\]", b):
        res.append((iv(m.group(1)) * esz, base or "?"))
    for m in re.finditer(r"(?<![\w)])\*" + P + r"(?!\w)", b):
        res.append((0, base or "?"))
    for m in re.finditer(r"(?<!\*)\((?:\w+ \*\))?\((?:\(int\))?" + P + r" \+ (0x[0-9a-f]+|\d+)\)", b):
        off = iv(m.group(1)) * (1 if "(int)" in m.group(0) or not base else esz)
        res.append((off, "ptr/array"))
    for line in b.split("\n"):
        for c, args in calls(line):
            a = [strip_casts(x) for x in args]
            if pvar in a and c not in GETTERS:
                sig = signature(c)
                if len(sig) == len(a):
                    t, n = sig[a.index(pvar)]
                    res += [(o, ty) for o, ty in fields_of(c, n, t, depth + 1, seen)]
    return res


def payload_chain(fn, pvar, depth=0, seen=None):
    """fn plus every callee (depth <= 2) that receives the payload pointer"""
    seen = seen if seen is not None else set()
    if fn in seen or fn not in FUNCS or depth > 2: return seen
    seen.add(fn)
    for line in FUNCS[fn].split("\n"):
        for c, args in calls(line):
            a = [strip_casts(x) for x in args]
            if pvar in a and c not in GETTERS:
                sig = signature(c)
                if len(sig) == len(a): payload_chain(c, sig[a.index(pvar)][1], depth + 1, seen)
    return seen


def texts_of(fns):
    t = {}
    for fn in fns:
        for v in re.findall(r"0x[0-9a-f]{6,8}", FUNCS.get(fn, "")):
            if int(v, 16) in TEXTS: t[f"0x{int(v, 16):08x}"] = TEXTS[int(v, 16)]
    return t


def payload_callee(stmts, payload_var):
    best = None
    for s in stmts:
        for c, args in calls(s):
            if c in GETTERS: continue
            a = [strip_casts(x) for x in args]
            if payload_var and payload_var in a: return c, a.index(payload_var)
            if best is None: best = (c, None)
    return best or (None, None)


names = {}
for c in json.load(open(f"{R}/docs/protocol/opcodes.json")):
    if c["name"]: names[int(c["op"], 16)] = (c["name"], c["name_source"])

# names the client itself proves: On_NC_* debug strings inside the handler, ProtoStruct<PROTO_NC_*> RTTI
# instantiated with (dept, cmd) in CVirtualServer (FUN_00683240 / the function before it)
CLIENT_NAMES = {
    0x204a: ("NC_ACT_REINFORCE_STOP_CMD", "client debug string in handler FUN_00499f10"),
    0x2434: ("NC_BAT_SKILLBASH_CAST_FAIL_ACK", "client debug string in handler FUN_004aa840"),
    0x2438: ("NC_BAT_SOMEONESKILLBASH_CASTCUT_CMD", "client debug string in handler FUN_0049a3b0"),
    0x2445: ("NC_BAT_SKILLBASH_CASTABORT_ACK", "client debug string in handler FUN_0049a540"),
    0x6c11: ("NC_SCENARIO_NPCCHAT_CMD", "client debug string in handler FUN_004bb040"),
    0x6c12: ("NC_SCENARIO_MESSAGE_CMD", "client debug string in handler FUN_004b6f60"),
    0x1c06: ("NC_BRIEFINFO_LOGINCHARACTER_CMD", "client RTTI ProtoStruct<PROTO_NC_BRIEFINFO_LOGINCHARACTER_CMD>(7, 6, size 0xeb)"),
    0x242e: ("NC_BAT_SOMEONEBASH_HIT_CMD", "client RTTI ProtoStruct<PROTO_NC_BAT_SOMEONEBASH_HIT_CMD>(9, 0x2e, size 0xd)"),
}
from client_summaries import SUMMARY  # hand-written per-opcode summaries (C01), keyed "0xOPCODE" or "0xOPCODE@Scene"

STRREFS = defaultdict(list)  # function -> literal strings it references
for ln in open(f"{R}/re-data/exports/client/strings.tsv", encoding="utf-8", errors="replace"):
    c = ln.rstrip("\n").split("\t")
    if len(c) < 3 or len(c[1]) < 4: continue
    for fn in set(re.findall(r"@FUN_([0-9a-f]{8})", c[2])): STRREFS[fn].append(c[1].replace("\\n", "").strip())


# server functions that send each opcode (layouts.json s2c sites), under their names from names/<srv>/*.json
# (zone: original profiler names from Z01; wm: W01). Tells what a packet carries even when the opcode is unnamed.
SENDERS = defaultdict(dict)
for srv in ("login", "wm", "zone"):
    nm = {}
    for f in sorted(glob.glob(f"{R}/tools/protocol-re/names/{srv}/*.json")): nm.update(json.load(open(f)))
    for k, sites in json.load(open(f"{R}/re-data/exports/{srv}/layouts.json"))["s2c"].items():
        SENDERS[int(k, 16)][srv] = list(dict.fromkeys(nm.get(x["func"], x["func"]) for x in sites))[:6]


def auto_summary(h, op):
    strs = list(dict.fromkeys(x for f in h.pop("_chain") for x in STRREFS.get(f, [])))[:4]
    bits = []
    if h["inline"] and not h["fields"] and len(h["inline"]) <= 2 and re.match(r"(return|uVar\d+ = param_3|break)", h["inline"][0]):
        bits.append("accepted and ignored")
    if h["texts"]: bits.append("may show: " + " | ".join(list(h["texts"].values())[:4]))
    if strs: bits.append("refs: " + " | ".join(strs))
    named = [n for v in SENDERS.get(op, {}).values() for n in v if not n.startswith("FUN_")]
    if named: bits.append("sent by: " + ", ".join(named[:3]))
    return "(auto) " + ("; ".join(bits) if bits else f"{len(h['fields'])} payload reads")

result = {}
for (dv, cv), hits in sorted(out.items()):
    op = dv << 10 | cv
    per = defaultdict(list)
    for scene, disp, stmt, pv in hits: per[(scene, disp, pv)].append(stmt)
    hs = []
    for (scene, disp, pv), stmts in per.items():
        fn, idx = payload_callee(stmts, pv)
        fields, texts = [], {}
        for s in stmts:
            for v in re.findall(r"0x[0-9a-f]{6,8}", s):
                if int(v, 16) in TEXTS: texts[f"0x{int(v, 16):08x}"] = TEXTS[int(v, 16)]
        if fn and idx is not None:
            t, n = signature(fn)[idx]
            fields = sorted(set(fields_of(fn, n, t)))
            chain = payload_chain(fn, n)
            texts.update(texts_of(chain))
        elif fn:
            chain = {fn}
            texts.update(texts_of(chain))
        else:
            chain = set()
        inline = fn is None
        if inline and pv:
            ptype = dict((n, t) for t, n in signature(disp)).get(pv, "")
            fields = sorted(set(fields_text("\n".join(stmts), pv, ptype, 0, set())))
        hs.append({"scene": scene, "dispatcher": f"FUN_{disp}", "func": f"FUN_{fn}" if fn and not inline else None,
                   "inline": stmts[:6] if inline else None,
                   "fields": [[o, ty, None, "auto: client read"] for o, ty in fields],
                   "texts": texts, "_chain": sorted(chain)})
    n = names.get(op, (None, None))
    if op in CLIENT_NAMES:
        if n[0] and n[0] != CLIENT_NAMES[op][0]: print(f"name conflict 0x{op:04x}: catalog {n} vs client {CLIENT_NAMES[op]}")
        n = (CLIENT_NAMES[op][0], "client: " + CLIENT_NAMES[op][1])
    for h in hs:
        h["summary"] = SUMMARY.get(f"0x{op:04x}@{h['scene']}") or SUMMARY.get(f"0x{op:04x}") or auto_summary(h, op)
        h.pop("_chain", None)
    prim = hs[0]
    result[f"0x{op:04x}"] = {
        "dept": dv, "cmd": cv, "name": n[0], "name_source": n[1],
        "scene": prim["scene"], "func": prim["func"], "summary": prim["summary"],
        "fields": prim["fields"], "texts": prim["texts"],
        "inline": prim["inline"], "dispatcher": prim["dispatcher"],
        "senders": SENDERS.get(op, {}), "other_handlers": hs[1:]}

for op, (nm, src) in CLIENT_NAMES.items():  # proven names of opcodes no dispatcher handles
    if f"0x{op:04x}" not in result:
        result[f"0x{op:04x}"] = {"dept": op >> 10, "cmd": op & 0x3ff, "name": nm, "name_source": "client: " + src,
                                 "scene": None, "func": None, "summary": "no client dispatcher handles this opcode",
                                 "fields": [], "texts": {}, "inline": None, "dispatcher": None,
                                 "senders": SENDERS.get(op, {}), "other_handlers": []}
result = dict(sorted(result.items()))
os.makedirs(f"{R}/re-data", exist_ok=True)
json.dump(result, open(f"{R}/re-data/client-handlers.json", "w"), indent=1, ensure_ascii=False)
by_scene = defaultdict(int)
for v in result.values():
    if not v["scene"]: continue
    by_scene[v["scene"]] += 1
    for h in v["other_handlers"]: by_scene[h["scene"]] += 1
print(sum(1 for v in result.values() if v["scene"]), "handled opcodes;", dict(by_scene))
assert len(result) > 300, "dispatcher walk found too few opcodes"
_hit = {h for v in result.values() for h in [v["scene"]] + [x["scene"] for x in v["other_handlers"]]}
print("dispatchers without handlers:", {s: a for s, a in SCENES.items() if s not in _hit})
