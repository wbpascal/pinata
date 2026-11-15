#!/usr/bin/env python3
"""X01 bug register: collects every `<item>-B<n>` table row of docs/pseudocode/**/*.md and docs/knowledge/*.md
into docs/pseudocode/README.md §6 (between the register markers).

usage (repo root):  python3 -I docs/plan/status/X01-register.py write   # rewrite the register in README.md
                    python3 -I docs/plan/status/X01-register.py stats   # rows per file, duplicates, headers
                    python3 -I docs/plan/status/X01-register.py md      # print the register

Rules: a row's ID cell matches `<item>-B<n>`; the copy in the owning item's file wins (L00 = login-server.md,
S01 = knowledge/S01.md); other files holding the same ID are listed as "also". Skipped: verdict tables without a
bug-table header (knowledge/Z09.md, Z13.md) and S01 §1.4 (hints already owned by W04, repeats of S01 §7).
X01's own additions (free-text bugs of pre-convention items, client mismatches) live in EXTRA, superseded
entries in SUPERSEDED (ID -> note, links README §5)."""
import re, sys, glob, json, collections

ROW = re.compile(r'^\|\s*\(?([A-Z]\d{2}-B\d+[a-z]?)\)?\s*\|(.*)\|\s*$')
H = re.compile(r'^(#{2,4})\s+(.*)$')

def anchor(h):
    a = h.strip().lower()
    a = re.sub(r'[^\w\- ]', '', a)
    return a.replace(' ', '-')

def split_cells(s):
    # split on | not inside backticks
    cells, cur, tick = [], '', False
    prev = ''
    for ch in s:
        if ch == '`':
            tick = not tick
        if ch == '|' and not tick and prev != '\\':
            cells.append(cur.strip()); cur = ''
        else:
            cur += ch
        prev = ch
    cells.append(cur.strip())
    return cells

files = sorted(glob.glob('docs/pseudocode/**/*.md', recursive=True) + glob.glob('docs/knowledge/*.md'))
files = [f for f in files if not f.endswith(('FORMAT.md', 'README.md'))]
rows = []
for f in files:
    head = None; header = None
    for i, line in enumerate(open(f, encoding='utf-8'), 1):
        m = H.match(line)
        if m:
            head = m.group(2); header = None
            continue
        if line.startswith('| ') and ('2016 behaviour' in line or 'Behaviour' in line):
            header = split_cells(line.strip()[1:-1])
            continue
        m = ROW.match(line.rstrip('\n'))
        if not m:
            continue
        cells = split_cells(m.group(2))
        rows.append(dict(id=m.group(1), file=f, line=i, head=head, header=header, cells=cells,
                         paren=line.lstrip('| ').startswith('(')))

if sys.argv[1] == 'stats':
    c = collections.Counter(r['file'] for r in rows)
    for f, n in sorted(c.items()):
        print(n, f)
    ids = collections.defaultdict(list)
    for r in rows:
        ids[r['id']].append(f"{r['file']}:{r['line']}")
    d = {k: v for k, v in ids.items() if len(v) > 1}
    print('total', len(rows), 'unique', len(ids), 'dups', len(d))
    for k, v in list(d.items())[:40]:
        print(' dup', k, v)
    hs = collections.Counter(tuple(r['header'] or ()) for r in rows)
    for h, n in hs.items():
        print(n, h)
    nc = collections.Counter(len(r['cells']) for r in rows)
    print('ncells', nc)
elif sys.argv[1] == 'json':
    json.dump(rows, sys.stdout, indent=0)

def split_plain(s):
    return [c.strip() for c in re.split(r'(?<!\\)\|', s)]

SERVER = {'L00': 'Login', 'L01': 'Login', 'D01': 'Account / AccountLog', 'D02': 'Character', 'D03': 'Character',
          'D04': 'Character', 'D07': 'Character', 'D05': 'GameLog', 'D06': 'DB procedures', 'S02': 'Shared library'}
GROUPS = [('Login', ['L00', 'L01']), ('Account / AccountLog', ['D01']), ('WorldManager', ['W']),
          ('Zone', ['Z']), ('Character', ['D02', 'D03', 'D04', 'D07']), ('GameLog', ['D05']),
          ('Database (inferred procedures)', ['D06']), ('Shared library (Login / WM / Zone)', ['S02']),
          ('Found while reading the 2016 server PDBs', ['S01'])]

def owner_file(item, f):
    b = f.split('/')[-1]
    if item == 'L00': return b == 'login-server.md'
    if item == 'S01': return f == 'docs/knowledge/S01.md'
    return b.startswith(item + '-') or b == item + '.md'

def server(item):
    return SERVER.get(item) or {'W': 'WM', 'Z': 'Zone'}.get(item[0], item)

def evidence(cells):
    t = ' '.join(cells)
    ev = []
    if '(captured)' in t or 'captured' in t.lower() and 'capture' in cells[1].lower(): ev.append('*(captured)*')
    beh = cells[1]; eff = cells[2] if len(cells) > 2 else ''
    if 'inferred' in beh: ev.append('*(inferred)*')
    elif 'inferred' in eff or 'inferred' in (cells[3] if len(cells) > 3 else ''): ev.append('code; effect *(inferred)*')
    if 'db-backup' in t: ev.append('*(db-backup)*')
    if 'pdb2017' in t: ev.append('*(pdb2017)*')
    if 'fh-doc' in t: ev.append('*(fh-doc)*')
    if not ev or ev[0].startswith('*(db') or ev[0].startswith('*(pdb') or ev[0].startswith('*(fh'):
        ev.insert(0, 'code')
    return ', '.join(ev)

def key(i):
    m = re.match(r'([A-Z])(\d{2})-B(\d+)([a-z]?)', i)
    return (m.group(1), int(m.group(2)), int(m.group(3)), m.group(4))

EXTRA = []        # (group name, row dict with id, handler, beh, eff, intent, ev, owner)
SUPERSEDED = {}   # ID -> short note

if sys.argv[1] in ('md', 'write'):
    by = collections.OrderedDict()
    for r in rows:
        if r['header'] is None or 'Patch' in r['header']:
            continue
        if len(r['cells']) != 4:
            alt = split_plain(r['cells'] and '|'.join(r['cells']))
            r['cells'] = split_plain(open(r['file'], encoding='utf-8').read().split('\n')[r['line'] - 1].strip()[1:-1])[1:]
        item = r['id'][:3]
        by.setdefault(r['id'], []).append(r)
    out = []; bad = []
    n = 0
    for gname, prefixes in GROUPS:
        ids = sorted((i for i in by if any(i.startswith(p) for p in prefixes)), key=key)
        if not ids: continue
        n += 1
        out.append(f'#### 6.1.{n} {gname} ({len(ids)})\n')
        out.append('| ID | Handler (§ in the owning doc) | 2016 behaviour | Effect | Likely intent | Evidence | Owner |')
        out.append('|---|---|---|---|---|---|---|')
        for i in ids:
            rs = by[i]; item = i[:3]
            own = [r for r in rs if owner_file(item, r['file'])] or rs
            r = own[0]
            if len(r['cells']) != 4:
                bad.append((i, r['file'], r['line'], len(r['cells']))); continue
            rel = r['file'].replace('docs/pseudocode/', '').replace('docs/knowledge/', '../knowledge/')
            link = f"[{r['file'].split('/')[-1].replace('.md','')} § {r['head'].split(' ')[0].rstrip('.') if re.match(r'[0-9]', r['head']) else 'bugs'}]({rel}#{anchor(r['head'])})"
            others = [x for x in rs if x is not r and x['file'] != r['file']]
            also = ('; also ' + ', '.join(sorted({x['file'].split('/')[-1] for x in others}))) if others else ''
            c = list(r['cells'])
            if i in SUPERSEDED:
                c[1] = f"**Superseded** ({SUPERSEDED[i]}): " + c[1]
            out.append(f"| {i} | {c[0]} ({link}{also}) | {c[1]} | {c[2]} | {c[3]} | {evidence(c)} | {item} |")
        out.append('')
    text = '\n'.join(out)
    if sys.argv[1] == 'md':
        print(text)
    else:
        R = 'docs/pseudocode/README.md'
        doc = open(R, encoding='utf-8').read()
        a, b = '<!-- register:begin (generated by docs/plan/status/X01-register.py) -->\n', '<!-- register:end -->'
        i, j = doc.index(a) + len(a), doc.index(b)
        open(R, 'w', encoding='utf-8').write(doc[:i] + text + '\n' + doc[j:])
    for b in bad: print('BAD', b, file=sys.stderr)
    print('rows', sum(1 for l in out if l.startswith('| ') and re.match(r'\| [A-Z]\d', l)), file=sys.stderr)
