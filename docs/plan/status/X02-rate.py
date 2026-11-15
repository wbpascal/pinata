#!/usr/bin/env python3
"""X02 confidence ratings: gives every `##`-`####` heading of docs/pseudocode/**/*.md and of docs/knowledge/*.md
a baseline rating (high / medium / low) from the rules of docs/review/confidence.md §1.4 and writes one table per
file into docs/review/confidence.md §2 (between the X02-RATINGS markers). Hand ratings live in X02-rate-hand.py
and win (knowledge files: item key 'K:<ID>').

usage (repo root):  python3 -I docs/plan/status/X02-rate.py write          # rewrite §2.3 ff. in confidence.md
                    python3 -I docs/plan/status/X02-rate.py stats          # per file: sections, high/medium/low
                    python3 -I docs/plan/status/X02-rate.py show W01 [low] # rows of one item (optionally one rating)
                    python3 -I docs/plan/status/X02-rate.py sig W01 4.2    # raw signals of one section
                    python3 -I docs/plan/status/X02-rate.py pdbmiss K:Z01  # lines whose PDB member has another offset
                    python3 -I docs/plan/status/X02-rate.py pdbcache       # rebuild X02-pdb-members.tsv (5 server PDBs)
(`show` / `sig` / `pdbmiss` take 'K:<ID>' for the knowledge file of an item.)

Signals per section (own body, up to the next heading of any level):
  cap      opcodes of the section with a capture evidence entry (annotations/P02.json `evidence`), of all its opcodes
  conf     the § is named in a **confirmed** row of capture-validation.md (§11, §13 tail) -> `cv ok`
  corr     the § is named in a row of capture-validation.md §13 (corrected / contradicted / extended) -> `cv corr`
  sup      rows of README §5 whose "Older place" names this item and § (statements a later item superseded)
  cli      lines that cite a client function (`client … FUN_…`)
  weak     *(inferred)* + *(pdb2017)* + *(fh-doc)* + *(db-backup)* markers
  B R U F  "Find more" keyword tests of confidence.md §1.2 (see KW below)
  S        `p+0x…` offsets of a zone doc that neither S01-player-offsets.tsv nor the 2016 Zone.pdb layout of
           ShinePlayer / ShineMobileObject / ShineObject (members flattened 3 levels, X02-pdb-members.tsv) knows
  pdb      knowledge files: lines that name a 2016 PDB member next to a `+0x…` offset; n of m agree with the PDB
  N        names of README §4.8 ("older names that mislead") used in the section; "(ours)" names in pre-S01 docs
  D        *(db-backup)* in D01-D05 (procedure bodies read before D06 compared the backup versions)
Rating: see `rate()`; the legend printed into confidence.md §2.2 is the same text."""
import re, sys, glob, json, os, collections, subprocess, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PDBCACHE = os.path.join(HERE, 'X02-pdb-members.tsv')
PDBS = ['Zone00/Zone.pdb', 'WorldManager/WorldManager.pdb', 'Login/Login.pdb', 'Account/Account.pdb',
        'AccountLog/AccountLog.pdb']
PLAYER = ['ShineObjectClass::ShineObject', 'ShineObjectClass::ShineMobileObject', 'ShineObjectClass::ShinePlayer']
IDENT = re.compile(r'[A-Za-z_]\w{4,}')
HEXOFF = re.compile(r'\+\s?0x([0-9a-fA-F]+)\b|^\|\s*`?0x([0-9a-fA-F]+)`?\s*\|')
PARAM = {0xfc0 + i * 4 for i in range(16 * 51)}      # smo_Param: 16 Parameter::Cluster of 51 int (Z12 §1.1)

PRE_S01 = {'L00', 'W01', 'W02', 'W03', 'W04', 'Z01', 'Z02', 'Z03', 'Z04', 'Z05', 'Z06', 'Z07', 'Z08',
           'D01', 'D02', 'D03', 'D04', 'D05'}
NO_PDB = {'D02', 'D03', 'D04', 'D05', 'D07'}       # Character / GameLog: no server PDB, every name is ours
H = re.compile(r'^(#{2,4})\s+(.*?)\s*$')
NUM = re.compile(r'^§?\s*(\d+(?:\.\d+)*[a-z]?)\.?(?:\s|$)')
OP = re.compile(r'\b0x([0-9A-Fa-f]{4})\b')
FUN = re.compile(r'FUN_[0-9a-f]{8}')
KW = {
    # B: a packet / request said to be ignored or a step said to be unconditional (not: a field or a result ignored)
    'B': re.compile(r'(?:packet|request|message|opcodes?|handler)s? (?:is|are) (?:silently )?(?:ignored|dropped)|else ignored|'
                    r'\bno-op\b|\bunconditional(?:ly)?\b|ignored silently|\(ignored\)\s+@', re.I),
    'R': re.compile(r'\b(dead code|never sent|no sender|unreachable|never called|legacy|not reachable|no caller)\b', re.I),
    'U': re.compile(r'\b(zeroed|zero-filled|zero filled|memset|uninitiali[sz]ed|stale)\b', re.I),
    'F': re.compile(r'\b(milliseconds|seconds|minutes|hours)\b|\bms\b|\bunk\w*|\?\?', re.I),
}
WEAK = {'inf': '(inferred)', 'p17': '(pdb2017)', 'fh': '(fh-doc)', 'dbb': '(db-backup)'}
META = re.compile(r'coverage boundary|not reconstructed|uncertain|open questions|open points|follow-up items', re.I)
BUGS = re.compile(r'original-server bugs|^bugs\b', re.I)

# ---------------------------------------------------------------------------------------------------------------
# Hand ratings: (item, § or heading text) -> (rating, reason, what would raise it). Filled by the hand passes
# (part 2: Login, WM, shared, DB; part 3: zone). They replace the baseline; the row is marked "hand".
OVERRIDE = {}
CAPS = []          # (item, regex on the § number, highest rating allowed, reason, raise)
ORDER = {'low': 0, 'medium': 1, 'high': 2}
exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'X02-rate-hand.py'), encoding='utf-8').read()) \
    if os.path.exists(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'X02-rate-hand.py')) else None


def item_of(path):
    b = os.path.basename(path)
    return 'L00' if b == 'login-server.md' else b[:3]


def load_inputs():
    I = {}
    ev = json.load(open('docs/protocol/annotations/P02.json', encoding='utf-8'))['evidence']
    I['cap'] = {op.lower() for b in ev.values() for op in b}
    I['ops'] = {e['op'].lower() for e in json.load(open('docs/protocol/opcodes.json', encoding='utf-8'))
                if e.get('name') or e.get('received_by')}
    ch = json.load(open('re-data/client-handlers.json', encoding='utf-8'))
    I['cliops'] = {k.lower() for k in ch}
    I['clifun'] = set(FUN.findall(json.dumps(ch)))
    d06 = open('docs/pseudocode/db/D06-db-inferred.md', encoding='utf-8').read()
    m = re.search(r'### 8\.5 .*?(?=\n### )', d06, re.S)
    I['dprocs'] = {n for l in m.group(0).splitlines() if l.startswith('| `')
                   for n in re.findall(r'`((?:p|usp)_\w+)`', l.split(' | ')[0])}
    tsv = open('docs/knowledge/S01-player-offsets.tsv', encoding='utf-8').read().splitlines()[1:]
    I['offs'] = {int(l.split('\t')[0], 16) for l in tsv if l.strip()}
    I['poffs'] = set(); I['members'] = {}
    for l in open(PDBCACHE, encoding='utf-8').read().splitlines()[1:]:
        c = l.split('\t')
        if c[0] == 'P':
            I['poffs'].add(int(c[1], 16))
        elif c[0] == 'M':
            o = {int(x, 16) for x in c[2].split(',')}
            if len(o) <= 12:             # a name with many offsets ("handle", "count") agrees with anything
                I['members'][c[1]] = o
    readme = open('docs/pseudocode/README.md', encoding='utf-8').read().splitlines()
    # README §4.8: misleading names
    mis = {}; sup = collections.defaultdict(list); sec = None; default = None
    DEF = {'5.2': 'L00'}
    for line in readme:
        m = re.match(r'^#{2,4}\s+(\d+(?:\.\d+)*)\.?\s', line)
        if m:
            sec = m.group(1); default = DEF.get(sec); continue
        if not line.startswith('| ') or line.startswith('| Older place') or line.startswith('|---'):
            continue
        cells = [c.strip() for c in line.strip().strip('|').split(' | ')]
        if sec == '4.8' and len(cells) > 2:
            its = set(re.findall(r'\b([A-Z]\d\d)\b', cells[1])) | ({'L00'} if 'L00' in cells[1] or '00-base' in cells[1] else set())
            for n in re.findall(r'`([A-Za-z_][\w:.]*)`', cells[1]):
                if len(n) > 5:
                    mis.setdefault(n, set()).update(its)
        if sec and sec.startswith('5.') and sec != '5.9' and len(cells) >= 3:
            for it, s in refs(cells[0], default):
                sup[(it, s)].append(sec)
    I['mis'] = mis; I['sup'] = sup
    # capture-validation: confirmed / corrected § references
    conf = set(); corr = set()
    cv = open('docs/protocol/capture-validation.md', encoding='utf-8').read()
    in13 = False
    for line in cv.splitlines():
        if line.startswith('## '):
            in13 = line.startswith('## 13.')
        if line.startswith('| '):
            cells = [c.strip() for c in line.strip().strip('|').split(' | ')]
            if in13 and len(cells) >= 4 and 'README.md' not in cells[1]:
                dflt = re.match(r'[A-Z]\d\d', cells[0].split('/')[-1].strip())
                for r in refs(cells[1], dflt.group(0) if dflt else None):
                    corr.add(r)
            elif '**confirmed**' in line and len(cells) >= 4:
                for r in refs(cells[1], None):
                    conf.add(r)
    m = re.search(r'Pseudocode orders the captures confirm in full:(.*?)The corrected orders', cv, re.S)
    if m:
        conf.update(refs(m.group(1), None))
    I['conf'] = conf; I['corr'] = corr
    return I


FILE_ITEM = re.compile(r'`?(login-server|[A-Z]\d\d)(?:-[\w-]+)?(?:\.md)?`?')


def refs(text, default):
    """(item, §) pairs named in a cell: 'Z03 §3 / §7.2', '`W01-core.md` §4.2 (…), §7.4', '§2 bootstrap' (default)."""
    out = []; cur = default
    for m in re.finditer(r'(login-server(?:\.md)?|\b[A-Z]\d\d\b(?:-[\w-]+\.md)?)|§\s?(\d+(?:\.\d+)*[a-z]?)', text):
        if m.group(1):
            t = m.group(1)
            cur = 'L00' if t.startswith('login-server') else t[:3]
            if not re.match(r'[LWZDSCPX]\d\d', cur):
                cur = default
        elif cur:
            out.append((cur, m.group(2)))
    if not out and cur and cur != default:
        out.append((cur, ''))            # item named without a §: counts for the file
    return out


def sections(path):
    out = []; cur = None; fence = False
    for i, line in enumerate(open(path, encoding='utf-8'), 1):
        if line.startswith('```'):
            fence = not fence
        m = None if fence else H.match(line)
        if m:
            t = m.group(2)
            n = NUM.match(t)
            cur = dict(level=len(m.group(1)), title=t, num=n.group(1) if n else '', line=i, body=[])
            out.append(cur)
        elif cur is not None:
            cur['body'].append(line)
    for s in out:
        s['text'] = ''.join(s['body']); del s['body']
    return out


def signals(item, s, I, secnums):
    t = s['text']; g = {}
    ops = {('0x' + o).lower() for o in OP.findall(s['title'] + '\n' + t)} & I['ops']
    g['ops'] = ops; g['cap'] = ops & I['cap']; g['cliops'] = ops & I['cliops']
    g['fun'] = len(set(FUN.findall(s['title'] + t)))
    g['optitle'] = bool(OP.search(s['title']))
    g['cli'] = sum(1 for l in t.splitlines() if re.search(r'\bclient\b', l, re.I)
                   and (set(FUN.findall(l)) & I['clifun'] or re.search(r'\bclient(?: handler| function)? \(?`?(?:On[ _]\w+ )?FUN_', l, re.I)))
    g['D'] = sorted(n for n in I['dprocs'] if re.search(r'\b' + n + r'\b', t))
    for k, w in WEAK.items():
        g[k] = t.count(w)
    g['weak'] = sum(g[k] for k in WEAK)
    g['captured'] = t.count('(captured)') + s['title'].count('(captured)')
    for k, r in KW.items():
        g[k] = len(r.findall(t))
    g['S'] = 0
    if item.startswith('Z'):
        offs = {int(x, 16) for x in re.findall(r'\bp\+0x([0-9a-f]+)', t)}
        g['Sbad'] = sorted(offs - I['offs'] - I['poffs'] - PARAM); g['S'] = len(g['Sbad'])
    g['pdbn'] = g['pdbok'] = 0; g['pdbmiss'] = []; g['offlines'] = 0
    if s.get('kn'):
        for l in t.splitlines():
            hx = {int(a or b, 16) for a, b in HEXOFF.findall(l)}
            if not hx:
                continue
            g['offlines'] += 1
            names = [n for n in IDENT.findall(' '.join(re.findall(r'`([^`]+)`', l))) if n in I['members']]
            if not names:
                continue
            g['pdbn'] += 1
            if any(hx & I['members'][n] for n in names):
                g['pdbok'] += 1
            else:
                g['pdbmiss'].append(l.strip()[:200])
    g['N'] = sorted(n for n, its in I['mis'].items() if (item in its or not its) and re.search(r'\b' + re.escape(n) + r'\b', t))
    g['ours'] = len(re.findall(r'\(ours\)|, ours\b|name is ours|names are ours', t))
    g['size'] = len(t)
    # § references apply to the exact heading; a § that is no heading goes to its nearest ancestor
    def hits(table):
        n = 0; where = []
        for (it, sec), v in (table.items() if isinstance(table, dict) else ((k, [1]) for k in table)):
            if it != item:
                continue
            tgt = sec
            while tgt and tgt not in secnums:
                tgt = tgt.rpartition('.')[0]
            if tgt == s['num'] and (tgt or sec == ''):
                if sec == '' and s['num'] != '':
                    continue
                n += len(v); where += v
        return n, sorted(set(map(str, where)))
    if s.get('kn'):                      # README §5 and capture-validation name pseudocode §, not knowledge §
        g['sup'], g['supwhere'], g['conf'], g['corr'] = 0, [], 0, 0
        return g
    g['sup'], g['supwhere'] = hits(I['sup'])
    g['conf'] = hits(I['conf'])[0]; g['corr'] = hits(I['corr'])[0]
    return g


def rate(item, s, g, haskids):
    """-> (rating, reason, raise)"""
    title = s['title']
    if META.search(title):
        return '–', 'open points / boundary list, no claim to rate', ''
    low = []; note = []; up = []
    pre = item in PRE_S01
    nops, ncap = len(g['ops']), len(g['cap'])
    uncap_cli = sorted(g['cliops'] - g['cap'])
    if g['sup']:
        low.append(f"sup×{g['sup']} (README §{', §'.join(g['supwhere'])})")
        up.append('re-read the rest (§3)')
    if g['corr']:
        low.append('cv corr')
        up.append('read with P02 "Corrections"')
    kb = max(g['size'] / 1000.0, 1.0)
    if g['weak'] >= 3 and g['weak'] / kb >= 0.5:
        low.append('weak ' + ' '.join(f"{k}{g[k]}" for k in WEAK if g[k]))
        up.append('code or capture for the marked statements')
    elif g['weak']:
        note.append('weak ' + ' '.join(f"{k}{g[k]}" for k in WEAK if g[k]))
    if g['D'] and item in ('D01', 'D02', 'D03', 'D04', 'D05'):
        low.append('D: ' + ', '.join('`%s`' % n for n in g['D'][:3]) + (' …' if len(g['D']) > 3 else '') + ' differ between the backups')
        up.append('D06 §8.5 version')
    if g['S'] >= 2 or (g['S'] and pre):
        low.append('S: ' + ' '.join('p+0x%x' % o for o in g['Sbad'][:4]) + (' …' if g['S'] > 4 else ''))
        up.append('PDB member (`pdb.py` ShinePlayer)')
    kn = bool(s.get('kn'))
    if kn and pre and g['offlines'] >= 3 and not g['pdbn']:
        low.append(f"S: {g['offlines']} offset lines, no 2016 PDB member named (pre-S01 names are ours)")
        up.append('find the struct in the 2016 PDB (`pdb.py … types`), S01-renames.tsv')
    if g['pdbn'] and g['pdbok'] * 2 < g['pdbn']:
        note.append(f"{g['pdbn'] - g['pdbok']} PDB member(s) at another offset (nested or wrong: `X02-rate.py pdbmiss`)")
        up.append('check the offsets with `pdb.py`')
    if g['N']:
        low.append('N: ' + ', '.join('`%s`' % n for n in g['N'][:3]) + (' …' if len(g['N']) > 3 else ''))
        up.append('README §4.8')
    if pre and g['B']:
        low.append(f"B×{g['B']}")
        up.append('follow the return value to the parser')
    elif g['B'] >= 3:
        note.append(f"B×{g['B']}")
    if pre and g['R']:
        low.append(f"R×{g['R']}")
        up.append('callers incl. vtable slots; senders in every `handlers.json`')
    elif g['R']:
        note.append(f"R×{g['R']}")
    if g['ours'] and pre:
        note.append(f"ours×{g['ours']}")
    strong = g['conf'] or g['captured'] >= 2
    captured = bool(nops and ncap * 2 >= nops and (ncap >= 2 or g['optitle'])) or (strong and (not nops or ncap * 3 >= nops))
    if item[0] == 'D' and captured and not g['conf']:
        captured = False; note.append('capture shows the link packets, not the SQL')
    if BUGS.search(title):
        captured = False
    if kn:
        captured = False      # knowledge sections are fact lists: a mentioned captured opcode confirms no table
    ev = []
    if nops:
        ev.append(f"cap {ncap}/{nops}")
    if g['conf']:
        ev.append('cv ok')
    if g['cli']:
        ev.append(f"client×{g['cli']}")
    if g['pdbn']:
        ev.append(f"pdb {g['pdbok']}/{g['pdbn']}")
    layout = kn and g['pdbn'] >= 3 and g['pdbok'] * 5 >= g['pdbn'] * 4
    if g['fun'] == 0 and nops == 0:
        if haskids and g['size'] < 1500 and not g['sup'] and not g['corr'] and not low:
            return '–', 'container (see its subsections)', ''
        ev.append('no function cited')
    if uncap_cli:
        up.append('capture ' + ', '.join(o[:2] + o[2:].upper() for o in uncap_cli[:4]) + (' …' if len(uncap_cli) > 4 else ''))
    if BUGS.search(title):
        note.append('bug table (class X: effects are deductions)')
    if captured and not low:
        r = 'high'
    elif captured:
        r = 'medium'
    elif low:
        r = 'low'
    elif layout:
        r = 'high'            # struct table: the offsets are the 2016 PDB's (second source for the layout)
    elif g['cli'] and not nops and g['fun'] and not kn:
        r = 'high'            # client behaviour read in the client, no wire content in the §
    elif g['fun'] == 0 and nops == 0:
        r = 'medium' if not pre else 'low'
        if pre:
            low.append('pre-S01 prose without a function')
        up.append('cite and re-read the function')
    else:
        r = 'medium'
        if not up:
            up.append('capture (class U)' if nops else 'second reading / client check')
    if item in NO_PDB and r == 'medium' and not ncap and 'names ours' not in note:
        note.append('no PDB')
    reason = '; '.join(ev + low + note) or 'read in code'
    if r == 'high':
        up = []
    return r, reason, '; '.join(dict.fromkeys(up))


def files():
    fs = sorted(glob.glob('docs/pseudocode/**/*.md', recursive=True))
    fs = [f for f in fs if not f.endswith(('FORMAT.md', 'README.md'))]
    key = lambda f: ('LWZDS'.index(item_of(f)[0]) if item_of(f)[0] in 'LWZDS' else 9, item_of(f))
    return sorted(fs, key=key)


def kfiles():
    fs = sorted(glob.glob('docs/knowledge/*.md'))
    key = lambda f: ('LWZDSCPX'.index(item_of(f)[0]) if item_of(f)[0] in 'LWZDSCPX' else 9, item_of(f))
    return sorted(fs, key=key)


def build():
    I = load_inputs(); res = []
    for f in files() + kfiles():
        kn = f.startswith('docs/knowledge/')
        item = item_of(f); secs = sections(f)
        for s in secs:
            s['kn'] = kn
        hkey = ('K:' if kn else '') + item
        secnums = {s['num'] for s in secs if s['num']}
        rows = []
        for k, s in enumerate(secs):
            haskids = k + 1 < len(secs) and secs[k + 1]['level'] > s['level']
            g = signals(item, s, I, secnums)
            r, why, up = rate(item, s, g, haskids)
            hand = OVERRIDE.get((hkey, s['num'])) or OVERRIDE.get((hkey, s['title']))
            for it, rx, mx, cwhy, cup in CAPS:
                if it == hkey and re.match(rx, s['num'] or s['title']) and r != '–' and ORDER[r] > ORDER[mx]:
                    why = cwhy + ' (hand; baseline: ' + r + ': ' + why + ')'; r = mx; up = cup
            if hand:
                r, why, up = hand[0], hand[1] + ' (hand; baseline: ' + r + ')', hand[2]
            rows.append((s, g, r, why, up))
        res.append((f, hkey, rows))
    return res


def pdbcache():
    """X02-pdb-members.tsv: P rows = ShinePlayer members flattened 3 levels (absolute offset); M rows = every
    member name of the five 2016 server PDBs that a pseudocode / knowledge document writes, with its offsets."""
    words = set()
    for f in files() + kfiles():
        for bt in re.findall(r'`([^`\n]+)`', open(f, encoding='utf-8').read()):
            words.update(IDENT.findall(bt))
    members = collections.defaultdict(set); P = {}
    with tempfile.TemporaryDirectory() as d:
        for k, pdb in enumerate(PDBS):
            out = os.path.join(d, f'{k}.json')
            subprocess.run([sys.executable, '-I', 'tools/protocol-re/pdb.py', 'Files/Server/NA2016/' + pdb, 'json', out],
                           check=True, stdout=subprocess.DEVNULL)
            T = json.load(open(out, encoding='utf-8'))['types']
            for t in T.values():
                for f in t.get('fields', ()):
                    if 'offset' in f and f['name'] in words:
                        members[f['name']].add(f['offset'])
            if k == 0:
                def flat(tn, base, depth, path):
                    for f in T.get(tn, {}).get('fields', ()):
                        if 'offset' not in f:
                            continue
                        o = base + f['offset']
                        P.setdefault(o, (path + f['name'], f['type']))
                        if depth:
                            flat(re.sub(r'\[\d+\]$', '', f['type']), o, depth - 1, path + f['name'] + '.')
                for cls in PLAYER:
                    flat(cls, 0, 3, '')
    with open(PDBCACHE, 'w', encoding='utf-8') as fh:
        fh.write('kind\toffset or name\tmember path or offsets\ttype\n')
        for o in sorted(P):
            fh.write(f'P\t0x{o:x}\t{P[o][0]}\t{P[o][1]}\n')
        for n in sorted(members):
            fh.write(f"M\t{n}\t{','.join('0x%x' % o for o in sorted(members[n]))}\t\n")
    print('written', len(P), 'player members,', len(members), 'member names')


def esc(t):
    return t.replace('|', '\\|')


def short(t, n=64):
    t = re.sub(r'\*\(captured\)\*', '', t).strip()
    return t if len(t) <= n else t[:n - 1] + '…'


def table(rows):
    out = ['| § | Rating | Reason | Raise by |', '|---|---|---|---|']
    for s, g, r, why, up in rows:
        ind = '· ' * (s['level'] - 2)
        rr = f'**{r}**' if r in ('low', 'high') else r
        out.append(f"| {ind}{esc(short(s['title']))} | {rr} | {esc(why)} | {esc(up)} |")
    return out


def counts(rows):
    c = collections.Counter(r for _, _, r, _, _ in rows)
    return c['high'], c['medium'], c['low'], c['–']


def render(res):
    out = ['### 2.3 Summary per file (generated)', '']
    for kn, title in ((False, 'Pseudocode documents (`docs/pseudocode/`):'), (True, 'Knowledge files (`docs/knowledge/`):')):
        out += [title, '', '| File | Item | Sections | high | medium | low | not rated | hand |', '|---|---|---|---|---|---|---|---|']
        T = collections.Counter()
        for f, item, rows in res:
            if item.startswith('K:') != kn:
                continue
            h, m, l, n = counts(rows)
            hand = sum(1 for r in rows if '(hand;' in r[3])
            out.append(f"| `{f.split('/', 2)[2]}` | {item[-3:]} | {len(rows)} | {h} | {m} | {l} | {n} | {hand} |")
            T.update(dict(s=len(rows), h=h, m=m, l=l, n=n, hand=hand))
        out.append(f"| **total** | | {T['s']} | {T['h']} | {T['m']} | {T['l']} | {T['n']} | {T['hand']} |")
        out.append('')
    for k, (f, item, rows) in enumerate(res, 4):
        kn = item.startswith('K:')
        out += [f"### 2.{k} {item[-3:]}{' knowledge' if kn else ''}: `{f if kn else f.split('/', 2)[2]}`", ''] + table(rows) + ['']
    return out


BEGIN, END = '<!-- X02-RATINGS:BEGIN (generated by docs/plan/status/X02-rate.py write; do not edit) -->', '<!-- X02-RATINGS:END -->'


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'stats'
    if cmd == 'pdbcache':
        return pdbcache()
    res = build()
    if cmd == 'stats':
        for f, item, rows in res:
            print(item, len(rows), 'h/m/l/-', *counts(rows))
    elif cmd == 'show':
        for f, item, rows in res:
            if item == sys.argv[2]:
                for s, g, r, why, up in rows:
                    if len(sys.argv) < 4 or r == sys.argv[3]:
                        print(f"{s['num'] or short(s['title'], 30):10} {r:6} {short(s['title'], 50):50} | {why} | {up}")
    elif cmd == 'pdbmiss':
        for f, item, rows in res:
            if item == sys.argv[2]:
                for s, g, r, why, up in rows:
                    for l in g['pdbmiss']:
                        print(f"{s['num'] or short(s['title'], 20):8} {l}")
    elif cmd == 'sig':
        for f, item, rows in res:
            if item == sys.argv[2]:
                for s, g, r, why, up in rows:
                    if s['num'] == sys.argv[3]:
                        print(r, why, up); print({k: (sorted(v) if isinstance(v, set) else v) for k, v in g.items()})
    elif cmd == 'write':
        p = 'docs/review/confidence.md'
        t = open(p, encoding='utf-8').read()
        a, b = t.index(BEGIN), t.index(END)
        t = t[:a] + BEGIN + '\n\n' + '\n'.join(render(res)) + '\n' + t[b:]
        open(p, 'w', encoding='utf-8').write(t)
        print('written', sum(len(r) for _, _, r in res), 'rows')


if __name__ == '__main__':
    main()
