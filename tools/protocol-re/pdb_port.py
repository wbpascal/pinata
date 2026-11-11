#!/usr/bin/env python3
"""Port 2017 client PDB function names to the 2016 client (work item C02).

  python3 -I tools/protocol-re/pdb_port.py            # writes tools/protocol-re/names/client/C02.json, prints stats

Evidence level pdb2017 (see docs/knowledge/C02.md). Three passes, each only adds unambiguous names:
  1. opcode: the 2016 handler of an opcode (C01 re-data/client-handlers.json) gets the 2017 `Class::On_NC_*` /
     `Recv_NC_*` method for the same opcode value, same scene class first.
  2. bytes: functions whose first bytes (call targets and image addresses masked) are unique in both builds.
  3. calls: callees at the same call position in matched pairs, when every matched pair votes the same way
     (needs functions.tsv from ExportFuncs.java in re-data/exports/client and re-data/exports/client2017).
Names C01 already gave are kept (reported, not overwritten).
"""
import collections, json, os, re, sys

R = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(R, 'tools/protocol-re'))
import pdb as P          # noqa: E402  (our PDB reader, not the debugger)
from rtti import PE      # noqa: E402

EXE16, EXE17 = f'{R}/Files/Client/2016/Fiesta.bin', f'{R}/Files/Client/2017/Fiesta.bin'
OUT = f'{R}/tools/protocol-re/names/client/C02.json'


def pretty(m):
    """mangled public -> Class::method (ctor/dtor spelled out), None for compiler-generated names"""
    if m.startswith('??0') or m.startswith('??1'):
        parts = m[3:].split('@@', 1)[0].split('@')
        cls = '::'.join(reversed(parts))
        return cls + '::' + ('~' if m[2] == '1' else '') + parts[0]
    if m.startswith('??') or m.startswith('__') or m.startswith('$'):
        return None
    return P.demangle_hint(m).lstrip('_') if m.startswith('_') and '@' not in m else P.demangle_hint(m)


def signature(pe, va, size, n=96):
    """first n bytes, with E8/E9 rel32 and image-range dwords masked; None if too short to be distinctive"""
    o = pe.off(va)
    if o is None or size < 12:
        return None
    b = bytearray(pe.b[o:o + min(size, n)])
    lo, hi = pe.base, pe.base + 0x2000000
    i = 0
    while i < len(b):
        if b[i] in (0xE8, 0xE9) and i + 5 <= len(b):
            b[i + 1:i + 5] = b'\0\0\0\0'; i += 5; continue
        if i + 4 <= len(b) and lo <= int.from_bytes(b[i:i + 4], 'little') < hi:
            b[i:i + 4] = b'\xAA' * 4; i += 4; continue
        i += 1
    return bytes(b) + size.to_bytes(4, 'little') if size <= n else bytes(b)


def funcs16():
    """entry -> size (functions.tsv if exported, else gaps between decomp.c entries)"""
    ft = f'{R}/re-data/exports/client/functions.tsv'
    if os.path.exists(ft):
        return {int(l.split('\t')[0], 16): int(l.split('\t')[1]) for l in open(ft)}
    s = sorted(int(m, 16) for m in re.findall(r'^//==== FUNC ([0-9a-f]{8})', open(f'{R}/re-data/exports/client/decomp.c').read(), re.M))
    return {a: b - a for a, b in zip(s, s[1:])}


def calls(path):
    """functions.tsv -> entry -> [callee entries in call order]"""
    if not os.path.exists(path):
        return None
    out = {}
    for l in open(path):
        a, _, _, c = l.rstrip('\n').split('\t')
        out[int(a, 16)] = [int(x, 16) if ':' not in x else -1 for x in c.split(',') if x]   # -1 = EXTERNAL import
    return out


def main():
    msf = P.MSF(f'{R}/Files/Client/2017/Fiesta.pdb')
    pubs = [(va, m) for va, m, fn in P.publics(msf, EXE17) if fn]
    name17, f17 = {}, None
    for va, m in pubs:
        n = pretty(m)
        if n:
            name17.setdefault(va, n)
    ft17 = f'{R}/re-data/exports/client2017/functions.tsv'
    if os.path.exists(ft17):         # Ghidra with the PDB applied: real sizes, static functions named too
        f17 = {}
        for l in open(ft17):
            a, z, n, _ = l.rstrip('\n').split('\t')
            a = int(a, 16); f17[a] = int(z)
            if not re.match(r'(thunk_)?FUN_|LAB_|Unwind@|Catch@|`', n.split('::')[-1]):
                name17.setdefault(a, n)
    sim = lambda x, y: x is not None and y is not None and abs(x - y) <= max(16, max(x, y) // 4)
    st = collections.Counter()
    match = {}                       # 2016 entry -> 2017 entry
    src = {}

    # 1. opcode handlers
    H17 = collections.defaultdict(list)
    for va, n in name17.items():
        mm = re.search(r'(?:^|::)(?:On_Recv|On|Recv|ON)_(NC_\w+)$', n)
        if mm:
            H17[mm.group(1)].append((n.rsplit('::', 1)[0].split('::')[-1] if '::' in n else '', va))
    PL = json.load(open(f'{R}/docs/protocol/pdb-layouts.json'))['opcodes']
    CAT = {c['op']: c for c in json.load(open(f'{R}/docs/protocol/opcodes.json'))}
    votes = collections.defaultdict(set)
    for op, v in json.load(open(f'{R}/re-data/client-handlers.json')).items():
        e = PL.get(op.lower())
        names = ([e['name']] + e.get('aliases', [])) if e else []
        if CAT.get(op.lower(), {}).get('name') not in names + [None]:
            names.append(CAT[op.lower()]['name'])
        for h in [v] + v['other_handlers']:
            if not h.get('func'):
                continue
            cands = [x for n in names for x in H17.get(n, [])]
            same = [x for x in cands if x[0] == (h.get('scene') or '').split(':')[-1]]
            pick = same or (cands if len(cands) == 1 else [])
            if pick:
                votes[int(h['func'][4:], 16)].add(pick[0][1])
    folded, f16 = {}, funcs16()
    if f17 is None:
        s17 = sorted(name17)
        f17 = {a: b - a for a, b in zip(s17, s17[1:])}
    for a, vs in votes.items():
        vs = sorted(vs)
        if len(vs) > 1:              # one 2016 function serves several 2017 handlers: a shared helper, no name
            folded[a] = [name17[x] for x in vs]
            continue
        if not sim(f16.get(a), f17.get(vs[0])):
            st['opcode: size differs, dropped'] += 1   # 2016 dispatcher calls a helper, 2017 On_* wraps it
            continue
        match[a], src[a] = vs[0], 'opcode'
    st['opcode'] = len(match)

    # 2. byte signatures, unique on both sides
    pe16, pe17 = PE(EXE16), PE(EXE17)
    def index(pe, fs):
        d = collections.defaultdict(list)
        for a, n in fs.items():
            s = signature(pe, a, n)
            if s:
                d[s].append(a)
        return {s: v[0] for s, v in d.items() if len(v) == 1}
    i16, i17 = index(pe16, f16), index(pe17, f17)
    checked = collections.Counter()
    for s, a in i16.items():
        b = i17.get(s)
        if b is None:
            continue
        if not sim(f16.get(a), f17.get(b)):
            continue
        if a in match:
            checked['agree' if match[a] == b else 'disagree (bytes win)'] += 1
            if match[a] != b and '-v' in sys.argv:
                print('  disagree FUN_%08x opcode->%s bytes->%s' % (a, name17.get(match[a]), name17.get(b)))
            if match[a] == b:
                continue
        match[a], src[a] = b, 'bytes'
        st['bytes'] += 1
    print('pass 2 cross-check of pass 1 (opcode pairs with a unique byte match):', dict(checked))

    # 3. call graph propagation
    c16, c17 = calls(f'{R}/re-data/exports/client/functions.tsv'), calls(f'{R}/re-data/exports/client2017/functions.tsv')
    if c16 and c17:
        for rnd in range(10):
            used = set(match.values())
            prop = collections.defaultdict(set)
            for a, b in list(match.items()):
                x, y = c16.get(a, []), c17.get(b, [])
                if len(x) != len(y):
                    continue
                for p, q in zip(x, y):
                    if p >= 0 and q >= 0 and p not in match and q in name17 and sim(f16.get(p), f17.get(q)):
                        prop[p].add(q)
            new = {p: next(iter(q)) for p, q in prop.items() if len(q) == 1}
            inv = collections.Counter(new.values())
            new = {p: q for p, q in new.items() if inv[q] == 1 and q not in used}
            if not new:
                break
            for p, q in new.items():
                match[p], src[p] = q, 'calls'
            st['calls'] += len(new)
    else:
        print('pass 3 skipped: functions.tsv missing (run ExportFuncs.java, see docs/knowledge/C02.md)')

    c01 = json.load(open(f'{R}/tools/protocol-re/names/client/C01.json'))
    out, kept = {}, []
    for a, b in sorted(match.items()):
        k = 'FUN_%08x' % a
        n = name17.get(b)
        if not n:
            continue
        if k in c01:
            kept.append((k, c01[k], n))
            continue
        out[k] = n
    dup = collections.Counter(out.values())
    for k, n in list(out.items()):  # same 2017 name on two 2016 functions: keep both, mark which is which
        if dup[n] > 1:
            out[k] = '%s_%s' % (n, k[4:])
    json.dump(out, open(OUT, 'w'), indent=1, sort_keys=True)
    print(dict(st), 'named', len(out), 'by source', collections.Counter(src[int(k[4:], 16)] for k in out))
    print('C01 names kept (2017 name differs or equal):', len(kept), sum(1 for _, x, y in kept if x != y), 'differ')
    for k, x, y in kept:
        if x != y:
            print('  C01', k, x, '| 2017:', y)
    print('folded (one 2016 func, two 2017 handlers):', len(folded))
    for a, ns in sorted(folded.items()):
        print('  FUN_%08x' % a, ' = '.join(ns))


if __name__ == '__main__':
    main()
