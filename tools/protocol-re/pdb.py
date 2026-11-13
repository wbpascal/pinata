#!/usr/bin/env python3
"""Minimal MSVC PDB 7 reader (stdlib only): types (structs/unions/enums) and public symbols.

  python3 -I pdb.py Files/Client/2017/Fiesta.pdb types [REGEX]       # C-like struct/union/enum dump
  python3 -I pdb.py Files/Client/2017/Fiesta.pdb publics [REGEX]     # VA<TAB>mangled<TAB>demangled-ish
  python3 -I pdb.py Files/Client/2017/Fiesta.pdb json OUT.json       # everything as JSON (types + publics)
  python3 -I pdb.py Files/Client/2017/Fiesta.pdb layouts OUT.json    # opcode -> name + flattened PROTO layout (C02)
  python3 -I pdb.py A.pdb layouts2016 OUT.json B.pdb ...             # same, merged over several server PDBs (S01)
  python3 -I pdb.py Files/Client/2017/Fiesta.pdb selftest            # asserts a few known facts

Publics need the matching PE next to the PDB (same basename, .bin or .exe) for section bases.
shortcut: only the leaf kinds Fiesta's PDB uses for data types are decoded (no method lists,
no module-private S_GPROC32 symbols); extend LEAF handling when an item needs more.
"""
import json, os, re, struct, sys

# ---- MSF container -------------------------------------------------------------------------
class MSF:
    def __init__(self, path):
        self.f = open(path, 'rb')
        hdr = self.f.read(56)
        assert hdr[:32] == b'Microsoft C/C++ MSF 7.00\r\n\x1aDS\0\0\0', 'not a PDB 7 file'
        self.bs, _, _, ndir, _, bmap = struct.unpack_from('<6I', hdr, 32)
        nb = -(-ndir // self.bs)
        dirblocks = struct.unpack('<%dI' % nb, self._blk(bmap)[:4 * nb])
        d = b''.join(self._blk(b) for b in dirblocks)[:ndir]
        n = struct.unpack_from('<I', d)[0]
        sizes = struct.unpack_from('<%dI' % n, d, 4)
        pos, self.streams = 4 + 4 * n, []
        for s in sizes:
            s = 0 if s == 0xFFFFFFFF else s
            k = -(-s // self.bs)
            self.streams.append((s, struct.unpack_from('<%dI' % k, d, pos)))
            pos += 4 * k

    def _blk(self, i):
        self.f.seek(i * self.bs)
        return self.f.read(self.bs)

    def stream(self, i):
        size, blocks = self.streams[i]
        return b''.join(self._blk(b) for b in blocks)[:size]

# ---- type records --------------------------------------------------------------------------
NUM = {0x8000: '<b', 0x8001: '<h', 0x8002: '<H', 0x8003: '<i', 0x8004: '<I', 0x8009: '<q', 0x800a: '<Q'}
BASIC = {0x03: 'void', 0x10: 'char', 0x11: 'short', 0x12: 'long', 0x13: '__int64', 0x20: 'uchar', 0x21: 'ushort',
         0x22: 'ulong', 0x23: 'unsigned __int64', 0x30: 'bool', 0x40: 'float', 0x41: 'double', 0x68: 'int8',
         0x69: 'uint8', 0x70: 'char', 0x71: 'wchar_t', 0x72: 'short', 0x73: 'ushort', 0x74: 'int', 0x75: 'uint',
         0x76: '__int64', 0x77: 'unsigned __int64'}

def numeric(b, o):
    v = struct.unpack_from('<H', b, o)[0]
    if v < 0x8000:
        return v, o + 2
    fmt = NUM[v]
    return struct.unpack_from(fmt, b, o + 2)[0], o + 2 + struct.calcsize(fmt)

def cstr(b, o):
    e = b.index(b'\0', o)
    return b[o:e].decode('latin-1'), e + 1

def parse_fieldlist(b):
    out, o = [], 0
    while o < len(b):
        if b[o] >= 0xF0:          # padding
            o += b[o] & 0x0F
            continue
        k = struct.unpack_from('<H', b, o)[0]; o += 2
        if k == 0x150d:           # LF_MEMBER
            _, t = struct.unpack_from('<HI', b, o); off, o = numeric(b, o + 6); n, o = cstr(b, o)
            out.append(('member', n, t, off))
        elif k == 0x1502:         # LF_ENUMERATE
            v, o = numeric(b, o + 2); n, o = cstr(b, o)
            out.append(('enum', n, v))
        elif k == 0x1400:         # LF_BCLASS
            _, t = struct.unpack_from('<HI', b, o); off, o = numeric(b, o + 6)
            out.append(('base', t, off))
        elif k in (0x1401, 0x1402):  # LF_VBCLASS / LF_IVBCLASS
            _, o = numeric(b, o + 10); _, o = numeric(b, o)
        elif k == 0x150e:         # LF_STMEMBER
            n, o = cstr(b, o + 6)
        elif k == 0x150f:         # LF_METHOD
            n, o = cstr(b, o + 6); out.append(('method', n))
        elif k == 0x1511:         # LF_ONEMETHOD
            attr = struct.unpack_from('<H', b, o)[0]; o += 6
            if (attr >> 2) & 7 in (4, 6):
                o += 4
            n, o = cstr(b, o); out.append(('method', n))
        elif k == 0x1510:         # LF_NESTTYPE
            n, o = cstr(b, o + 6)
        elif k in (0x1409, 0x1404):  # LF_VFUNCTAB / LF_INDEX (continuation)
            t = struct.unpack_from('<I', b, o + 2)[0]; o += 6
            if k == 0x1404:
                out.append(('index', t))
        else:
            raise ValueError('fieldlist leaf %#x' % k)
    return out

class Types:
    def __init__(self, data):
        self.ti0, self.ti1 = struct.unpack_from('<II', data, 8)
        hsz = struct.unpack_from('<I', data, 4)[0]
        self.rec, o = {}, hsz
        ti = self.ti0
        while o < len(data):
            ln, kind = struct.unpack_from('<HH', data, o)
            self.rec[ti] = (kind, data[o + 4:o + 2 + ln])
            o += 2 + ln; ti += 1

    def fields(self, ti):
        out = []
        for f in parse_fieldlist(self.rec[ti][1]) if ti in self.rec else []:
            out += self.fields(f[1]) if f[0] == 'index' else [f]
        return out

    def udt(self, ti):
        """(kind, name, size, fieldlist-ti, forward?) for struct/class/union/enum records."""
        kind, b = self.rec[ti]
        if kind in (0x1504, 0x1505):
            _, prop, fl = struct.unpack_from('<HHI', b); size, o = numeric(b, 16)
        elif kind == 0x1506:
            _, prop, fl = struct.unpack_from('<HHI', b); size, o = numeric(b, 8)
        elif kind == 0x1507:
            _, prop, ut, fl = struct.unpack_from('<HHII', b); size, o = BASIC.get(ut, ut), 12
        else:
            return None
        name, _ = cstr(b, o)
        tag = {0x1504: 'class', 0x1505: 'struct', 0x1506: 'union', 0x1507: 'enum'}[kind]
        return tag, name, size, fl, bool(prop & 0x80)

    def name(self, ti):
        """C-ish type name; arrays as (base, [dims])."""
        if ti < self.ti0:
            base = BASIC.get(ti & 0xff, 'T%#x' % ti)
            return base + ('*' if ti & 0x700 else '')
        kind, b = self.rec[ti]
        if kind in (0x1504, 0x1505, 0x1506, 0x1507):
            return self.udt(ti)[1]
        if kind == 0x1001:        # LF_MODIFIER
            return self.name(struct.unpack_from('<I', b)[0])
        if kind == 0x1002:        # LF_POINTER
            return self.name(struct.unpack_from('<I', b)[0]) + '*'
        if kind == 0x1503:        # LF_ARRAY
            et = struct.unpack_from('<I', b)[0]; size, _ = numeric(b, 8)
            esz = self.size(et)
            return '%s[%s]' % (self.name(et), size // esz if esz else '?')
        if kind == 0x1205:        # LF_BITFIELD
            t, ln, pos = struct.unpack_from('<IBB', b)
            return '%s:%d@%d' % (self.name(t), ln, pos)
        if kind == 0x1008:
            return 'fn*'
        return 'leaf%#x' % kind

    def size(self, ti):
        if ti < self.ti0:
            if ti & 0x700:
                return 4
            return {0x03: 0, 0x10: 1, 0x11: 2, 0x12: 4, 0x13: 8, 0x20: 1, 0x21: 2, 0x22: 4, 0x23: 8, 0x30: 1, 0x40: 4,
                    0x41: 8, 0x68: 1, 0x69: 1, 0x70: 1, 0x71: 2, 0x72: 2, 0x73: 2, 0x74: 4, 0x75: 4, 0x76: 8,
                    0x77: 8}.get(ti & 0xff, 0)
        kind, b = self.rec[ti]
        if kind in (0x1504, 0x1505, 0x1506):
            u = self.udt(ti)
            full = self.complete.get(u[1]) if u[4] else ti   # forward ref -> complete definition
            return self.udt(full)[2] if full else 0
        if kind == 0x1507:
            return 4
        if kind == 0x1001:
            return self.size(struct.unpack_from('<I', b)[0])
        if kind == 0x1002:
            return 4
        if kind == 0x1503:
            return numeric(b, 8)[0]
        return 0

    def all_udts(self):
        """name -> complete (non-forward) type index (the first definition in the PDB).
        self.variants: name -> [ti, ...] when the PDB holds several *different* complete definitions of one name
        (translation units compiled against different headers; S01 part 3 found them in the 2016 server PDBs, e.g.
        CWMClientSession 0x1f7b0 / 0x1f7b8). The first one is not necessarily the one the code uses."""
        self.complete, alldefs = {}, {}
        for ti in range(self.ti0, self.ti1):
            u = self.udt(ti) if self.rec[ti][0] in (0x1504, 0x1505, 0x1506, 0x1507) else None
            if u and not u[4]:
                self.complete.setdefault(u[1], ti)
                alldefs.setdefault(u[1], []).append(ti)
        self.variants = {}
        for n, tis in alldefs.items():
            if len(tis) > 1:
                shapes = {}
                for ti in tis:
                    d = self.describe(ti)
                    shapes.setdefault((d['size'], tuple((f['name'], f.get('offset'), f.get('value'), f.get('type'))
                                                        for f in d['fields'])), ti)
                if len(shapes) > 1:
                    self.variants[n] = list(shapes.values())
        return self.complete

    def describe(self, ti):
        tag, name, size, fl, _ = self.udt(ti)
        d = {'kind': tag, 'name': name, 'size': size, 'fields': []}
        for f in self.fields(fl):
            if f[0] == 'member':
                d['fields'].append({'name': f[1], 'type': self.name(f[2]), 'offset': f[3]})
            elif f[0] == 'enum':
                d['fields'].append({'name': f[1], 'value': f[2]})
            elif f[0] == 'base':
                d.setdefault('bases', []).append(self.name(f[1]))
        return d

# ---- public symbols ------------------------------------------------------------------------
def pe_sections(path):
    b = open(path, 'rb').read(4096)
    pe = struct.unpack_from('<I', b, 0x3c)[0]
    nsec, = struct.unpack_from('<H', b, pe + 6)
    opt = struct.unpack_from('<H', b, pe + 20)[0]
    base = struct.unpack_from('<I', b, pe + 24 + 28)[0]
    s = pe + 24 + opt
    return base, [struct.unpack_from('<I', b, s + 40 * i + 12)[0] for i in range(nsec)]

def publics(msf, pe_path):
    dbi = msf.stream(3)
    symrec = struct.unpack_from('<H', dbi, 20)[0]
    base, secs = pe_sections(pe_path)
    d, o, out = msf.stream(symrec), 0, []
    while o + 4 <= len(d):
        ln, kind = struct.unpack_from('<HH', d, o)
        if kind == 0x110e:        # S_PUB32
            flags, off, seg = struct.unpack_from('<IIH', d, o + 4)
            name, _ = cstr(d, o + 14)
            if 0 < seg <= len(secs):
                out.append((base + secs[seg - 1] + off, name, flags & 2 != 0))
        o += 2 + ln
    return sorted(out)

def demangle_hint(m):
    """'?On_X@Cls@@QAEHHPAX@Z' -> 'Cls::On_X' (names only, no signature)."""
    if not m.startswith('?') or m.startswith('??_'):
        return m
    parts = m[1:].split('@@', 1)[0].split('@')
    return '::'.join(reversed(parts))

# ---- opcodes + packet layouts (work item C02) -----------------------------------------------
PRIM = {'char': 'i8', 'short': 'i16', 'ushort': 'u16', 'long': 'i32', 'ulong': 'u32', '__int64': 'i64',
        'unsigned __int64': 'u64', 'uchar': 'u8', 'bool': 'u8', 'float': 'f32', 'int8': 'i8', 'uint8': 'u8',
        'wchar_t': 'u16', 'int': 'i32', 'uint': 'u32'}
COUNT = re.compile(r'num|cnt|count|len|size', re.I)

def opcodes(t, comp):
    """-> {opcode: [names]}, declaration order (some enums give two names one value: the later is an alias).
    Dept of a cmd enum = its 'NC_<X>_NULL = 0' member (enum names differ: KINGDOMQUEST = KQ; dept 45/46 enums
    are PROTOCOL_USER_CONNECTION / PROTOCOL_AUCTION, no _COMMAND_ infix: S01 review)."""
    dept = {f['name']: f['value'] for f in t.describe(comp['PROTOCOL_COMMAND'])['fields']}
    out = {}
    for n in comp:
        if not n.startswith('PROTOCOL_') or n == 'PROTOCOL_COMMAND':
            continue
        d = t.describe(comp[n])
        if d['kind'] != 'enum':
            continue
        fs = d['fields']
        null = next((f['name'][:-5] for f in fs if f['name'].endswith('_NULL') and f['value'] == 0), None)
        if null not in dept:
            continue                          # LOG_EASY_LOG_SYS (log codes >= 2000), empty enums
        for f in fs:
            if 0 < f['value'] < 1024:
                out.setdefault(dept[null] << 10 | f['value'], []).append(f['name'])
    return out

class Flat:
    """PDB struct -> annotation-style fields [off, type, name, note] (types as in annotations.json)."""
    def __init__(self, t, comp):
        self.t, self.comp, self.structs = t, comp, {}

    def strip(self, ti):
        while ti >= self.t.ti0 and self.t.rec[ti][0] == 0x1001:
            ti = struct.unpack_from('<I', self.t.rec[ti][1])[0]
        return ti

    def full(self, ti):                       # forward ref -> complete udt index
        u = self.t.udt(ti)
        return self.comp.get(u[1], ti) if u[4] else ti

    def prim(self, ti):
        """primitive annotation type of a basic/enum/pointer/bitfield type index, else None"""
        ti = self.strip(ti)
        if ti < self.t.ti0:
            return 'u32' if ti & 0x700 else PRIM.get(BASIC.get(ti & 0xff), 'byte[%d]' % self.t.size(ti))
        kind, b = self.t.rec[ti]
        if kind == 0x1002:
            return 'u32'
        if kind == 0x1507:
            return PRIM.get(self.t.udt(ti)[2], 'i32')
        if kind == 0x1205:
            return self.prim(struct.unpack_from('<I', b)[0])
        return None

    def fields(self, ti, base=0, prefix=''):
        out, prev_bf = [], None
        ti = self.full(ti)
        for f in self.t.fields(self.t.udt(ti)[3]):
            if f[0] == 'base':                # inherited members, unprefixed (C++ access); S01 part 3
                out += self.fields(f[1], base + f[2], prefix)
                continue
            if f[0] != 'member':
                continue
            _, name, mt, off = f
            mt, off, name = self.strip(mt), base + off, prefix + name
            if mt >= self.t.ti0 and self.t.rec[mt][0] == 0x1205:      # bitfields sharing a unit -> one field
                bits = '%s:%s' % (name.rsplit('.', 1)[-1], self.t.name(mt).split(':')[1])   # name:len@pos
                if prev_bf and prev_bf[0] == off:
                    prev_bf[2] += '|' + name.rsplit('.', 1)[-1]
                    prev_bf[3] += ', ' + bits
                    continue
                prev_bf = [off, self.prim(mt), name, 'bits ' + bits]
                out.append(prev_bf)
                continue
            out += self.member(mt, off, name, out)
        return out

    def member(self, mt, off, name, before):
        p = self.prim(mt)
        if p:
            return [[off, p, name, '']]
        kind, b = self.t.rec[mt]
        if kind == 0x1503:
            et, total = self.strip(struct.unpack_from('<I', b)[0]), numeric(b, 8)[0]
            esz = self.t.size(et)
            if total == 0:                    # trailing variable-length array; count field guessed by name
                cnt = next((f[2] for f in reversed(before) if COUNT.search(f[2].rsplit('.', 1)[-1])
                            and f[1][0] in 'iu' and '[' not in f[1]), 'rest')
                dim, note = cnt, 'variable length' + ('' if cnt != 'rest' else ', count unknown')
            else:
                dim, note = total // esz if esz else 0, ''
            ep = self.prim(et)
            if ep and '[' not in ep:          # char[] = string; uchar[] stays u8[] (bytes)
                return [[off, '%s[%s]' % ('char' if ep == 'i8' else ep, dim), name, note]]
            if self.t.rec.get(et, (0,))[0] in (0x1504, 0x1505, 0x1506):
                sn = self.reg(et)
                return [[off, '%s[%s]' % (sn, dim), name, (note + ', ' if note else '') + 'element %s' % sn]]
            return [[off, 'byte[%d]' % total, name, 'nested array ' + self.t.name(mt)]]
        if kind in (0x1504, 0x1505):
            return self.fields(mt, off, name + '.')
        if kind == 0x1506:
            u = self.t.udt(self.full(mt))
            alts = [x for x in self.t.fields(u[3]) if x[0] == 'member']
            note = '%s (union: %s)' % (u[1], ', '.join(x[1] for x in alts))
            if any(re.search('name', x[1], re.I) and self.t.size(x[2]) == u[2] and self.t.rec.get(self.strip(x[2]), (0,))[0] == 0x1503
                   for x in alts):            # Name5, Name256Byte, ORToken: string unions
                return [[off, 'char[%d]' % u[2], name, u[1]]]
            whole = [self.prim(x[2]) for x in alts if self.prim(x[2]) and self.t.size(x[2]) == u[2]]
            return [[off, whole[0] if whole else 'byte[%d]' % u[2], name, note]]
        return [[off, 'byte[%d]' % self.t.size(mt), name, self.t.name(mt)]]

    def variable(self, fs):
        """any variable-length array in these fields or in their element structs"""
        return any('variable' in f[3] or (self.structs.get(f[1].split('[')[0]) and
                                          self.variable(self.structs[f[1].split('[')[0]]['fields'])) for f in fs)

    def reg(self, ti):
        """register an array element struct in self.structs, return its name"""
        ti = self.full(ti)
        u = self.t.udt(ti)
        if u[1] not in self.structs:
            self.structs[u[1]] = None         # recursion guard
            if u[0] == 'union':
                f = self.member(ti, 0, u[1], [])
            else:
                f = self.fields(ti)
            self.structs[u[1]] = {'size': u[2], 'fields': f}
        return u[1]

def layouts(t, comp, about=None):
    ops, fl = opcodes(t, comp), Flat(t, comp)

    def entry(n):
        ti, e = comp.get('PROTO_' + n), {'name': n, 'struct': None}
        alias = next((a for a in ('PROTO_' + n.replace('_CLIENT_', '_', 1), 'PROTO_' + n.replace('_ZONE_', '_', 1))
                      if ti is None and a in comp), None)
        if alias:                             # NC_CHAR_CLIENT_BASE_CMD -> PROTO_NC_CHAR_BASE_CMD (inferred)
            ti, e['struct_alias'] = comp[alias], True
        if ti is not None:
            u, fs = t.udt(ti), fl.fields(ti)
            # an empty C++ struct has sizeof 1; the packet carries no field, so document 0 bytes
            e.update(struct=u[1], size=u[2] if fs else 0, variable=fl.variable(fs), fields=fs)
            for vti in getattr(t, 'variants', {}).get(u[1], [])[1:]:   # other definitions of the same struct name
                vfs = fl.fields(vti)
                e.setdefault('variants', []).append({'name': n, 'struct': u[1], 'size': t.udt(vti)[2] if vfs else 0,
                                                     'variable': fl.variable(vfs), 'fields': vfs, 'variant': True})
        return e

    out = {}
    for op, ns in sorted(ops.items()):
        e = entry(ns[0])
        if len(ns) > 1:                       # two names, one value: often two packets (directions/links)
            e['aliases'] = ns[1:]
            e['alts'] = [a for a in map(entry, ns[1:]) if a['struct']]
        if e.get('variants'):                 # decoders pick an alt by size: a second definition is one more candidate
            e['alts'] = e.get('alts', []) + e.pop('variants')
        for a in e.get('alts', []):
            a.pop('variants', None)
        out['0x%04x' % op] = e
    return {'_about': about or 'Generated by tools/protocol-re/pdb.py layouts from Files/Client/2017/Fiesta.pdb (work item C02). '
                      'Evidence level pdb2017: a 2017 build; confirm against 2016 code. Offsets are PROTO struct '
                      'offsets: server-internal packets about a player carry a 6-byte ref prefix in 2016 that the '
                      'struct does not include (docs/knowledge/Z01.md). Field types follow annotations.json; '
                      'a dimension that is a field name means "count taken from that field" (guessed by name). '
                      'Empty structs are documented as size 0 (C++ sizeof 1). "alts": layouts of alias names '
                      'sharing the value; decoders pick the one whose size fits the payload.',
            'opcodes': out, 'structs': dict(sorted(fl.structs.items()))}

ABOUT2016 = ('Generated by tools/protocol-re/pdb.py layouts2016 from the 2016 server PDBs in Files/Server/NA2016 '
             '(work item S01; same builds as Files/Server/2016). Evidence level pdb2016 (counts as read in the 2016 code). '
             'Merged from %s: per opcode the first PDB (in that order) whose own PROTO struct exists; a struct only '
             'reached through the CLIENT_/ZONE_ name alias is used only when no PDB has the exact struct. "pdbs" = the '
             'PDBs whose opcode enums carry the value; "disagreements" = exact structs that differ between PDBs. '
             'Offsets are PROTO struct offsets. Server-internal packets about a player carry a 6-byte ref '
             '(NETPACKETZONEHEADER clienthandle, charregistnumber; docs/knowledge/Z01.md): about 215 structs declare it '
             'as their first member (header.clienthandle, ...), the others do not include it. Field types follow annotations.json; a dimension that '
             'is a field name means "count taken from that field" (guessed by name). Empty structs are size 0. '
             '"alts": alias names sharing the value, and ("variant": true) other definitions of the same PROTO struct that a '
             'PDB holds (translation units compiled against different headers, docs/knowledge/S01.md §2.4); decoders pick '
             'the one whose size fits the payload. "used_variant": true = the primary layout is the definition the 2016 '
             'zone sends (0x0452, 0x10AE, 0x5C05), not the first one in the PDB.')

# Opcodes whose PROTO struct has two definitions in Zone.pdb: size of the one the 2016 code sends (S01 §2.4, review):
# 0x0452 zone sends 0x2B (D05-B2), 0x10AE zone FUN_0045c0b0 sends 0x33 incl. the 2-byte opcode, 0x5C05 zone
# FUN_0059e410 sends 0x36. That definition becomes the primary layout, the other stays an alt with "variant": true.
USED_VARIANT2016 = {'0x0452': 43, '0x10ae': 49, '0x5c05': 54}

def merge_layouts(parts):
    """[(label, layouts())] -> one layouts dict (pdb2016): exact structs first, disagreements listed"""
    shape = lambda e: (e.get('size'), [f[:3] for f in e.get('fields') or []])   # notes differ by PDB (union names)
    out, structs, dis = {}, {}, []
    for op in sorted(set().union(*(L['opcodes'] for _, L in parts))):
        es = [(lab, L['opcodes'][op]) for lab, L in parts if op in L['opcodes']]
        exact = [(l, e) for l, e in es if e['struct'] and not e.get('struct_alias')]
        lab, pick = (exact or [x for x in es if x[1]['struct']] or es)[0]
        out[op] = dict(pick, pdbs=[l for l, _ in es])
        alts, variants = {}, []               # alias layouts: each PDB holds only the structs its code uses
        for _, e in es:
            for a in e.get('alts', []):
                if not a.get('variant'):
                    alts.setdefault(a['name'], a)
                elif shape(a) != shape(pick) and all(shape(a) != shape(v) for v in variants):
                    variants.append(a)        # another definition of the picked struct (same name, other header)
        used = USED_VARIANT2016.get(op)
        if used is not None and out[op]['size'] != used:
            v = next(v for v in variants if v['size'] == used)
            prim = {k: out[op][k] for k in ('size', 'variable', 'fields') if k in out[op]}
            variants[variants.index(v)] = dict(v, **prim)
            out[op].update({k: v[k] for k in ('size', 'variable', 'fields') if k in v}, used_variant=True)
        if alts or variants:
            out[op]['alts'] = [alts[n] for n in pick.get('aliases', []) if n in alts] + variants
        if variants:
            dis.append({'op': op, 'kind': 'variants', 'pdbs': {
                l: sorted({e['size']} | {a['size'] for a in e.get('alts', []) if a.get('variant')}) for l, e in es if e['struct']}})
        if len({e['name'] for _, e in es}) > 1:
            dis.append({'op': op, 'kind': 'name', 'pdbs': {l: e['name'] for l, e in es}})
        diff = [(l, e) for l, e in es if e['struct'] and shape(e) != shape(pick)]
        if diff:
            dis.append({'op': op, 'kind': 'struct' if any(not e.get('struct_alias') for _, e in diff) else 'alias only',
                        'pdbs': {l: [e['struct'], e['size']] for l, e in [(lab, pick)] + diff}})
    for lab, L in parts:
        for n, st in L['structs'].items():
            if n not in structs:
                structs[n] = st
            elif shape(st) != shape(structs[n]):
                dis.append({'struct': n, 'kind': 'element struct', 'pdbs': lab})
    return {'_about': ABOUT2016 % ', '.join(l for l, _ in parts), 'opcodes': out,
            'structs': dict(sorted(structs.items())), 'disagreements': dis}

# ---- CLI -----------------------------------------------------------------------------------
def fmt_udt(d):
    if d['kind'] == 'enum':
        body = ''.join('  %s = %s,\n' % (f['name'], f['value']) for f in d['fields'])
        return 'enum %s {\n%s};\n' % (d['name'], body)
    bases = ' : ' + ', '.join(d['bases']) if d.get('bases') else ''
    body = ''.join('  /*%#06x*/ %s %s;\n' % (f['offset'], f['type'], f['name']) for f in d['fields'])
    return '%s %s%s { // size %#x\n%s};\n' % (d['kind'], d['name'], bases, d['size'], body)

def main(a):
    msf = MSF(a[0]); cmd = a[1]
    stem = os.path.splitext(a[0])[0]
    pe = next((stem + e for e in ('.bin', '.exe') if os.path.exists(stem + e)), None)
    if cmd in ('types', 'json', 'layouts'):
        t = Types(msf.stream(2)); comp = t.all_udts()
    if cmd == 'types':
        rx = re.compile(a[2] if len(a) > 2 else '.')
        for n in sorted(comp):
            if rx.search(n):
                vs = t.variants.get(n, [comp[n]])
                for k, ti in enumerate(vs):     # several different definitions of one name: print each (S01)
                    if len(vs) > 1:
                        sys.stdout.write('// definition %d of %d of %s (different headers per translation unit)\n' % (k + 1, len(vs), n))
                    sys.stdout.write(fmt_udt(t.describe(ti)) + '\n')
    elif cmd == 'publics':
        rx = re.compile(a[2] if len(a) > 2 else '.')
        for va, m, fn in publics(msf, pe):
            if rx.search(m):
                print('%08x\t%s\t%s' % (va, m, demangle_hint(m)))
    elif cmd == 'selftest':       # known facts of Files/Client/2017/Fiesta.pdb
        t = Types(msf.stream(2)); comp = t.all_udts()
        d = t.describe(comp['PROTO_NC_MAP_LOGINFAIL_ACK'])
        assert (d['size'], [f['name'] for f in d['fields']]) == (3, ['err', 'nWrongDataFileIndex']), d
        assert {'name': 'NC_MAP_LOGIN_REQ', 'value': 1} in t.describe(comp['PROTOCOL_COMMAND_MAP'])['fields']
        assert t.describe(comp['PROTO_NC_MAP_LOGIN_REQ'])['fields'][1]['type'] == 'Name8[50]'
        assert (0x47a9a0, '?On_NC_MAP_LOGIN_ACK@ZoneLoginNetFrameWork@@QAEHHPAX@Z', True) in publics(msf, pe)
        L = layouts(t, comp)['opcodes']
        assert L['0x5801']['name'] == 'NC_KQ_LIST_REQ'      # enum PROTOCOL_COMMAND_KINGDOMQUEST
        assert L['0xb411']['name'] == 'NC_USER_CONNECTION_DB_CHANGE_CHAR_ID_ITEM_USE_REQ'   # enum PROTOCOL_USER_CONNECTION (S01 review)
        assert L['0x1804']['fields'] == [[0, 'u16', 'err', ''], [2, 'u8', 'nWrongDataFileIndex', '']], L['0x1805']
        assert L['0x2001']['fields'][-1] == [2, 'u8[len]', 'content', 'variable length'], L['0x2001']
        print('ok')
    elif cmd == 'layouts':        # docs/protocol/pdb-layouts.json
        json.dump(layouts(t, comp), open(a[2], 'w'), indent=1)
    elif cmd == 'layouts2016':    # docs/protocol/pdb2016-layouts.json: pdb.py <pdb> layouts2016 OUT [more PDBs]
        parts = []
        for p in [a[0]] + a[3:]:
            tp = Types(MSF(p).stream(2)); cp = tp.all_udts()
            parts.append((os.path.splitext(os.path.basename(p))[0], layouts(tp, cp)))
        json.dump(merge_layouts(parts), open(a[2], 'w'), indent=1)
    elif cmd == 'json':
        out = {'types': {n: t.describe(ti) for n, ti in sorted(comp.items())},
               'publics': [{'va': '%08x' % va, 'name': m, 'func': fn} for va, m, fn in publics(msf, pe)]}
        json.dump(out, open(a[2], 'w'), indent=0)
    else:
        sys.exit(__doc__)

if __name__ == '__main__':
    main(sys.argv[1:]) if len(sys.argv) > 2 else sys.exit(__doc__)
