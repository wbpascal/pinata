"""Read stored-procedure source out of raw SQL Server .bak files (no SQL Server needed); compare with the binaries.

The backups in Files/Server/2016/_Database are uncompressed SQL Server 2008 R2 and 2017 backups. Procedure text sits
in the data pages as plain text (UTF-16LE, or single-byte with cp949 Korean comments); we scan for both. Text longer
than one 8 KB page is split over LOB pages; lob_texts() rejoins it when the in-row root lists the fragments directly
(level 0, every case in these backups but IndexOptimize). "TRUNCATED?" = the text does not end in END/RETURN/GO: a
heuristic, most flagged definitions are complete. A .sql file (the Fixes/ scripts) works wherever a .bak does.
usage: python3 -I bak.py <file.bak|.sql> procs [regex]   procedure names that have source, with origin hints
       python3 -I bak.py <file.bak|.sql> proc <name>       print every distinct stored version of one procedure
       python3 -I bak.py <file.bak> names [regex]          object names (tables, procs, constraints; heuristic)
       python3 -I bak.py cover <bin> [regex]               every {CALL} of re-data/exports/<bin> vs all backups + Fixes
origin hints: KR = Korean header comment (written by the original developers); 3RD? = marks of a private-server
author (KHRISMIZER, SSMS script date 2018/2019). Neither = unknown. Hints only: read the source.
"""
import glob, os, re, struct, sys

R = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DB = f"{R}/Files/Server/2016/_Database"
PROC = re.compile(r"(?:create|alter)\s+proc(?:edure)?\s+(?:\[?dbo\]?\.)?\[?(\w+)", re.I)


def runs(data, minlen=40):
    # UTF-16LE text (ASCII, Latin-1 and the cp1252 extras: umlauts and Korean comments saved through cp1252,
    # punctuation, CJK, Hangul) ...
    for m in re.finditer(rb"(?:[\x09\x0a\x0d\x20-\x7e\xa0-\xff]\x00|[\x00-\xff][\x01\x02]"
                         rb"|[\x00-\xff][\x20-\x33\x4e-\x9f\xac-\xd7\xff])+", data):
        if len(m.group()) >= minlen:
            yield m.group().decode("utf-16le")
    # ... and 8-bit text: part of the procedure source is stored single-byte, with cp949 Korean comments
    for m in re.finditer(rb"[\x09\x0a\x0d\x20-\x7e\x81-\xfe]{%d,}" % minlen, data):
        yield m.group().decode("cp949", "replace")


def lob_texts(data):
    """Source longer than one page: SQL Server keeps it as LOB DATA fragments (records of type 3 on text pages, up
    to 8040 bytes each) listed by an in-row root {u8 4, u8 level 0, u8, u8 flags, u32, u32 blob id, links {u32 end offset,
    u32 page, u16 file, u16 slot}…} in the sysobjvalues row. Rejoin every such list; yields the joined UTF-16 text."""
    frags = {}
    for p in range(0, len(data) - 8191, 512):  # pages are 512-aligned in the backup stream, not 8 KB-aligned
        if data[p] != 1 or data[p + 1] != 3: continue
        nslots, free = struct.unpack_from("<H", data, p + 22)[0], struct.unpack_from("<H", data, p + 30)[0]
        if not 0 < nslots < 200 or not 96 <= free <= 8192: continue
        pid, fid = struct.unpack_from("<IH", data, p + 32)
        for s in range(nslots):
            off = struct.unpack_from("<H", data, p + 8190 - 2 * s)[0]
            if not 96 <= off < 8178 or struct.unpack_from("<H", data, p + off + 12)[0] != 3: continue
            end = struct.unpack_from("<H", data, p + off + 2)[0]
            frags[(pid, fid, s)] = data[p + off + 14:p + off + min(end, 8192 - off)]
    for m in re.finditer(rb"\x04\x00\x00[\x00-\xff]", data):
        o, prev, parts = m.start() + 12, 0, []
        while o + 12 <= len(data):
            size, pid, fid, slot = struct.unpack_from("<IIHH", data, o)
            f = frags.get((pid, fid, slot))
            if f is None or not prev < size <= prev + len(f): break
            parts.append(f[:size - prev]); prev, o = size, o + 12
        if len(parts) > 1:
            yield b"".join(parts).decode("utf-16le", "replace")


def procs(data):
    out = {}
    for s in [*runs(data), *lob_texts(data)]:
        m = PROC.search(s)
        if m:
            v = out.setdefault(m.group(1).lower(), (m.group(1), []))[1]
            if s not in v: v.append(s)  # whole run: keeps a header comment placed before CREATE
    for _, v in out.values():  # drop the cut-off first pages of sources that lob_texts rejoined
        v[:] = [s for s in v if not any(s != t and s.strip() in t for t in v)]
    return out


def load(path):
    data = open(path, "rb").read()
    if not path.lower().endswith(".sql"): return procs(data)
    txt = data.decode("utf-16") if data[:2] in (b"\xff\xfe", b"\xfe\xff") else data.decode("utf-8-sig", "replace")
    out = {}
    for part in re.split(r"^\s*GO\s*$", txt, flags=re.M | re.I):
        m = PROC.search(part)
        if m: out.setdefault(m.group(1).lower(), (m.group(1), []))[1].append(part.strip())
    return out


def truncated(src):
    return not re.search(r"\b(END|RETURN\s*\S*|GO)\s*;?(\s*--[^\n]*)?\s*\S?\s*$", src, re.I)


def origin(src):
    tags = ["KR"] if re.search("[가-힣]", src) else []
    if re.search(r"KHRISMIZER|Script Date: \d+/\d+/201[89]", src): tags.append("3RD?")
    return ",".join(tags)


def nparams(src):
    s = re.sub(r"/\*.*?\*/|--[^\n]*", "", src, flags=re.S)
    m = PROC.search(s)
    s = s[m.end():] if m else s
    a = re.search(r"\bAS\b", s, re.I)
    return len(re.findall(r"@\w+\s+\w", s[:a.start()] if a else s))


def cover(bin_, pat=""):
    srcs = sorted(glob.glob(f"{DB}/*.bak")) + sorted(glob.glob(f"{DB}/Fixes/**/*.sql", recursive=True))
    P = {os.path.relpath(f, DB): load(f) for f in srcs}
    calls = {}
    for line in open(f"{R}/re-data/exports/{bin_}/strings.tsv", encoding="utf-8", errors="replace"):
        m = re.search(r"\{\s*(?:\?\s*=\s*)?CALL\s+(?:dbo\.)?([A-Za-z]\w+)\s*(?:\(([^)]*)\))?", line, re.I)
        if m: calls[m.group(1)] = (m.group(2) or "").count("?")
    found = same = 0
    for name, n in sorted(calls.items(), key=lambda x: x[0].lower()):
        if not re.search(pat, name, re.I): continue
        hits = []
        for f, p in P.items():
            for src in p.get(name.lower(), (0, []))[1]:
                k = nparams(src)
                hits.append(f"{f}:{'=' if k == n else k}{'[' + origin(src) + ']' if origin(src) else ''}")
        found += bool(hits); same += any(":=" in h for h in hits)
        print(f"{name}({n}) " + (" ".join(dict.fromkeys(hits)) if hits else "MISSING"))
    print(f"# {bin_}: {len(calls) if not pat else found} calls listed, {found} with source, {same} with the same "
          f"parameter count ('=' = same count as the binary, a number = the backup's count)")


def main(path, cmd="", arg=""):
    if path == "cover": return cover(cmd, arg)
    P = load(path)
    if cmd == "procs":
        for k, (name, v) in sorted(P.items()):
            if re.search(arg, name, re.I):
                print(name, f"({len(v)} versions)" if len(v) > 1 else "", "TRUNCATED?" if all(map(truncated, v)) else "",
                      " ".join(sorted({origin(s) for s in v} - {""})))
    elif cmd == "proc":
        name, v = P.get(arg.lower(), (arg, []))
        if not v: sys.exit(f"{arg}: no source in this backup (try `names {arg}`)")
        for i, src in enumerate(v, 1):
            print(f"-- {name} version {i}/{len(v)}{'  TRUNCATED?' if truncated(src) else ''}\n{src.rstrip()}\n")
    elif cmd == "names":
        data = open(path, "rb").read()
        ids = {m.group().decode("utf-16le") for m in re.finditer(rb"[A-Za-z_]\x00(?:[A-Za-z0-9_]\x00){3,80}", data)}
        for n in sorted(ids):
            if re.match(r"(t[A-Z]|p_|usp_|fn_|v_|PK_|TPK_|TDF_|TIX_)", n) and re.search(arg, n, re.I): print(n)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    if len(sys.argv) < 3: sys.exit(__doc__)
    main(*sys.argv[1:4])
