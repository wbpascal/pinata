#!/usr/bin/env python3
"""X01 bug register: collects every `<item>-B<n>` table row of docs/pseudocode/**/*.md and docs/knowledge/*.md
(plus P02's table in docs/protocol/capture-validation.md §8) into docs/pseudocode/README.md §6 (between the
register markers). IDs listed in capture-validation's "captured evidence" table get *(captured)*.

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
files.append('docs/protocol/capture-validation.md')   # P02's bug table (§8) and its "captured evidence" table
rows = []
CAPTURED = {}     # ID -> § of capture-validation.md where the capture shows the bug on the wire
for f in files:
    head = None; header = None; capmode = False
    for i, line in enumerate(open(f, encoding='utf-8'), 1):
        m = H.match(line)
        if m:
            head = m.group(2); header = None; capmode = False
            continue
        if line.startswith('| ') and ('2016 behaviour' in line or 'Behaviour' in line):
            header = split_cells(line.strip()[1:-1]); capmode = False
            continue
        if line.startswith('| ID') and 'Captured evidence' in line:
            header = None; capmode = True
            continue
        m = ROW.match(line.rstrip('\n'))
        if not m:
            continue
        cells = split_cells(m.group(2))
        if capmode:
            CAPTURED[m.group(1)] = cells[-1]
            continue
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
          ('Found while reading the 2016 server PDBs', ['S01']),
          ('Found in packet captures (P02; Character, WM, Zone)', ['P02'])]

def owner_file(item, f):
    b = f.split('/')[-1]
    if item == 'L00': return b == 'login-server.md'
    if item == 'S01': return f == 'docs/knowledge/S01.md'
    if item == 'P02': return b == 'capture-validation.md'
    return b.startswith(item + '-') or b == item + '.md'

def server(item):
    return SERVER.get(item) or {'W': 'WM', 'Z': 'Zone'}.get(item[0], item)

def evidence(cells, i=''):
    t = ' '.join(cells)
    ev = []
    if i in ('P02-B1', 'P02-B2', 'P02-B3') or i in CAPTURED:     # P02-B4 is latent: read in the disassembly only
        ev.append('*(captured)*' + (f" ([capture-validation {CAPTURED[i]}](../protocol/capture-validation.md))" if i in CAPTURED else ''))
    elif '(captured)' in t or 'captured' in t.lower() and 'capture' in cells[1].lower(): ev.append('*(captured)*')
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
# ID -> (mark, note): mark = Superseded (the bug as stated does not exist), Narrowed (part of it, or its effect, is
# wrong), Extended (a later item adds the cause or more effect), Withdrawn (the owning item itself withdrew the entry
# but kept the row; evidence column becomes "withdrawn"). README §5.9 lists the same entries with sources.
SUPERSEDED = {
    'W05-B7': ('Withdrawn', 'W05 review: `ReadGlobalGameData` does pass the path for `%s`; not a bug'),
    'W05-B12': ('Withdrawn', 'W05 review: the 0x0802 log gets all its arguments; not a bug'),
    'Z09-B5': ('Withdrawn', 'Z09 R1: the call is the map-script interrupt `sim_MobHPFull`; not a bug'),
    'Z11-B11': ('Withdrawn', 'Z11 sweep: the number is used (`pr_SetCount` FUN_00468180); not a bug'),
    'W01-B5': ('Superseded', 'X01: the XOR key is Login\'s per-world counter, +1 per world select (`GetClientValidation` FUN_0040a200, L01 §2.5), so pending logins take consecutive slots; a slot is reused only after 2048 selects'),
    'Z02-B5': ('Narrowed', 'Z07 §11: the 0x2035 / 0x2039 produce path is live (client `ProductTask` sends both); only the result packets are unused'),
    'Z02-B12': ('Narrowed', 'Z09 §15.8: the report only arms the interrupt, which fires when the server\'s own `.aid` geometry agrees; a false report can only choose which inside player counts'),
    'Z04-B13': ('Superseded', 'Z13 §3.3: every failing check returns a code that the handler sends as 0x3034; only the 0x702 error loses its code, see Z13-B17'),
    'Z07-B10': ('Narrowed', 'the 2016 client does handle 0x1094 (`WeddingInfoWin::SetWeddingInfo` FUN_006da330, Z13 §4.7), so the stale LastConnect is shown'),
    'Z07-B13': ('Narrowed', 'Z13 §1.4: the house method refuses `nNotifyLen > 100`, so the over-read is at most 100 bytes past a short packet'),
    'Z08-B6': ('Extended', 'Z15 §4.7: the silent case is `IsDoingQuest` = 0, i.e. client and zone diaries disagree'),
    'Z08-B12': ('Superseded', 'Z16-B17: `seed <= 32` against 32-entry tables; the start bound is the bug'),
    'D01-B4': ('Narrowed', 'D06 §2.4: `usp_UserTWLoginGame` (pdb2016) belonged to a separate Taiwan Account DB; fails only against the NA database, and the NA client never starts the TW path'),
    'D01-B10': ('Superseded', 'D06 §3.3: both L20 wrappers preset `nRet = -1`, so the error branch is deterministic (0x128a); the `nRet` not in {1,3} log condition is intended'),
    'D02-B3': ('Narrowed', 'W03 §4.5: the WM refuses guild masters itself with 0x140A {0x00C7} before 0x1408 reaches the Character server'),
    'D02-B8': ('Narrowed', 'D06 §6.3: harmless with the w00 body (`@nRet int = 0 output` default); only the codes -1111 / 1 are lost'),
    'D02-B18': ('Extended', 'D06: no 2016 component sends 0xA001 / 0xA004, so the whole promotion path is dead'),
    'D02-B19': ('Superseded', 'D06 §6.2: column 37 is the link-scroll destination map (`sLinkScrollDestMap`, ours) the backups lack: a backup mismatch, not a 2016 bug *(inferred, strong)*'),
    'D03-B21': ('Narrowed', 'D06: 0xBC06 has no 2016 sender (no zone send, no zone 0xBC07 handler), so it has no effect in 2016; the handler also ignores `@nRet`'),
    'D04-B6': ('Narrowed', 'W04 §5.3: the 2016 client shows its literal "DB Error" for 0x949, not "Already have a friend request." (§5.7)'),
    'D04-B9': ('Extended', 'S01 §2.4: a header mismatch: the 2016 Zone PDB has two definitions of the 0x5C05 struct; the zone sends the 54-byte one, the Character server reads 58'),
    'D05-B2': ('Extended', 'S01 §2.4: a header mismatch: the 2016 Zone PDB has two definitions of the 0x0452 struct; the zone sends the newer one'),
}

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
            rel = r['file'].replace('docs/pseudocode/', '').replace('docs/knowledge/', '../knowledge/').replace('docs/protocol/', '../protocol/')
            link = f"[{r['file'].split('/')[-1].replace('.md','')} § {r['head'].split(' ')[0].rstrip('.') if re.match(r'[0-9]', r['head']) else 'bugs'}]({rel}#{anchor(r['head'])})"
            others = [x for x in rs if x is not r and x['file'] != r['file']]
            also = ('; also ' + ', '.join(sorted({x['file'].split('/')[-1] for x in others}))) if others else ''
            c = list(r['cells'])
            if i in SUPERSEDED:
                mark, note = SUPERSEDED[i]
                c[1] = f"**{mark}** ({note}; [§5.9](#59-bug-register-entries-a-later-item-changed)): " + c[1]
            ev = 'withdrawn' if SUPERSEDED.get(i, ('',))[0] == 'Withdrawn' else evidence(c, i)
            out.append(f"| {i} | {c[0]} ({link}{also}) | {c[1]} | {c[2]} | {c[3]} | {ev} | {item} |")
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
