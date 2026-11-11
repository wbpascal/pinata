"""Read stored-procedure source out of raw SQL Server .bak files (no SQL Server needed); compare with the binaries.

The backups in Files/Server/2016/_Database are uncompressed SQL Server 2008 R2 and 2017 backups. Procedure text sits
in the data pages as plain text (UTF-16LE, or single-byte with cp949 Korean comments); we scan for both. Text longer
than one 8 KB page is split over LOB pages, which we do not reassemble: such definitions print cut off and are
flagged "TRUNCATED?". A .sql file (the Fixes/ scripts) works wherever a .bak does.
usage: python3 -I bak.py <file.bak|.sql> procs [regex]   procedure names that have source, with origin hints
       python3 -I bak.py <file.bak|.sql> proc <name>       print every distinct stored version of one procedure
       python3 -I bak.py <file.bak> names [regex]          object names (tables, procs, constraints; heuristic)
       python3 -I bak.py cover <bin> [regex]               every {CALL} of re-data/exports/<bin> vs all backups + Fixes
origin hints: KR = Korean header comment (written by the original developers); 3RD? = marks of a private-server
author (KHRISMIZER, SSMS script date 2018/2019). Neither = unknown. Hints only: read the source.
"""
import glob, os, re, sys

R = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DB = f"{R}/Files/Server/2016/_Database"
PROC = re.compile(r"(?:create|alter)\s+proc(?:edure)?\s+(?:\[?dbo\]?\.)?\[?(\w+)", re.I)


def runs(data, minlen=40):
    # UTF-16LE text (ASCII, punctuation, CJK, Hangul) ...
    for m in re.finditer(rb"(?:[\x09\x0a\x0d\x20-\x7e]\x00|[\x00-\xff][\x20-\x33\x4e-\x9f\xac-\xd7\xff])+", data):
        if len(m.group()) >= minlen:
            yield m.group().decode("utf-16le")
    # ... and 8-bit text: part of the procedure source is stored single-byte, with cp949 Korean comments
    for m in re.finditer(rb"[\x09\x0a\x0d\x20-\x7e\x81-\xfe]{%d,}" % minlen, data):
        yield m.group().decode("cp949", "replace")


def procs(data):
    out = {}
    for s in runs(data):
        m = PROC.search(s)
        if m:
            v = out.setdefault(m.group(1).lower(), (m.group(1), []))[1]
            if s not in v: v.append(s)  # whole run: keeps a header comment placed before CREATE
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
    return not re.search(r"\b(END|RETURN\s*\S*|GO)\s*;?\s*\S?\s*$", src, re.I)


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
