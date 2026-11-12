"""Read one section of a big markdown doc instead of the whole file.

usage: python3 -I sect.py <file.md>              outline: line, size, heading
       python3 -I sect.py <file.md> <sel>...     print the matching sections (with their subsections)
  <sel> = a section number ("5", "5.2", "§5.2") or a case-insensitive regex on the heading text
"""
import re, sys

f, sels = sys.argv[1], sys.argv[2:]
L = open(f, encoding="utf-8").read().split("\n")
fence, heads = False, []                       # (line index, level, text)
for i, l in enumerate(L):
    if l.startswith("```"): fence = not fence
    m = not fence and re.match(r"(#{1,6})\s+(.*)", l)
    if m: heads.append((i, len(m.group(1)), m.group(2)))

def end(k):                                    # section k runs until the next heading of same or higher level
    i, lv, _ = heads[k]
    return next((j for j, l2, _ in heads[k + 1:] if l2 <= lv), len(L))

if not sels:
    for k, (i, lv, t) in enumerate(heads):
        n = sum(len(x) + 1 for x in L[i:end(k)])
        print(f"{i + 1:5} {n / 1000:5.1f}k {'  ' * (lv - 1)}{t}")
    sys.exit()

for s in sels:
    s = s.lstrip("§")
    num = re.fullmatch(r"\d+(\.\d+)*", s)
    hits = [k for k, (_, _, t) in enumerate(heads)
            if (re.match(re.escape(s) + r"\.?\s", t) if num else re.search(s, t, re.I))]
    if not hits: print(f"[sect.py: no heading matches {s!r}; run without a selector for the outline]")
    for k in hits[:1] if num else hits:
        print("\n".join(L[heads[k][0]:end(k)]))
