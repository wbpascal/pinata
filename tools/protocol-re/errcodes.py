"""Extract the client's error-code -> message mapping (Fiesta.bin FUN_00416430, a big switch over the code).

usage: python3 -I errcodes.py <client export dir> <ressystem dir> > errors.json
Each case calls a text lookup with a 32-bit text id (resolved here against TextData*.shn) or returns a literal.
"""
import json, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shn import read

exp, res = sys.argv[1], sys.argv[2]
FUNC = sys.argv[3] if len(sys.argv) > 3 else "00416430"
src = open(f"{exp}/decomp.c", encoding="utf-8", errors="replace").read()
body = re.search(r"^//==== FUNC " + FUNC + r" \S+\n(.*?)(?=^//==== FUNC |\Z)", src, re.S | re.M).group(1)

texts = {}
for f in ("TextData", "TextData2", "TextData3"):
    cols, rows = read(f"{res}/{f}.shn")
    for r in rows: texts.setdefault(r[0], (f, r[3]))

NUM = r"(0x[0-9a-f]+|\d+)"
def iv(s): return int(s, 16) if s.startswith("0x") else int(s)

result, gotos, label_val = {}, {}, {}
pending, cur_label = [], None
for ln in body.split("\n"):
    s = ln.strip()
    m = re.match(r"(\w+):$", s)
    if m: cur_label = m.group(1); continue
    for v in re.findall(r"case " + NUM + ":", s): pending.append(iv(v))
    m = re.search(r"param_1 == " + NUM + r"\)", s)
    if m and "if" in s: pending.append(iv(m.group(1)))
    m = re.match(r"goto (\w+);", s)
    if m:
        for p in pending: gotos[p] = m.group(1)
        pending = []; continue
    val = None
    m = re.search(r"(FUN_[0-9a-f]{8})\((0x[0-9a-f]+|\d+)\)", s)
    if m and "pcVar" in s:
        tid = iv(m.group(2))
        val = {"text_id": f"0x{tid:08x}", "lookup": m.group(1), "text": texts.get(tid, (None, None))[1], "table": texts.get(tid, (None, None))[0]}
    m2 = re.match(r'return "([^"]*)";', s)
    if m2: val = {"literal": m2.group(1)}
    if val:
        for p in pending: result[p] = val
        if cur_label: label_val[cur_label] = val
        pending, cur_label = [], None
for code, lab in gotos.items():
    if lab in label_val and code not in result: result[code] = label_val[lab]

out = {f"0x{k:04x}": v for k, v in sorted(result.items())}
assert len(out) > 50, "switch parse failed"
json.dump(out, sys.stdout, indent=1, ensure_ascii=False)
print(f"\n{len(out)} codes, {sum(1 for v in out.values() if v.get('text'))} with resolved text", file=sys.stderr)
