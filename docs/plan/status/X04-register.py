#!/usr/bin/env python3
"""X04 wrapper around X03's bug-register generator (docs/plan/status/X03-register.py, which runs X01-register.py;
both left unchanged).

Runs X03's wrapper in `md` mode and post-processes its rows:
  1. the README §5.9 marks added by X04 (P02 capture batches 2-3): L00-B6, L01-B11, Z04-B6;
  2. *(captured)* evidence from capture-validation §12's second table with every § of an ID joined (X01 keeps only
     the last row of an ID: D03-B11 and Z09-B72 have two) and linked to the section anchor;
  3. the Evidence column of P02's own rows (P02-B1 ... B32): *(captured)* with the § of the capture, except the
     entries P02 read in the code only (P02-B4 latent, P02-B26 masked, P02-B32 found in the batch-3 review);
  4. cross notes between P02 rows and the owner entries they extend or duplicate (Handler column, "linked: ...").

usage (repo root):  python3 -I docs/plan/status/X04-register.py write   # rewrite README §6.1
                    python3 -I docs/plan/status/X04-register.py md      # print the register
"""
import io, re, sys, contextlib, collections

CV = 'docs/protocol/capture-validation.md'
CVREL = '../protocol/capture-validation.md'
README = 'docs/pseudocode/README.md'
MODE = sys.argv[1] if len(sys.argv) > 1 else 'md'

# --- run X03's wrapper (md) and capture its output -------------------------------------------------------------
buf = io.StringIO()
argv = sys.argv
sys.argv = ['docs/plan/status/X03-register.py', 'md']
with contextlib.redirect_stdout(buf):
    exec(compile(open(sys.argv[0], encoding='utf-8').read(), sys.argv[0], 'exec'), {'__name__': 'x03_register'})
sys.argv = argv
text = buf.getvalue()


def anchor(h):
    a = h.strip().lower()
    a = re.sub(r'[^\w\- ]', '', a)
    return a.replace(' ', '-')


def split_cells(s):
    cells, cur, tick, prev = [], '', False, ''
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


# --- capture-validation: section anchors and the "captured evidence" table -------------------------------------
ANCH = {}
CAP = collections.OrderedDict()          # ID -> [§ cells in table order]
cap = False
for line in open(CV, encoding='utf-8'):
    m = re.match(r'^(#{2,4})\s+((\d+(?:\.\d+)*)\.?\s.*)$', line.rstrip('\n'))
    if m:
        ANCH.setdefault(m.group(3), anchor(m.group(2))); cap = False
        continue
    if line.startswith('| ID') and 'Captured evidence' in line:
        cap = True; continue
    if cap and re.match(r'^\| [A-Z]\d{2}-B\d+ \|', line):
        c = split_cells(line.strip()[1:-1])
        for s in re.findall(r'§[\d.]+', c[-1]):
            if s not in CAP.setdefault(c[0], []):
                CAP[c[0]].append(s)


def caplink(secs):
    first = secs[0].lstrip('§').rstrip('.')
    a = ANCH.get(first)
    return f"[capture-validation {', '.join(secs)}]({CVREL}{'#' + a if a else ''})"


# --- 1. marks (README §5.9 rows "added by X04") ----------------------------------------------------------------
MARKS = {
    'L00-B6': ('Superseded', 'P02 capture-validation §7.3: `UserIP` of 0xC801 is filled after the zeroing (`"172.16.42.231"` captured); not a bug'),
    'L01-B11': ('Narrowed', 'P02 capture-validation §16.2: not reachable with the 2016 client, which opens no Login connection before submit and then polls 0x0C1B every 10 s'),
    'Z04-B6': ('Extended', 'P02 capture-validation §21.1: 0x206 and 0x208 (Character-server DB errors of BUYALL / BUYLOT) are silent too; 0x206 captured'),
}

# --- 3. P02's own rows: § of the capture (None = not captured; text = the Evidence cell) -------------------------
P02_EV = {
    'P02-B1': ['§4.3'], 'P02-B2': ['§4.2'], 'P02-B3': ['§5.3'],
    'P02-B4': 'code (latent; read in the disassembly)',
    'P02-B5': ['§7.3', '§16.1'], 'P02-B6': ['§7.3'], 'P02-B7': ['§7.4'], 'P02-B8': ['§7.4'], 'P02-B9': ['§7.4'],
    'P02-B10': ['§7.5.3'], 'P02-B11': ['§7.5.3'], 'P02-B12': ['§7.5.4'], 'P02-B13': ['§7.5.4'], 'P02-B14': ['§7.5.4'],
    'P02-B15': ['§7.6.1'], 'P02-B16': ['§8.1', '§20.2'], 'P02-B17': ['§8.1'], 'P02-B18': ['§9.2'], 'P02-B19': ['§9.2'],
    'P02-B20': ['§9.3'], 'P02-B21': ['§10.1'], 'P02-B22': (['§16.3'], 'cause *(inferred)*'),
    'P02-B23': ['§16.3'], 'P02-B24': ['§16.3'], 'P02-B25': ['§17.4'],
    'P02-B26': 'code; the repeated 0x180F registrations that mask it *(captured)* (' + caplink(['§17.4']) + ')',
    'P02-B27': ['§18.6'], 'P02-B28': ['§18.7'], 'P02-B29': ['§18.4'],
    'P02-B30': (['§19.2', '§19.3', '§19.4', '§21.2'], 'effect on the Character server *(inferred)*'),
    'P02-B31': ['§20.2'],
    'P02-B32': 'code; effect *(inferred)* (found in the batch-3 review of ' + caplink(['§20.2']) + ', not captured)',
}

# --- 4. cross notes (appended to the Handler cell) ---------------------------------------------------------------
NOTES = {
    'P02-B10': 'W05-B15 (same defect, CharDB blob side)',
    'P02-B11': 'W05-B15 (same defect, zone item blob side)',
    'W05-B15': 'P02-B10 / P02-B11 (the same copies, seen on the wire: capture-validation §7.5.3)',
    'P02-B16': 'P02-B32 (same function, send condition); Z05 §1.4 describes the 105-byte send without a tag',
    'P02-B32': 'P02-B16 (same function, 0x305C payload)',
    'P02-B29': 'W04 §2.1 states the whisper 0x200D stale flag bits without an ID; W04-B54 (stale flag bits 1-7 of the GM alert 0x200D)',
    'W04-B54': 'P02-B29 (the same stale 0x200D flag bits on the whisper path, captured)',
    'P02-B30': 'Z11-B8 (`&cleariv`, same 0x3459), Z18-B13 (`sp_DestroyItem` family, same 0x3459), Z06-B7 (the same unwritten `PROTO_ITEM_CREATE.attr` on the booth split)',
    'Z11-B8': 'P02-B30 (the same 0x3459 carries 14 unwritten bytes, captured)',
    'Z18-B13': 'P02-B30 (the same 0x3459 carries 14 unwritten bytes, captured)',
    'Z06-B7': 'P02-B30 (the same unwritten `lotcreate.attr` on 0x3434, captured)',
    'P02-B15': 'D03-B11 (the "Need" map name of the same 0x0446)',
}

CAPRE = re.compile(r'^\*\(captured\)\*(?: \(\[capture-validation [^\]]*\]\([^)]*\)\))?')
out, changed = [], collections.Counter()
for line in text.split('\n'):
    m = re.match(r'^\| ([A-Z]\d{2}-B\d+[a-z]?) \|', line)
    if not m:
        out.append(line); continue
    i = m.group(1)
    c = split_cells(line.strip()[1:-1])          # ID, handler, beh, eff, intent, ev, owner
    if len(c) != 7:                              # an odd backtick in a cell (Z21-B6 / B13 "Can`t"): plain split
        c = [x.strip() for x in line.strip()[1:-1].split(' | ')]
    if len(c) != 7:
        print('BAD', i, len(c), file=sys.stderr); out.append(line); continue
    if i in MARKS:
        mk, note = MARKS[i]
        c[2] = f"**{mk}** ({note}; [§5.9](#59-bug-register-entries-a-later-item-changed)): " + c[2]
        changed['mark'] += 1
    if i in P02_EV:
        v = P02_EV[i]
        if isinstance(v, str):
            c[5] = v
        else:
            secs, extra = (v if isinstance(v, tuple) else (v, ''))
            secs = secs + [s for s in CAP.get(i, []) if s not in secs]
            c[5] = f'*(captured)* ({caplink(secs)})' + (', ' + extra if extra else '')
        changed['p02-evidence'] += 1
    elif i in CAP:
        new = f'*(captured)* ({caplink(CAP[i])})'
        c[5] = CAPRE.sub(new, c[5]) if CAPRE.match(c[5]) else new + ', ' + c[5]
        changed['captured-link'] += 1
    elif i == 'W05-B15':
        c[5] = '*(captured)* (' + caplink(['§7.5.3']) + ', as P02-B10 / B11), ' + c[5]
        changed['captured-link'] += 1
    if i in NOTES:
        c[1] = c[1] + '; linked: ' + NOTES[i]
        changed['note'] += 1
    out.append('| ' + ' | '.join(c) + ' |')
text = '\n'.join(out)

missing = [i for i in list(MARKS) + list(NOTES) + list(P02_EV) if not re.search(r'^\| ' + re.escape(i) + r' \|', text, re.M)]
for i in missing:
    print('MISSING', i, file=sys.stderr)
print('x04 changes', dict(changed), file=sys.stderr)

if MODE == 'md':
    print(text)
elif MODE == 'write':
    doc = open(README, encoding='utf-8').read()
    m = re.search(r'<!-- register:begin [^\n]*-->\n', doc)
    a = '<!-- register:begin (generated by docs/plan/status/X04-register.py, which runs X03-register.py and X01-register.py) -->\n'
    j = doc.index('<!-- register:end -->')
    open(README, 'w', encoding='utf-8').write(doc[:m.start()] + a + text.rstrip('\n') + '\n\n' + doc[j:])
