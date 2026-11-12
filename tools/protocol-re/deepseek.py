#!/usr/bin/env python3
"""Hand a narrow batch task to DeepSeek (via `omp`), text in / text out, and check the draft by script.

usage: deepseek.py annotate --bin BIN --ops 0x7404,0x7406,...  --out FILE.json
       deepseek.py helpers  --bin BIN --funcs FUN_..,FUN_..     --out FILE.tsv
       deepseek.py bugscan  --bin BIN --funcs FUN_..,FUN_..     --out FILE.tsv
       options: --chunk CHARS (input per call, default 60000)  --max-cost USD (per call, default 0.5)  --jobs N (4)

The script builds the input itself (clean.py code, PDB structs, layouts.json send sites), so DeepSeek gets no repo
access. Output is a DRAFT for the calling session (Opus) to verify; never copy it into item files unchecked:
  annotate  -> JSON in the annotations schema; lint_item.py's name/layout checks run on it and print their findings
  helpers   -> TSV  FUN_x <tab> name or - <tab> one-line behaviour [<tab> unconfirmed name proposal]; a name is kept
               only when it occurs in the binary's strings or the input code, otherwise it moves to the 4th column
  bugscan   -> TSV  FUN_x <tab> quoted code line <tab> suspected bug; rows whose quote is not in the code are dropped
Model fallback is switched off: if DeepSeek fails, the call fails (no silent switch to a pricier model).
"""
import argparse, json, os, re, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor

R = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
T, E = f"{R}/tools/protocol-re", f"{R}/re-data/exports"
MODEL = "deepseek/deepseek-flash"
sys.path.insert(0, T)
import lint_item  # noqa: E402

RULES = """You are drafting reverse-engineering notes for a Fiesta 2016 server reconstruction. Everything you need is in
the attached file; do not use tools. Rules:
- Use only names that appear in the input (strings, PDB structs, opcode names). Never invent a name; write - instead.
- Ghidra often types bool-returning helpers as `void`. Never conclude anything from a `void` return type or from
  "the caller tests EAX".
- Be literal: describe what the code does, offsets as written. If unsure, say "unsure" in the note.
- Output ONLY the requested format, no prose, no code fences."""

TASKS = {
    "annotate": """For every opcode section in the file, give its packet layout as one JSON object:
{"0x7404": {"dir": "WM→client", "name": "<name from the section>", "basis": "<bin> FUN_x (the send/handler function)",
 "fields": [[offset, "type", "fieldName", "note"], ...], "notes": ""}, ...}
Offsets are payload offsets (after the 2-byte opcode). Prefer the PDB struct's field names and types (Name4, Name5,
nested struct names) when the code agrees; if the code disagrees with the PDB, follow the code and say so in the note.
Types: u8 u16 u32 u64 i32, char[N], Name4/Name5, or a PDB struct name; arrays as Type[n].""",
    "helpers": """For every function in the file write one line: FUN_xxxxxxxx<TAB>name<TAB>behaviour
name = a name taken from a log string or the code's known names in the file, else -.
behaviour = what it does in at most 25 words (inputs, effect, return value if visible).""",
    "bugscan": """List behaviour that looks unintended (unchecked lengths, uninitialised bytes sent, wrong opcode or code,
dead checks, missing replies, NULL dereference). One line each: FUN_xxxxxxxx<TAB>exact code line copied verbatim<TAB>suspected bug
Copy the code line exactly as in the file (it is checked). No line for a function without a suspect. These are
candidates only; the caller verifies them.""",
}


def clean(binname, funcs):
    names = f"{T}/names/{binname}"
    return subprocess.run([sys.executable, "-I", f"{T}/clean.py", f"{E}/{binname}", names] + [f.replace("FUN_", "") for f in funcs],
                          capture_output=True, text=True).stdout


def pieces_for_ops(binname, ops):
    opj = {o["op"]: o for o in json.load(open(f"{R}/docs/protocol/opcodes.json"))}
    lay = json.load(open(f"{E}/{binname}/layouts.json"))
    out = []
    for op in ops:
        op = op.lower()
        name = (opj.get(op) or {}).get("name") or "-"
        sites = [s for d in ("s2c", "c2s") for s in lay.get(d, {}).get(op, [])]
        funcs = sorted({s.get("func") or s.get("function") for s in sites} - {None})
        pdb = subprocess.run([sys.executable, "-I", f"{T}/pdb.py", lint_item.PDB, "types", f"^PROTO_{re.escape(name)}$"],
                             capture_output=True, text=True).stdout if name != "-" else ""
        txt = (f"=== OPCODE {op} name {name} (received_by: {(opj.get(op) or {}).get('received_by')})\n"
               f"--- PDB 2017 struct (2017 client; 2016 may differ; server-internal packets add a 6-byte header first)\n{pdb or '(none)'}\n"
               f"--- generated send/handler sites (sizes, memcpy offsets)\n{json.dumps(sites)[:3000]}\n"
               f"--- code of those functions\n{clean(binname, funcs) if funcs else '(no site found)'}\n")
        out.append(txt)
    return out


def chunks(pieces, limit):
    cur = ""
    for p in pieces:
        if cur and len(cur) + len(p) > limit:
            yield cur
            cur = ""
        cur += p
    if cur:
        yield cur


def call(task, text, max_cost):
    with tempfile.TemporaryDirectory() as d:
        inp, cfg = f"{d}/input.txt", f"{d}/overlay.yml"
        open(inp, "w").write(text)
        open(cfg, "w").write("retry:\n  modelFallback: false\n  maxRetries: 2\n")
        p = subprocess.run(["omp", "-p", "--model", MODEL, "--config", cfg, "--no-session", "--no-title", "--tools", "read",
                            "--no-context-files", "--no-skills", "--no-rules", "--no-extensions", "--approval-mode", "always-ask",
                            "--max-cost", str(max_cost), "--max-time", "900", "--mode", "json",
                            RULES + "\n\nTask:\n" + TASKS[task], f"@{inp}"], capture_output=True, text=True, cwd=d)
    text, cost, bad = "", 0.0, []
    for line in p.stdout.splitlines():
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        m = ev.get("message") or {}
        if ev.get("type") == "message_end" and m.get("role") == "assistant":
            cost += ((m.get("usage") or {}).get("cost") or {}).get("total") or 0
            if m.get("provider") != "deepseek":
                bad.append(f"answered by {m.get('provider')}/{m.get('model')}")
            if m.get("stopReason") == "error":
                bad.append(m.get("errorMessage", "")[:200])
            text = "".join(c.get("text", "") for c in m.get("content", []) if c.get("type") == "text") or text
    if bad or not text:
        raise RuntimeError(f"omp call failed: {bad or p.stderr[-300:]}")
    return re.sub(r"^```\w*\n|\n```\s*$", "", text.strip()), cost


def main():
    ap = argparse.ArgumentParser(usage=__doc__)
    ap.add_argument("task", choices=TASKS)
    ap.add_argument("--bin", required=True)
    ap.add_argument("--funcs", default="")
    ap.add_argument("--ops", default="")
    ap.add_argument("--out", required=True)
    ap.add_argument("--chunk", type=int, default=60000)
    ap.add_argument("--max-cost", type=float, default=0.5)
    ap.add_argument("--jobs", type=int, default=4)
    a = ap.parse_args()
    funcs = [f if f.startswith("FUN_") else f"FUN_{f}" for f in a.funcs.split(",") if f]
    if a.task == "annotate":
        pieces = pieces_for_ops(a.bin, [o for o in a.ops.split(",") if o])
    else:
        code = clean(a.bin, funcs)
        pieces = ["// ===== " + p for p in code.split("// ===== ") if p.strip()]
    parts = list(chunks(pieces, a.chunk))
    with ThreadPoolExecutor(a.jobs) as ex:
        results = list(ex.map(lambda t: call(a.task, t, a.max_cost), parts))
    cost = sum(c for _, c in results)

    if a.task == "annotate":
        packets = {}
        for txt, _ in results:
            packets.update(json.loads(txt[txt.find("{"):txt.rfind("}") + 1]))
        json.dump({"_about": f"DRAFT by {MODEL}, unverified", "packets": {a.bin: packets}}, open(a.out, "w"), indent=1, ensure_ascii=False)
        print(f"{len(packets)} packets drafted, {len(parts)} calls, ${cost:.4f} -> {a.out}\nlint of the draft:")
        lint_item.check_annotations(a.out)
        print(f"draft lint: {lint_item.problems['ERROR']} errors, {lint_item.problems['WARN']} warnings")
        return
    code = "\n".join(pieces)
    strings = open(f"{E}/{a.bin}/strings.tsv", errors="replace").read()
    rows, dropped = [], 0
    for txt, _ in results:
        for line in txt.splitlines():
            cols = line.split("\t")
            if len(cols) < 3 or not re.fullmatch(r"FUN_[0-9a-f]{8}", cols[0]) or (funcs and cols[0] not in funcs):
                dropped += 1
                continue
            if a.task == "bugscan" and re.sub(r"\s+", " ", cols[1].strip()) not in re.sub(r"\s+", " ", code):
                dropped += 1  # quote not found verbatim: likely made up
                continue
            if a.task == "helpers" and cols[1] != "-" and not re.search(rf"\b{re.escape(cols[1])}\b", strings + code):
                cols = [cols[0], "-", cols[2], f"unconfirmed name proposal: {cols[1]}"]  # not in any string or known name
            rows.append("\t".join(cols[:4] if a.task == "helpers" else cols[:3]))
    open(a.out, "w").write("\n".join(rows) + "\n")
    print(f"{len(rows)} rows, {dropped} malformed or unverifiable rows dropped, {len(parts)} calls, ${cost:.4f} -> {a.out}")


if __name__ == "__main__":
    main()
