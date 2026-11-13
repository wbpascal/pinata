#!/usr/bin/env python3
"""Official names from the NA2016 server PDBs for the 2016 exports (work item S01).

  python3 -I tools/protocol-re/pdb_names.py

The NA2016 PDBs match the 2016 server builds exactly (same RSDS GUID/age), so their names are facts about the 2016 code.
Writes per binary:
  tools/protocol-re/names/<bin>/S01.json   FUN_/DAT_ -> official name, for addresses no other item has named yet
                                           (item files sort after S01.json except C02/D0x, so item names keep winning)
  docs/knowledge/S01-renames.tsv           bin, address, item, our name, official name: the follow-up list per item
Function names come from re-data/exports/<bin>-pdb (Ghidra with the PDB loaded: publics + private procedures);
global names from the PDB public symbols.
"""
import glob, json, os, re, sys

R = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(R, 'tools/protocol-re'))
import pdb as P  # noqa: E402  (our PDB reader)

NA = f'{R}/Files/Server/NA2016'
BINS = {'login': 'Login/Login', 'wm': 'WorldManager/WorldManager', 'zone': 'Zone00/Zone',
        'account': 'Account/Account', 'accountlog': 'AccountLog/AccountLog'}
FUNC = re.compile(r'^//==== FUNC ([0-9a-f]{8}) (\S+)$', re.M)


def funcs(export):
    return dict(FUNC.findall(open(f'{R}/re-data/exports/{export}/decomp.c', encoding='utf-8', errors='replace').read()))


def global_name(m):
    """mangled data public -> readable name, or None for compiler data (string literals, RTTI, floats)."""
    v = re.match(r'\?\?_7(.+?)@@6B', m)
    if v: return '::'.join(reversed(v.group(1).split('@'))) + '::vftable'
    if m.startswith('??_') or m.startswith('__real@') or m.startswith('__xmm@'): return None
    return P.demangle_hint(m)


def main():
    rows = []
    for b, p in BINS.items():
        old, new = funcs(b), funcs(f'{b}-pdb')
        mine = {}
        for f in sorted(glob.glob(f'{R}/tools/protocol-re/names/{b}/*.json')):
            if not f.endswith('/S01.json'):
                for k, v in json.load(open(f)).items(): mine[k] = (os.path.basename(f)[:-5], v)
        out = {}
        for a, n in old.items():
            off = new.get(a)
            if not off or off.startswith('FUN_'): continue
            k = f'FUN_{a}'
            if k in mine: rows.append((b, k, *mine[k], off))
            else: out[k] = off
        msf = P.MSF(f'{NA}/{p}.pdb')
        for va, m, isfn in P.publics(msf, f'{NA}/{p}.exe'):
            g = None if isfn else global_name(m)
            k = f'DAT_{va:08x}'
            if not g: continue
            if k in mine: rows.append((b, k, *mine[k], g))
            else: out[k] = g
        json.dump(dict(sorted(out.items())), open(f'{R}/tools/protocol-re/names/{b}/S01.json', 'w'), indent=0)
        nf = sum(k.startswith('FUN_') for k in out)
        print(f'{b}: {len(old)} functions, {nf} newly named, {len(out) - nf} globals; '
              f'{sum(r[0] == b for r in rows)} item names to replace')
    with open(f'{R}/docs/knowledge/S01-renames.tsv', 'w') as w:
        w.write('bin\taddress\titem\tour name\tofficial name\n')
        for r in sorted(rows, key=lambda r: (r[2], r[0], r[1])): w.write('\t'.join(r) + '\n')


if __name__ == '__main__':
    main()
