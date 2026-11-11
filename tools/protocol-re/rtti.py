"""MSVC x86 RTTI: map class name -> primary vftable entries, straight from the PE file.

TypeDescriptor  = { pVFTable, spare, char name[] }       name like ".?AVShinePlayer@ShineObjectClass@@"
CompleteObjectLocator = { sig=0, offset, cdOffset, pTypeDescriptor, pClassHierarchy }
vftable[-1] = &CompleteObjectLocator
"""
import re, struct


class PE:
    def __init__(self, path):
        self.b = open(path, "rb").read()
        pe = struct.unpack_from("<I", self.b, 0x3C)[0]
        n = struct.unpack_from("<H", self.b, pe + 6)[0]
        opt = struct.unpack_from("<H", self.b, pe + 20)[0]
        self.base = struct.unpack_from("<I", self.b, pe + 52)[0]
        self.secs = []
        for i in range(n):
            s = pe + 24 + opt + 40 * i
            vs, va, rs, rp = struct.unpack_from("<IIII", self.b, s + 8)
            self.secs.append((self.base + va, max(vs, rs), rp, rs))

    def off(self, va):
        for sva, size, rp, rs in self.secs:
            if sva <= va < sva + rs:
                return va - sva + rp
        return None

    def va(self, off):
        for sva, size, rp, rs in self.secs:
            if rp <= off < rp + rs:
                return off - rp + sva
        return None

    def u32(self, va):
        o = self.off(va)
        return None if o is None else struct.unpack_from("<I", self.b, o)[0]


def demangle(n):
    # ".?AVShinePlayer@ShineObjectClass@@" -> "ShineObjectClass::ShinePlayer"
    parts = n[4:].rstrip("@").split("@")
    return "::".join(reversed([p for p in parts if p]))


def vtables(path, max_entries=1024):
    pe = PE(path)
    b = pe.b
    tds = {}
    for m in re.finditer(rb"\.\?A[VU][\w@?$]+@@\x00", b):
        va = pe.va(m.start() - 8)
        if va: tds[va] = demangle(m.group(0)[:-1].decode())
    # complete object locators with offset 0 pointing at a known TypeDescriptor
    cols = {}
    for td_va, name in tds.items():
        for m in re.finditer(re.escape(struct.pack("<I", td_va)), b):
            o = m.start() - 12
            if o < 0: continue
            sig, offset, cd = struct.unpack_from("<III", b, o)
            if sig == 0 and offset == 0:
                cols[pe.va(o)] = name
    out = {}
    for col_va, name in cols.items():
        if col_va is None: continue
        for m in re.finditer(re.escape(struct.pack("<I", col_va)), b):
            vft = pe.va(m.start() + 4)
            entries = []
            for i in range(max_entries):
                e = pe.u32(vft + 4 * i)
                if e is None or not (pe.base <= e < pe.base + 0x2000000) or pe.off(e) is None:
                    break
                # stop when we run into the next object's COL pointer
                if i and e in cols: break
                entries.append(e)
            if entries and (name not in out or len(entries) > len(out[name])):
                out[name] = entries
    return out


if __name__ == "__main__":
    import sys
    vt = vtables(sys.argv[1])
    for k in sorted(vt):
        if len(sys.argv) < 3 or sys.argv[2] in k:
            print(k, len(vt[k]))
    # self-check: vtable slots must point into the image
    assert vt, "no vftables recovered"
