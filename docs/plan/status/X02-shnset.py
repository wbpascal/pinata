"""Change numeric cells of a Fiesta .shn table (X02 part 9, capture-scenarios.md section 9).

usage: python3 -I docs/plan/status/X02-shnset.py <in.shn> <out.shn> <keyColumn>=<keyValue>[#n] <column>=<number> [...]
       python3 -I docs/plan/status/X02-shnset.py <in.shn> <out.shn> --selftest

The row is the n-th (default first) whose <keyColumn> prints as <keyValue> in tools/protocol-re/shn.py. Only
fixed-size integer columns (size 1, 2 or 4) can be set; file length and layout do not change. The body cipher of
shn.py is a position-only XOR stream, so applying it twice restores the file: the same routine encrypts.
Never write into Files/: copy the result to the TEST server's 9Data/Shine by hand and keep the original.
"""
import struct, sys
sys.path.insert(0, "tools/protocol-re")
import shn


def patch(src, dst, key, sets):
    b = bytearray(open(src, "rb").read())
    enc = struct.unpack_from("<I", b, 0x1C)[0]
    if enc: shn.decrypt(b, 0x24)
    cols, rows = shn.read(src)
    if any(t == 26 for _, t, _ in cols): sys.exit("variable-length rows: not supported")
    names = [c[0] for c in cols]
    kcol, kval = key.split("=", 1)
    kval, _, nth = kval.partition("#")
    hits = [i for i, r in enumerate(rows) if str(r[names.index(kcol)]) == kval]
    if len(hits) <= int(nth or 0): sys.exit(f"no row {key} ({len(hits)} match)")
    row = hits[int(nth or 0)]
    o = 0x34 + 0x38 * len(cols)
    for _ in range(row): o += struct.unpack_from("<H", b, o)[0]
    for s in sets:
        col, val = s.split("=", 1)
        i = names.index(col); size = cols[i][2]
        if size not in (1, 2, 4) or isinstance(rows[row][i], str): sys.exit(f"{col}: not a 1/2/4-byte integer column")
        p = o + 2 + sum(c[2] for c in cols[:i])
        old = int.from_bytes(b[p:p + size], "little")
        b[p:p + size] = int(val).to_bytes(size, "little")
        print(f"row {row} ({key}) {col}: {old} -> {val}")
    if enc: shn.decrypt(b, 0x24)
    open(dst, "wb").write(b)


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[3] == "--selftest":
        b = bytearray(open(sys.argv[1], "rb").read()); c = bytearray(b)
        shn.decrypt(c, 0x24); shn.decrypt(c, 0x24)
        print("cipher is its own inverse:", c == b); sys.exit(0)
    if len(sys.argv) < 5: sys.exit(__doc__)
    patch(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:])
