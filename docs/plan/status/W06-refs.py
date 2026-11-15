# W06: references to functions in a PE: absolute 4-byte values anywhere + E8/E9 rel32 in the first section.
# usage (repo root): python3 -I docs/plan/status/W06-refs.py Files/Server/2016/w00_WorldManager/4WorldManagerServer2.exe 45bdb0 ...
import sys, struct, collections
sys.path.insert(0, "tools/protocol-re")
from rtti import PE
pe = PE(sys.argv[1]); b = pe.b
tg = {int(a, 16) for a in sys.argv[2:]}
absr = collections.defaultdict(list); rel = collections.defaultdict(list)
for i in range(0, len(b) - 4):
    v = struct.unpack_from("<I", b, i)[0]
    if v in tg: absr[v].append(hex(pe.va(i) or 0))
sva, size, rp, rs = pe.secs[0]
for j in range(rp, rp + rs - 5):
    if b[j] in (0xE8, 0xE9):
        d = struct.unpack_from("<i", b, j + 1)[0]
        t = pe.va(j) + 5 + d
        if t in tg: rel[t].append(hex(pe.va(j)))
for t in sorted(tg):
    print(hex(t), "abs", len(absr[t]), absr[t], "rel", len(rel[t]), rel[t])   # full lists (an earlier [:6] cut hid callers)
