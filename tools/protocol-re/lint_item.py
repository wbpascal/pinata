#!/usr/bin/env python3
"""Mechanical checks of a work item's output, run before any review (and on every delegated draft).

usage: lint_item.py <ID> [--root DIR]      DIR = repo or worktree holding the item's output (default: this repo)

Checks (ERROR = almost certainly wrong, WARN = look at it):
  names    annotation opcode names vs docs/protocol/opcodes.json (names read from the binaries or the 2017 PDB)
  layout   annotation field offsets / names vs the 2017 PDB struct PROTO_<name>, nested structs flattened;
           tried with and without the 6-byte zone header / ref prefix, the better fit is reported
  void     doc lines claiming a callee "returns void / nothing / leftover EAX": shows what each cited function
           puts in EAX before every `ret` (Ghidra often types bool helpers as void)
  bugs     bug table IDs without gaps, and one inline `(original bug)` tag per row
Exit code 1 when an ERROR was found.
"""
import glob, json, os, re, subprocess, sys
from functools import lru_cache

R = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
PDB = f"{R}/Files/Client/2017/Fiesta.pdb"
EXE = {"wm": "Files/Server/2016/w00_WorldManager/4WorldManagerServer2.exe",
       "zone": "Files/Server/2016/w00_Zone00/5ZoneServer2.exe",
       "character": "Files/Server/2016/w00_Character/Character Release.exe",
       "login": "Files/Server/2016/Login/3LoginServer2.exe",
       "account": "Files/Server/2016/Account/Account Release.exe",
       "accountlog": "Files/Server/2016/AccountLog/AccountLog Release.exe",
       "gamelog": "Files/Server/2016/w00_GameLog/GameLog Release.exe",
       "client": "Files/Client/2016/Fiesta.bin"}
VOID = re.compile(r"\bvoid\b|returns? nothing|no return value|without a return value|leftover EAX|stale (register|EAX)", re.I)
PRIM = re.compile(r"^(u?char|u?short|u?long|u?int|long|short|char|bool|float|double|wchar_t|unsigned .*|__int64|Name\d+)$")
problems = {"ERROR": 0, "WARN": 0}


def report(level, check, msg):
    problems[level] += 1
    print(f"{level:5} {check:6} {msg}")


@lru_cache(None)
def pdb_type(name):
    """{size, fields: [(off, type, name)]} of a PDB struct/union, or None."""
    out = subprocess.run([sys.executable, "-I", f"{R}/tools/protocol-re/pdb.py", PDB, "types", f"^{re.escape(name)}$"],
                         capture_output=True, text=True).stdout
    m = re.search(r"^(struct|union) \S+ \{ // size 0x([0-9a-f]+)", out, re.M)
    if not m:
        return None
    fields = [(int(o, 16), t, n) for o, t, n in re.findall(r"/\*0x([0-9a-f]+)\*/ (.+?) (\w+);", out)]
    return {"size": int(m.group(2), 16), "union": m.group(1) == "union", "fields": fields}


def leaves(name, base=0, prefix=""):
    """Flatten a PDB struct to [(start, end, dotted name)]; strings, arrays, unions and primitives are leaves."""
    t = pdb_type(name)
    out = []
    if not t:
        return out
    offs = sorted({o for o, _, _ in t["fields"]})
    for off, typ, fname in t["fields"]:
        typ = re.sub(r":\d+@\d+$", "", typ)  # bitfield
        end = next((o for o in offs if o > off), t["size"])  # fields are packed: a field ends where the next starts
        sub = None if (PRIM.match(typ) or "[" in typ or "*" in typ) else pdb_type(typ)
        if sub and not sub["union"]:
            out += leaves(typ, base + off, f"{prefix}{fname}.")
        else:
            out.append((base + off, base + end, prefix + fname))
    return out


def norm(n):
    n = re.sub(r"\[.*", "", n).split(".")[-1]
    return re.sub(r"^(n|s|b|d|h|w|dw|sz|by|p)(?=[A-Z0-9])", "", n).lower()


def check_layout(op, ann):
    base = leaves(f"PROTO_{ann['name']}")
    if not base:
        return
    size = max(e for _, e, _ in base) if base else 0
    best = None
    for shift in (0, 6):
        errs, warns = [], []
        starts, where = {}, {}
        for s, e, n in base:
            starts.setdefault(s, []).append(n)
            if "header." not in n.lower():  # nested packet headers repeat clienthandle/charregistnumber
                where.setdefault(norm(n), s)
        for f in ann["fields"]:
            o = f[0] - shift
            if o < 0 or o >= size:
                continue
            hit = [(s, e, n) for s, e, n in base if s <= o < max(e, s + 1)]
            if [n for _, _, n in hit if norm(n) == norm(f[2])]:
                continue  # the field itself, or an element 'X[3]' inside PDB array X
            if norm(f[2]) in where and where[norm(f[2])] != o and o not in [s for s, _, n in base if norm(n) == norm(f[2])]:
                errs.append(f"@{f[0]} '{f[2]}' but PDB has that field @{where[norm(f[2])] + shift}")
            elif o in starts:
                if norm(f[2]) not in {norm(n) for n in starts[o]} | {norm(n.split(".")[0]) for n in starts[o]}:
                    warns.append(f"@{f[0]} '{f[2]}' where PDB has {'/'.join(starts[o])}")
            elif hit:
                errs.append(f"@{f[0]} '{f[2]}' starts inside PDB field {hit[0][2]} @{hit[0][0] + shift}")
        if best is None or (len(errs), len(warns)) < (len(best[1]), len(best[2])):
            best = (shift, errs, warns)
    shift, errs, warns = best
    tag = f"{op} {ann['name']}" + (" (+6 prefix)" if shift else "")
    for e in errs:
        report("ERROR", "layout", f"{tag}: {e}")
    if warns:
        report("WARN", "layout", f"{tag}: field names differ from PDB: " + "; ".join(warns[:4]) + (" …" if len(warns) > 4 else ""))


def check_annotations(path):
    ops = {o["op"]: o for o in json.load(open(f"{R}/docs/protocol/opcodes.json"))}
    for binname, pk in json.load(open(path)).get("packets", {}).items():
        for op, ann in pk.items():
            ref = ops.get(op.lower())
            if ref and ref["name"] and ann.get("name") != ref["name"]:
                report("ERROR", "names", f"{op}: '{ann.get('name')}' but opcodes.json has '{ref['name']}' ({ref['name_source']})")
            elif not ref or not ref["name"]:
                report("WARN", "names", f"{op}: '{ann.get('name')}' not confirmed by any binary or the PDB")
            if ann.get("name"):
                check_layout(op, ann)


@lru_cache(None)
def func_bounds(binname):
    addrs = sorted(int(a, 16) for a in re.findall(r"^//==== FUNC ([0-9a-f]{8})",
                                                   open(f"{R}/re-data/exports/{binname}/decomp.c").read(), re.M))
    return addrs


def eax_at_returns(binname, addr):
    """One summary per `ret`: the last instruction before it that writes EAX/AL (or 'none')."""
    addrs = func_bounds(binname)
    nxt = next((a for a in addrs if a > addr), addr + 0x400)
    asm = subprocess.run(["objdump", "-d", "-M", "intel", f"--start-address={addr:#x}", f"--stop-address={nxt:#x}",
                          f"{R}/{EXE[binname]}"], capture_output=True, text=True).stdout
    ins = [" ".join(l.split("\t")[1:]).strip() for l in asm.splitlines() if re.match(r"\s+[0-9a-f]+:", l)]
    out = []
    for i, x in enumerate(ins):
        if not x.startswith("ret"):
            continue
        w = "none"
        for y in reversed(ins[max(0, i - 12):i]):
            if y.startswith("call") and not w == "none":
                break
            if re.match(r"(mov|xor|or|and|sub|add|sbb|neg|set\w+|movzx|lea|pop) (eax|al)\b", y) or y.startswith("call"):
                w = y
                if not y.startswith("call"):
                    break
        out.append(w)
    return out


def check_doc(doc, binname):
    txt = open(doc).read()
    seen = set()
    for ln, line in enumerate(txt.splitlines(), 1):
        if not VOID.search(line) or re.search(r"return(s|ing)? (a |an )?(bool|value|int\b|1\b)|in `?EAX`?", line, re.I):
            continue  # no claim, or the line already says it returns something
        for a in re.findall(r"FUN_([0-9a-f]{8})", line):
            if a in seen or binname not in EXE:
                continue
            seen.add(a)
            rets = eax_at_returns(binname, int(a, 16))
            sets = [r for r in rets if r != "none" and not r.startswith("call")]
            if sets:
                report("ERROR", "void", f"{os.path.basename(doc)}:{ln} FUN_{a} treated as void, but sets EAX before ret: {'; '.join(sets[:3])}")
            elif rets:
                report("WARN", "void", f"{os.path.basename(doc)}:{ln} FUN_{a} void claim: EAX before ret = {'; '.join(rets[:3])} (check)")
    ids = [int(n) for n in re.findall(r"^\|\s*[A-Z]\d+-B(\d+)\s*\|", txt, re.M)]
    if ids:
        missing = sorted(set(range(1, max(ids) + 1)) - set(ids))
        if missing:
            report("WARN", "bugs", f"{os.path.basename(doc)}: bug IDs missing: {missing}")
        tags = txt.count("(original bug)")
        if tags < len(ids):  # one description may cover two rows, so only "none at all" is an error
            report("ERROR" if tags == 0 else "WARN", "bugs",
                   f"{os.path.basename(doc)}: {len(ids)} bug rows but only {tags} inline `(original bug)` tags")


def main(a):
    if not a or a[0].startswith("-"):
        sys.exit(__doc__)
    iid, root = a[0], (a[a.index("--root") + 1] if "--root" in a else R)
    docs = glob.glob(f"{root}/docs/pseudocode/*/{iid}-*.md")
    plan = open(f"{R}/docs/plan/items/{iid}.md").read() if os.path.exists(f"{R}/docs/plan/items/{iid}.md") else ""
    binname = (re.findall(r"### `(\w+)` ·", plan) or ["?"])[0]
    ann = f"{root}/docs/protocol/annotations/{iid}.json"
    if os.path.exists(ann):
        check_annotations(ann)
    for d in docs:
        check_doc(d, binname)
    print(f"{iid}: {problems['ERROR']} errors, {problems['WARN']} warnings")
    sys.exit(1 if problems["ERROR"] else 0)


if __name__ == "__main__":
    main(sys.argv[1:])
