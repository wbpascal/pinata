"""Decode Fiesta .shn tables (format and cipher taken from 5ZoneServer2.exe FUN_0062a780 / FUN_0062a0b0).

layout: [0x00..0x24) header (u32 @0x1c != 0 -> body encrypted)
        body @0x24: u32 ?, u32 rowCount @0x28, u32 defaultRowLen @0x2c, u32 colCount @0x30,
        colCount x {char name[48], u32 type, u32 size} @0x34, then rows, each prefixed by u16 rowLen.
usage: python3 -I shn.py <file.shn> [--csv]
"""
import struct, sys


def decrypt(buf, start):
    n = len(buf) - start
    key = n & 0xFF
    for i in range(n - 1, -1, -1):
        buf[start + i] ^= key
        key = ((i & 0xFF) * 11 ^ ((i & 0xF) + 0x55) ^ key ^ 0xAA) & 0xFF
    return buf


def read(path, enc="cp1252"):
    b = bytearray(open(path, "rb").read())
    if struct.unpack_from("<I", b, 0x1C)[0]:
        decrypt(b, 0x24)
    rows_n, deflen, cols_n = struct.unpack_from("<III", b, 0x28)
    cols, o = [], 0x34
    for _ in range(cols_n):
        name = b[o:o + 48].split(b"\0")[0].decode(enc, "replace")
        typ, size = struct.unpack_from("<II", b, o + 48)
        cols.append((name, typ, size)); o += 0x38
    rows = []
    for _ in range(rows_n):
        rl = struct.unpack_from("<H", b, o)[0]
        p, row = o + 2, []
        for name, typ, size in cols:
            raw = b[p:p + size]
            if typ == 26:  # variable-length NUL-terminated string, runs to the end of the row
                s = b[p:o + rl].split(b"\0")[0]
                row.append(s.decode(enc, "replace")); p += len(s) + 1
                continue
            if typ in (9, 0x18, 0x1A) or (typ not in (1, 2, 3, 0xB, 0x0C, 0x0D, 0x10, 0x12, 0x14, 0x15, 0x16, 0x1B) and size > 4):
                v = raw.split(b"\0")[0].decode(enc, "replace")
            elif size == 1: v = raw[0]
            elif size == 2: v = struct.unpack_from("<H", raw)[0]
            elif size == 4: v = struct.unpack_from("<I", raw)[0]
            else: v = raw.hex()
            row.append(v); p += size
        rows.append(row); o += rl
    return cols, rows


if __name__ == "__main__":
    cols, rows = read(sys.argv[1])
    assert rows is not None
    print("\t".join(f"{n}({t}:{s})" for n, t, s in cols))
    for r in rows:
        print("\t".join(str(x) for x in r))
