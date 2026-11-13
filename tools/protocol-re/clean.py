"""Print decompiled functions with decompiler noise removed and known symbols renamed.

usage: python3 -I clean.py <export_dir/server> <names.json | names/<server>/ dir | -> <hexaddr>...
names.json: {"FUN_00408e20": "SendRaw", "DAT_0043f27c": "g_ClientSessions", ...}
"""
import json, re, sys

d, namesf, addrs = sys.argv[1], sys.argv[2], sys.argv[3:]
src = open(f"{d}/decomp.c", encoding="utf-8", errors="replace").read()
import glob, os
def load_names(p):
    """a names file, or a directory of names files (one per work item, merged in sorted order)"""
    if p == "-" or not os.path.exists(p): return {}
    files = sorted(glob.glob(os.path.join(p, "*.json"))) if os.path.isdir(p) else [p]
    out = {}
    for f in files: out.update(json.load(open(f)))
    return out
names = load_names(namesf)
funcs = {m.group(1): m.group(2) for m in re.finditer(r"^//==== FUNC ([0-9a-f]{8}) \S+\n(.*?)(?=^//==== FUNC |\Z)", src, re.S | re.M)}

NOISE = re.compile(r"""^\s*(?:
    (?:undefined\w*|int|uint|char|byte|ushort|short|bool|float|double|longlong|ulonglong|code|tm|__time32_t|
       LPVOID|DWORD|BOOL|HANDLE|LPCRITICAL_SECTION|void|uchar|wchar_t|exception|NETPACKET|\w+_t)\s+\**\w+(?:\s*\[\w+\])*;   # declarations
  | \w+\s*=\s*DAT_\w+\s*\^\s*\(.*\);                                     # stack cookie
  | __security_check_cookie\(.*\);
  | ExceptionList\s*=.*; | \w+\s*=\s*ExceptionList; | puStack_\w+\s*=.*; | local_8\s*=\s*0xffffffff;
  | local_8(?:\._0_1_)?\s*=\s*\d+;
  | \w+\[(?:0x)?[0-9a-f]+\]\s*=\s*'\\0';                                   # unrolled zeroing
  | uStack_\w+\s*=\s*0x[0-9a-f]+;
  | /\*\s*WARNING.*\*/
  | \s*
)$""", re.X)

def rename(t):  # one pass: every names key is a plain identifier (FUN_/DAT_/...)
    return re.sub(r"\b\w+\b", lambda m: names.get(m.group(0), m.group(0)), t)

for a in addrs:
    a = f"{int(a, 16):08x}"
    body = funcs.get(a)
    key = f"FUN_{a}"
    print(f"// ===== {names.get(key, key)} ({key})")
    if body is None:
        print("// not found"); continue
    out = [l for l in body.split("\n") if not NOISE.match(l)]
    print(rename("\n".join(out)))
