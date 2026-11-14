"""Byte-faithful emulation of the 2016 CToken / CCsl script reader (S02 §2), to test the shipped config files.
Usage: python3 -I tools/protocol-re/csl.py <script> [-v] [--lf] [--noend]
  -v       print every row;  --lf  convert CRLF to LF first (S02-B16);  --noend  drop #END first (S02-B14)
Follows #INCLUDE relative to the including file, like CCsl::IncludeFile. FLAG lines name the bug paths hit."""
import os, re, sys

CMDS = ['#END', '#DEFINE', '#INCLUDE', '#CLEAR', '#CLEARFORMAT', '#CLEARDATA', '#READ', '#WRITE', '#WRITEFORMAT', '#WRITEDATA']
PARS = ['<ID>', '[ID]', '<INTEGER>', '[INTEGER]', '<HEX>', '[HEX]', '<FLOAT>', '[FLOAT]', '<STRING>', '[STRING]',
        '<FILENAME>', '[FILENAME]', '<SHORTKEY>', '[SHORTKEY]', '<ARRAYSRT>', '[ARRAYSRT]', '<ARRAYEND>', '[ARRAYEND]', '#ENDDEFINE']
SIZE = [4, 4, 4, 4, 4, 4, 4, 4, 512, 512, 260, 260, 4, 4, 4, 4, 0, 0, 0]
FLAGS = []


def icmp(a, b): return a.lower() == b.lower()


class Tok:
    def __init__(s, data):
        s.b = bytearray(data) + b'\0'; s.n = len(data)
        s.seps = b' \t\r\n'; s.start = True; s.reset = False; s.rpos = None; s.tok = None; s.mts = None
        s.saved = None; s.raw = bytes(data)

    def cstr(s, p):
        if p is None: return None
        if p == 'NULL': return ''
        e = s.b.index(0, p); return s.b[p:e].decode('cp949', 'replace')

    def line(s, p): return s.raw.count(b'\n', 0, p if isinstance(p, int) else 0) + 1

    def tcstok(s, start, delim):
        if start is not None: s.mts = start
        p = s.mts
        if p is None: return None
        def brk(x):
            while s.b[x] != 0:
                if s.b[x] in delim: return x
                x += 1
            return None
        q = brk(p); s.mts = q
        while q == p:
            s.mts += 1; p = s.mts; q = brk(p); s.mts = q
        if s.mts is not None:
            s.b[s.mts] = 0; s.mts += 1
        return p

    def get(s):
        if s.start:
            s.start = False; s.reset = False; s.tok = s.tcstok(0, s.seps)
        elif s.reset:
            s.tok = s.tcstok(s.rpos, s.seps); s.reset = False
        else:
            s.tok = s.tcstok(None, s.seps)
        return s.tok

    def gostart(s):
        p = s.tok
        if p == 'NULL': FLAGS.append('GoStartString from m_NULLstr (static memory)'); return None
        p = s.b.index(0, p) + 1
        while True:
            if p >= len(s.b): FLAGS.append('string scan ran past the file buffer (S02-B13)'); return None
            if s.b[p] == 0x22: return p
            p += 1

    def getstr(s):
        if s.start:
            s.start = False; s.reset = False; s.tok = s.tcstok(0, b'"')
        if s.reset:
            s.tok = s.rpos - 1; s.reset = False
        p = s.gostart()
        if p is None: return ''
        s.tok = p
        if s.b[p] == 0x22 and s.b[p + 1] == 0x22:
            s.rpos = p + 2; s.reset = True; s.tok = 'NULL'; return ''
        s.tok = s.tcstok(p, b'"')
        return s.cstr(s.tok)

    def nextline(s):
        if s.tok is None or s.tok == 'NULL': return
        p = s.b.index(0, s.tok) + 1
        if s.b[p] != 0x0A: s.tok = s.tcstok(None, b'\n')

    def gobegin(s):
        s.b[:s.n] = s.raw; s.b[s.n] = 0; s.start = True


class Csl:
    def __init__(s, parent=None):
        if parent:
            s.formats, s.datas, s.msgs = parent.formats, parent.datas, parent.msgs
            s.remline, s.remstart, s.remend, s.sep = parent.remline, parent.remstart, parent.remend, parent.sep
            s.block = parent.block
            s.parent_remarks = parent.parent_remarks       # child shares the parent's m_CslRemarks pointers
            s.inc = True; s.dummy_ok = False
        else:
            s.formats, s.datas, s.msgs = [], [], []
            s.remline, s.remstart, s.remend, s.sep = ';', '/*', '*/', b', \t\r\n'
            s.block = False; s.parent_remarks = s; s.inc = False; s.dummy_ok = True
        s.ferr = s.derr = 0; s.end = False

    def remarks(s):
        r = s.parent_remarks
        return [r.remline, r.remstart, r.remend, '#SEPRATOR', '#REMARKLINE', '#REMARKSTART', '#REMARKEND']

    def procremark(s, t):
        txt = s.t.cstr(t); i = next((k for k, w in enumerate(s.remarks()) if icmp(txt, w)), -1)
        if s.block and i != 2: return True
        if i == 1: s.block = True; return True
        if i == 2: s.block = False; return True
        if i in (3, 4, 5, 6):
            v = s.t.get(); v = s.t.cstr(v)
            if i == 3:
                s.sep = (v.encode('cp949') if v is not None else b', \t\r\n'); s.t.seps = s.sep
            elif i == 4: s.remline = v if v is not None else ';'
            elif i == 5: s.remstart = v if v is not None else '/*'
            else: s.remend = v if v is not None else '*/'
            return True
        if i == 0 or txt.encode('cp949')[:len(s.remline)].lower() == s.remline.encode('cp949').lower():
            s.t.nextline(); return True
        return False

    def datatok(s):
        while True:
            t = s.t.get()
            if t is None:
                s.ferr += 1; s.msgs.append('DATA DEFINNING, EOF Come')
                if not s.dummy_ok: FLAGS.append('EOF in an included data row: m_pDummyNull uninitialised (S02-B15)')
                return ''
            if not s.procremark(t): return s.t.cstr(t)

    def makeformat(s):
        name = None; params = []
        while True:
            t = s.t.get()
            if t is None:
                s.ferr += 1; s.msgs.append('FORMAT DEFINNING, EOF Come.'); return None
            if s.procremark(t): continue
            txt = s.t.cstr(t)
            if name is None: name = txt[:64]; continue
            k = next((k for k, w in enumerate(PARS) if icmp(txt, w)), -1)
            if 0 <= k <= 17: params.append(k); continue
            if k == 18: return (name, params)
            j = next((j for j, f in enumerate(s.formats) if icmp(txt, f[0])), -1)
            if j > 0: FLAGS.append(f'format {name} inherits non-first format {txt}: array-stride read (S02-B12)')
            if j >= 0: params += s.formats[j][1]
            else: s.ferr += 1; s.msgs.append(f'{txt} - FORMAT DEFINING, UNKNOWNED PARAMATER.')

    def makedata(s, fi, f, line):
        row = []
        for k in f[1]:
            if k <= 3: v = s.datatok(); row.append(int(v) if v.lstrip('+-').isdigit() else ('atoi', v))
            elif k <= 5: row.append(('hex', s.datatok()))
            elif k <= 7: row.append(('float', s.datatok()))
            elif k <= 11:
                v = s.t.getstr(); row.append(v)
                lim = SIZE[k]
                if len(v.encode('cp949')) >= lim: FLAGS.append(f'string longer than {lim - 1}: heap overflow')
            elif k <= 13: v = s.t.getstr(); row.append(('key', v[:1]))
            else:
                row.append(('array-marker', PARS[k]))
                if k in (14, 15): FLAGS.append('ARRAYSRT column: writer/reader offsets diverge (S02-B11)')
        s.datas.append((fi, f[0], row, line))

    def procdata(s, txt, line):
        j = next((j for j, f in enumerate(s.formats) if icmp(txt, f[0])), -1)
        if j < 0: return False
        s.makedata(j, s.formats[j], line); return True

    def proccmd(s, txt, fn):
        k = next((k for k, w in enumerate(CMDS) if icmp(txt, w)), -1)
        if k == 0: s.end = True
        elif k == 1:
            f = s.makeformat()
            if f: s.formats.append(f)
        elif k == 2:
            name = s.t.getstr(); s.t.saved = s.t.tok
            child = Csl(s); child.read(os.path.join(os.path.dirname(os.path.abspath(fn)), name))
            s.ferr += child.ferr; s.derr += child.derr       # ReadScriptDone of the child
            s.t.gobegin(); s.t.start = False; s.t.tok = s.t.tcstok(s.t.saved, s.t.seps)
            rest = s.t.cstr(s.t.tok)
            if rest is not None and rest != name and not rest.endswith('"'):
                FLAGS.append(f'include name with separator: resumes at {rest!r}')
        elif k == 3: s.formats.clear(); s.datas.clear()
        elif k == 4: s.formats.clear()
        elif k == 5: s.datas.clear()
        elif k >= 6: s.t.getstr(); FLAGS.append(f'{CMDS[k]} used (binary chunk file, not emulated)')
        else: return False
        return True

    def read(s, fn, lf=False, noend=False):
        try: data = open(fn, 'rb').read()
        except OSError:
            s.ferr += 1; s.msgs.append(f'{"INCLUDE" if s.inc else "FILE"} OPEN ERROR - {fn}'); return False
        if lf: data = data.replace(b'\r\n', b'\n')
        if noend: data = re.sub(rb'#END(?!DEFINE)', b'', data)
        s.t = Tok(data); s.t.seps = s.sep
        while not s.end:
            t = s.t.get()
            if t is None: break
            if s.procremark(t): continue
            txt = s.t.cstr(t); line = s.t.line(t)
            if s.proccmd(txt, fn) or s.procdata(txt, line): continue
            s.msgs.append(f'{txt!r} - UNKNOWNED. (line {line})'); s.derr += 1
        return s.ferr + s.derr == 0


if __name__ == '__main__':
    a = sys.argv[1:]; fn = a[0]
    c = Csl(); ok = c.read(fn, lf='--lf' in a, noend='--noend' in a)
    print(f'{fn}: ReadScript={int(ok)} formats={len(c.formats)} rows={len(c.datas)} ferr={c.ferr} derr={c.derr}')
    print('  formats:', ', '.join(f'{i}:{f[0]}({len(f[1])})' for i, f in enumerate(c.formats)))
    for m in c.msgs: print('  msg:', m)
    for f in sorted(set(FLAGS)): print('  FLAG:', f)
    if '-v' in a:
        for d in c.datas: print('  row', d)
