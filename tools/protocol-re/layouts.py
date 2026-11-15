"""Reconstruct packet field layouts from a Ghidra ExportAll dump.

usage: python3 -I layouts.py <export_dir/server> <unused> [<original .exe, enables vtable resolution>]   -> writes layouts.json next to decomp.c

S->C: every send site is located and the fields written into the outgoing buffer are collected:
  - zone:      global buffer PTR_DAT_0084d908 (opcode at +0, payload at +2), size from FUN_004c8ce0(&buf, total)
  - login/wm:  stack CSendPacket (CSendPacket::ID(buf, op, payload_size, src); payload at buf+5)
               and raw byte headers (buf[0]=len, buf[1..2]=opcode; payload at buf+3)
C->S: for each registered handler, the packet offsets it reads, the comparisons applied to them,
      and field names taken from log format strings that print them.
All offsets in the output are payload offsets (0 = first byte after the opcode).
"""
import json, re, sys
from collections import defaultdict

d = sys.argv[1]
src = open(f"{d}/decomp.c", encoding="utf-8", errors="replace").read()
H = json.load(open(f"{d}/handlers.json"))
funcs = {}
for m in re.finditer(r"^//==== FUNC ([0-9a-f]{8}) (\S+)\n(.*?)(?=^//==== FUNC |\Z)", src, re.S | re.M):
    funcs[f"FUN_{m.group(1)}"] = m.group(3)

NUM = r"(?:0x[0-9a-fA-F]+|\d+)"
def ival(s): return int(s, 16) if s.lower().startswith("0x") else int(s)
TSZ = {"char": 1, "byte": 1, "uchar": 1, "bool": 1, "undefined": 1, "undefined1": 1,
       "short": 2, "ushort": 2, "undefined2": 2, "wchar_t": 2,
       "int": 4, "uint": 4, "undefined4": 4, "float": 4, "long": 4, "ulong": 4, "dword": 4, "DWORD": 4,
       "undefined3": 3, "undefined5": 5, "undefined6": 6, "undefined7": 7,
       "undefined8": 8, "longlong": 8, "ulonglong": 8, "double": 8, "__time64_t": 8}
TNAME = {1: "u8", 2: "u16", 3: "u24", 4: "u32", 8: "u64"}
def tname(t, n=None):
    n = n or TSZ.get(t, 4)
    if t == "float": return "f32"
    if t in ("short",): return "i16"
    if t in ("int", "long"): return "i32"
    if t == "char": return "char"
    return TNAME.get(n, f"bytes[{n}]")

def clean(e):
    e = re.sub(r"\s+", " ", e.strip())
    return e if len(e) <= 70 else e[:67] + "..."

def value_of(e):
    e = e.strip()
    if re.fullmatch(r"-?" + NUM, e):
        v = ival(e.lstrip("-")) * (-1 if e.startswith("-") else 1)
        return v
    return None

def call_args(s):
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch == "(" : depth += 1
        if ch == ")":
            if depth == 0: break
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur); cur = ""
        else:
            cur += ch
    out.append(cur)
    return [a.strip() for a in out]

def decls(body):
    """local stack variable declarations: name -> (type, elem_size, count)"""
    out = {}
    for t, ptr, name, cnt in re.findall(r"^\s+(\w+) (\*?)(local_[0-9a-f]+|[a-zA-Z]+Stack_[0-9a-f]+)(?: \[(\d+)\])?;", body, re.M):
        out[name] = (t if not ptr else "ptr", TSZ.get(t, 4) if not ptr else 4, int(cnt) if cnt else 1)
    return out

def stack_off(name):
    m = re.search(r"_([0-9a-f]+)$", name)
    return int(m.group(1), 16) if m else None

def add_field(fields, off, size, typ, expr, kind="write"):
    if off < 0: return
    f = fields.setdefault(off, {"size": size, "type": typ, "values": set(), "exprs": set(), "kind": kind})
    f["size"] = max(f["size"], size)
    v = value_of(expr) if expr is not None else None
    if v is not None: f["values"].add(v)
    elif expr is not None: f["exprs"].add(clean(expr))

def param_writes(fname, pidx, base_off, depth=0, seen=None):
    """fields written through parameter param_<pidx> inside a callee, following it two calls deep"""
    body = funcs.get(fname)
    fields = {}
    seen = seen or set()
    if not body or depth > 3 or (fname, pidx) in seen: return fields
    seen.add((fname, pidx))
    sig = body.split("{", 1)[0]
    p = f"param_{pidx}"
    if "void *this" in sig and pidx == 0: p = "this"
    pt = re.search(r"(\w+) \*" + p + r"\b", sig)
    esz = TSZ.get(pt.group(1), 1) if pt and pt.group(1) not in ("void", "char", "byte", "uchar", "undefined") else 1
    ptype = pt.group(1) if pt else "undefined1"
    for t, cast, off, e in re.findall(r"\*\((\w+) \*\)\((\(int\))?" + p + r" \+ (" + NUM + r")\) = ([^;]+);", body):
        add_field(fields, base_off + ival(off) * (1 if cast else esz), TSZ.get(t, 4), tname(t), e)
    for t, e in re.findall(r"\*\((\w+) \*\)" + p + r" = ([^;]+);", body):
        add_field(fields, base_off, TSZ.get(t, 4), tname(t), e)
    for e in re.findall(r"^\s*\*" + p + r" = ([^;]+);", body, re.M):
        add_field(fields, base_off, esz, tname(ptype, esz), e)
    for off, e in re.findall(r"\b" + p + r"\[(" + NUM + r")\] = ([^;]+);", body):
        add_field(fields, base_off + ival(off) * esz, esz, tname(ptype, esz), e)
    # virtual calls passing the buffer on (receiver assumed to be the preferred class)
    for m in re.finditer(r"\(\*\*\(code \*\*\)\(\*(?:\(int \*\))?\w+ \+ (" + NUM + r")\)\)\(", body):
        slot = ival(m.group(1)) // 4
        tgt = next((f"FUN_{VT[c][slot]:08x}" for c in VT_PREF if slot < len(VT.get(c, []))), None)
        if not tgt: continue
        for i, a in enumerate(call_args(body[m.end():])):
            am = re.fullmatch(r"(?:\(\w+ \*?\))?\(?(\(int\))?" + p + r"(?: \+ (" + NUM + r"))?\)?", a)
            if am:
                o = base_off + ((ival(am.group(2)) * (1 if am.group(1) else esz)) if am.group(2) else 0)
                sub = param_writes(tgt, i + 1, o, depth + 1, seen)
                for so, f in sub.items():
                    for v in f["values"]: add_field(fields, so, f["size"], f["type"], str(v))
                    for e in f["exprs"]: add_field(fields, so, f["size"], f["type"], e)
    for fn, off, rest in re.findall(r"(\w*(?:memcpy|strncpy|strcpy\w*|mbsnbcpy))\(\(?\w* ?\*?\)?\(?(?:\(int\))?" + p + r"(?: \+ (" + NUM + r"))?\)?,([^;]*)\)", body):
        a = call_args(rest)
        n = value_of(a[-1]) if len(a) >= 2 else None
        add_field(fields, base_off + (ival(off) if off else 0), n or 0,
                  (f"char[{n}]" if "str" in fn or "mbs" in fn else f"bytes[{n}]") if n else "bytes[?]",
                  f"{fn} from {clean(a[0])}", "string" if "str" in fn else "blob")
    for m in re.finditer(r"(FUN_[0-9a-f]{8})\(", body):
        args = call_args(body[m.end():])
        for i, a in enumerate(args):
            am = re.fullmatch(r"(?:\(\w+ \*?\))?\(?(\(int\))?" + p + r"(?: \+ (" + NUM + r"))?\)?", a)
            if am:
                o = base_off + ((ival(am.group(2)) * (1 if am.group(1) else esz)) if am.group(2) else 0)
                sub = param_writes(m.group(1), i + 1, o, depth + 1, seen)
                for o, f in sub.items():
                    for v in f["values"]: add_field(fields, o, f["size"], f["type"], str(v))
                    for e in f["exprs"]: add_field(fields, o, f["size"], f["type"], e)
    return fields

# ---------------------------------------------------------------- zone-style global buffer
ZBUF = H.get("zbuf")
VT, VT_PREF = {}, []
if ZBUF and len(sys.argv) > 3:
    # shortcut: virtual fills assume the receiver is ShinePlayer (the class that owns client packets); verify per packet when it matters
    from rtti import vtables
    VT = vtables(sys.argv[3])
    VT_PREF = ["ShineObjectClass::ShinePlayer"]
SENDID = H.get("sendid")

def zone_sites(fname, body):
    sites = []
    lines = body.split("\n")
    alias = {ZBUF: 0}
    start = 0
    fields, opcode = {}, None
    fills = []
    for i, ln in enumerate(lines):
        m = re.match(r"\s*(\w+) = (?:\(\w+ \*\))?\(?" + ZBUF + r"(?: \+ (" + NUM + r"))?\)?;", ln)
        if m:
            alias[m.group(1)] = ival(m.group(2)) if m.group(2) else 0
            continue
        # opcode write
        for a, base in list(alias.items()):
            am = re.escape(a)
            m = re.match(r"\s*\*\(undefined2 \*\)" + am + r" = (" + NUM + r");", ln)
            if m and base == 0:
                opcode = ival(m.group(1)); break
            m = re.match(r"\s*\*\((?:undefined4|undefined \*\*|int|uint) \*\)" + am + r" = (?:&DAT_|\(\w+\))?((?:0x)?[0-9a-f]{5,8});", ln)
            if m and base == 0:
                x = int(m.group(1), 16); opcode = x & 0xffff
                add_field(fields, 2, 2, "u16", str(x >> 16)); break
            m = re.match(r"\s*\*\((\w+) \*\)\(" + am + r" \+ (" + NUM + r")\) = ([^;]+);", ln)
            if m:
                add_field(fields, base + ival(m.group(2)), TSZ.get(m.group(1), 4), tname(m.group(1)), m.group(3)); break
            m = re.match(r"\s*\*\((\w+) \*\)" + am + r" = ([^;]+);", ln)
            if m and base != 0:
                add_field(fields, base, TSZ.get(m.group(1), 4), tname(m.group(1)), m.group(2)); break
            m = re.match(r"\s*" + am + r"\[(" + NUM + r")\] = ([^;]+);", ln)
            if m:
                add_field(fields, base + ival(m.group(1)), 1, "u8", m.group(2)); break
            m = re.search(r"(\w*(?:memcpy|strncpy|strcpy\w*|mbsnbcpy|memset))\(" + am + r"(?: \+ (" + NUM + r"))?,([^,]+)(?:,([^)]+))?\)", ln)
            if m:
                n = value_of(m.group(4) or "") if m.group(4) else None
                kind = "string" if "str" in m.group(1) or "mbs" in m.group(1) else "blob"
                add_field(fields, base + (ival(m.group(2)) if m.group(2) else 0), n or 0,
                          f"char[{n}]" if kind == "string" and n else (f"bytes[{n}]" if n else "bytes[?]"),
                          f"{m.group(1)} from {clean(m.group(3))}", kind); break
            m = re.search(r"(FUN_[0-9a-f]{8})\(([^;]*?)\b" + am + r"(?: \+ (" + NUM + r"))?[,)]", ln)
            if m and "&" + ZBUF not in ln:
                pidx = m.group(2).count(",") + 1
                off = base + (ival(m.group(3)) if m.group(3) else 0)
                sub = param_writes(m.group(1), pidx, off)
                for o, f in sub.items():
                    for v in f["values"]: add_field(fields, o, f["size"], f["type"], str(v))
                    for e in f["exprs"]: add_field(fields, o, f["size"], f["type"], f"[{m.group(1)}] {e}")
                fills.append(f"+{off - 2}: {m.group(1)}" + ("" if sub else " (no direct writes found)"))
                break
            m = re.search(r"\(\*\*\(code \*\*\)\(\*(\w+) \+ (" + NUM + r")\)\)\(([^;]*?)\b" + am + r"(?: \+ (" + NUM + r"))?[,)]", ln)
            if m:
                slot = ival(m.group(2)) // 4
                off = base + (ival(m.group(4)) if m.group(4) else 0)
                tgt = None
                for cls in VT_PREF:
                    if slot < len(VT.get(cls, [])):
                        tgt = (cls, f"FUN_{VT[cls][slot]:08x}"); break
                if tgt:
                    sub = param_writes(tgt[1], m.group(3).count(",") + 1, off)
                    for o, f in sub.items():
                        for v in f["values"]: add_field(fields, o, f["size"], f["type"], str(v))
                        for e in f["exprs"]: add_field(fields, o, f["size"], f["type"], f"[{tgt[1]}] {e}")
                    fills.append(f"+{off - 2}: {tgt[0]}::vfunc[{m.group(2)}] = {tgt[1]} (assumed class)"
                                 + ("" if sub else " (no direct writes found)"))
                else:
                    fills.append(f"+{off - 2}: virtual {m.group(1)}->vtbl[{m.group(2)}] (unresolved)")
                break
        # end of a packet: any call taking (&buf, size) - FUN_004c8ce0 (send) or broadcast helpers
        m = re.search(r"FUN_[0-9a-f]{8}\([^;]*?&" + ZBUF + r",\(?(?:uint\)|short\)|ushort\))?(" + NUM + r"|[^)]+)\)", ln)
        if m:
            if opcode is not None:
                total = value_of(m.group(1))
                sites.append({"op": opcode, "func": fname, "size": None if total is None else total - 2,
                              "size_expr": None if total is not None else clean(m.group(1)),
                              "fields": {o - 2: f for o, f in fields.items() if o >= 2}, "fills": fills})
            fields, opcode, fills = {}, None, []
    return sites

# ---------------------------------------------------------------- stack buffers (login/wm/char)
def stack_sites(fname, body):
    sites = []
    dl = decls(body)
    lines = body.split("\n")
    starts = []  # (line, base_name, hdr, op, size, src)
    for i, ln in enumerate(lines):
        if SENDID:
            m = re.search(SENDID + r"\(", ln)
            if m:
                a = call_args(ln[m.end():])
                if len(a) == 4 and re.search(r"local_[0-9a-f]+", a[0]) and value_of(a[1]) is not None:
                    sz = value_of(a[2])
                    starts.append((i, re.search(r"local_[0-9a-f]+", a[0]).group(0), 5, value_of(a[1]), sz, a[3], clean(a[2])))
    # raw headers: X[0]=len X[1]=lo X[2]=hi  (all three must be constants)
    raw = defaultdict(dict)
    for i, ln in enumerate(lines):
        m = re.match(r"\s*(local_[0-9a-f]+)\[([012])\] = (" + NUM + r");", ln)
        if m: raw[m.group(1)][int(m.group(2))] = (ival(m.group(3)), i)
    for v, kv in raw.items():
        if all(k in kv for k in (0, 1, 2)) and kv[1][0] < 256 and kv[2][0] < 256 and 2 <= kv[0][0] < 256:
            op = kv[2][0] << 8 | kv[1][0]
            if 1 <= op >> 10 <= 63:
                starts.append((min(x[1] for x in kv.values()), v, 3, op, kv[0][0] - 2, "0", None))
    starts.sort()
    for k, (i, base, hdr, op, size, srcp, size_expr) in enumerate(starts):
        lo = starts[k - 1][0] + 1 if k else 0
        hi = starts[k + 1][0] if k + 1 < len(starts) else len(lines)
        B = stack_off(base)
        fields, fills = {}, []
        if srcp not in ("0", "(void *)0x0", "NULL", "(void *)0"):
            add_field(fields, 0, size or 0, f"bytes[{size}]" if size else "bytes[?]", f"memcpy from {clean(srcp)}", "blob")
        lim = size if size is not None else 0x2000
        def off_of(name, extra=0):
            o = stack_off(name)
            if o is None or B is None: return None
            p = B - o - hdr + extra
            return p if 0 <= p < lim else None
        for ln in lines[lo:hi]:
            for name, idx, e in re.findall(r"^\s*(local_[0-9a-f]+)(?:\[(" + NUM + r")\])? = ([^;]+);", ln):
                t, es, cnt = dl.get(name, ("undefined4", 4, 1))
                # base[i], i >= hdr, of a byte buffer is a payload byte (header indices give o = None)
                if name == base and (not idx or es != 1): continue
                o = off_of(name, ival(idx) * es if idx else 0)
                if o is not None:
                    add_field(fields, o, es if idx or cnt > 1 else es, tname(t, es), e)
            for t, name, off, e in re.findall(r"\*\((\w+) \*\)\((local_[0-9a-f]+) \+ (" + NUM + r")\) = ([^;]+);", ln):
                o = off_of(name, ival(off))
                if o is not None: add_field(fields, o, TSZ.get(t, 4), tname(t), e)
            for fn, name, rest in re.findall(r"(\w*(?:memcpy|strncpy|strcpy\w*|mbsnbcpy|sprintf|memset))\((?:\(\w+ \*\))?&?(local_[0-9a-f]+),([^;]*)\)", ln):
                o = off_of(name)
                if o is None: continue
                args = [a.strip() for a in rest.split(",")]
                n = value_of(args[-1]) if "sprintf" not in fn and len(args) >= 2 else None
                t, es, cnt = dl.get(name, ("undefined1", 1, 1))
                n = n or (cnt * es if cnt > 1 else None)
                kind = "string" if any(s in fn for s in ("str", "mbs", "sprintf")) else "blob"
                add_field(fields, o, n or 0, (f"char[{n}]" if kind == "string" else f"bytes[{n}]") if n else "bytes[?]",
                          f"{fn} from {clean(args[0])}" if "memset" not in fn else f"memset {clean(args[0])}", kind)
            for fn, pre, name in re.findall(r"(FUN_[0-9a-f]{8})\(([^;]*?)&?(local_[0-9a-f]+)[,)]", ln):
                o = off_of(name)
                if o is None or fn == SENDID: continue
                sub = param_writes(fn, pre.count(",") + 1, o)
                for so, f in sub.items():
                    for v in f["values"]: add_field(fields, so, f["size"], f["type"], str(v))
                    for e in f["exprs"]: add_field(fields, so, f["size"], f["type"], f"[{fn}] {e}")
                if (sub or dl.get(name, ("", 0, 1))[2] > 1) and (size is None or o < size):
                    fills.append(f"+{o}: {fn}")
        sites.append({"op": op, "func": fname, "size": size, "size_expr": size_expr if size is None else None,
                      "fields": fields, "fills": fills, "raw": hdr == 3})
    return sites

# ---------------------------------------------------------------- C->S reads
FMT_LABEL = re.compile(r"([A-Za-z_][\w.\[\]]*)\s*(?:=|:|\()\s*%[-+ #0-9.]*(?:I64|ll|l|h)?[diuxXsScfp]")

def reads(handler_body):
    sig = handler_body.split("{", 1)[0]
    pk, ln = ("param_1", "param_2") if "void *this" in sig else ("param_2", "param_3")
    m = re.search(r"\b(int|ushort \*|short \*|byte \*|char \*|undefined2 \*|NETCOMMAND \*|void \*) ?" + pk + r"\b", sig)
    if not m: return None
    scale = 2 if m.group(1).replace(" ", "") in ("ushort*", "short*", "undefined2*") else 1
    pat = [
        (r"\*\((\w+) \*\)\((\(int\))?" + pk + r" \+ (" + NUM + r")\)", lambda g: (g[0], ival(g[2]) * (1 if g[1] else scale))),
        (r"\((char|uchar|byte|undefined1|undefined4|undefined) \*\)\((\(int\))?" + pk + r" \+ (" + NUM + r")\)", lambda g: ("ptr", ival(g[2]) * (1 if g[1] else scale))),
    ]
    if scale == 2:
        pat.append((r"(\(byte\)|\(char\))?" + pk + r"\[(" + NUM + r")\]", lambda g: ("byte" if g[0] else "ushort", ival(g[1]) * 2)))
    fields = {}
    for rx, conv in pat:
        for mm in re.finditer(rx, handler_body):
            t, o = conv(mm.groups())
            if o < 2: continue
            f = fields.setdefault(o - 2, {"type": "char*" if t == "ptr" else tname(t), "size": 0 if t == "ptr" else TSZ.get(t, 4),
                                         "names": set(), "checks": set(), "copied": set()})
            ctx = handler_body[max(0, mm.start() - 120): mm.end() + 120]
            tail = handler_body[mm.end(): mm.end() + 40]
            c = re.match(r"\)?\s*(==|!=|<=|>=|<|>)\s*(-?" + NUM + r")", tail)
            if c: f["checks"].add(f"{c.group(1)} {c.group(2)}")
            cp = re.search(r"(\w*(?:strncpy|memcpy|mbsnbcpy|strcpy\w*))\([^,]+,[^,]*" + re.escape(mm.group(0)) + r"[^,]*,\s*(" + NUM + r")\)", ctx)
            if cp:
                f["copied"].add(f"{cp.group(1)} n={cp.group(2)}")
                if f["type"] == "char*": f["size"] = max(f["size"], ival(cp.group(2)))
    # names from format strings
    for mm in re.finditer(r'\(([^;]*?)"([^"]*%[^"]*)"\s*,', handler_body):
        fmt = mm.group(2)
        args = call_args(handler_body[mm.end():])
        specs = re.findall(r"%[-+ #0-9.]*(?:I64|ll|l|h)?[diuxXsScfp]", fmt)
        labels = []
        pos = 0
        for s in specs:
            j = fmt.index(s, pos)
            lab = re.search(r"([A-Za-z_][\w.]*)\s*(?:=|:|\()?\s*$", fmt[max(0, j - 24):j])
            labels.append(lab.group(1) if lab else None)
            pos = j + len(s)
        for lab, a in zip(labels, args):
            if not lab: continue
            for rx, conv in pat:
                am = re.search(rx, a)
                if am:
                    t, o = conv(am.groups())
                    if o >= 2 and (o - 2) in fields: fields[o - 2]["names"].add(lab)
    lens = sorted({f"{op} {v}" for op, v in re.findall(r"\b" + ln + r" (!=|==|<|>|<=|>=) (" + NUM + r")\b", handler_body)})
    return {"fields": fields, "len_checks": lens}

# ---------------------------------------------------------------- run
s2c = defaultdict(list)
for fname, body in funcs.items():
    if ZBUF and ZBUF in body:
        for s in zone_sites(fname, body): s2c[s["op"]].append(s)
    if (SENDID and SENDID in body) or re.search(r"local_[0-9a-f]+\[2\] = ", body):
        for s in stack_sites(fname, body): s2c[s["op"]].append(s)

c2s = {}
for t in H["tables"]:
    for e in t["entries"]:
        b = funcs.get(e["handler"].replace("LAB_", "FUN_"))
        if b:
            r = reads(b)
            if r: c2s.setdefault(f"0x{e['op']:04x}", {})[t["parser"]] = dict(r, handler=e["handler"], name=e.get("name"))

def ser(o):
    if isinstance(o, set): return sorted(o, key=str)
    raise TypeError(o)
out = {"s2c": {f"0x{k:04x}": v for k, v in sorted(s2c.items())}, "c2s": c2s}
json.dump(out, open(f"{d}/layouts.json", "w"), default=ser, indent=1)
print(f"send sites: {sum(len(v) for v in s2c.values())} over {len(s2c)} opcodes; "
      f"handlers with reads: {sum(len(v) for v in c2s.values())}")
