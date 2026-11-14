# Zone (and all servers): the CSL config-script format and its reader (Z19)

Source: `Files/Server/2016/w00_Zone00/5ZoneServer2.exe` (the four zone exes are identical), read in
`re-data/exports/zone-pdb` (names, types and layouts from the NA2016 `Zone.pdb`, same build *(pdb2016)*):
`python3 -I tools/protocol-re/clean.py re-data/exports/zone-pdb - 00652500 00651050 …`. The constant tables were read
from the exe (`pCslCmd` 0x873864, `pCslParameter` 0x873818, `pCslParameterSize` 0x8737c8, `pCslRemarks` 0x87388c,
default strings 0x70cae0 … 0x70caec), `MakeData`, `MakeFormat`, `Read`, `ClearFormats`, `ClearDatas`, `Close` also in
the disassembly (`objdump -d --start-address=…`), because the decompiler drops loops there.

**Relation to S02.** S02 (`docs/pseudocode/shared/S02-library.md` §2, done) reconstructed `CToken` / `CCsl` from the WM
build in full pseudocode and showed that the Login and Zone copies are identical at instruction level (S02 §2.7). This
document does not repeat that pseudocode. It adds: the zone citation of every function (§1), the file format as a
specification a rebuild can implement (§2), the zone's use of it (§3), a short spec-level reader tested on every 2016
config file against S02's byte-faithful emulator `tools/protocol-re/csl.py` (§4), and the Account / AccountLog /
Character / GameLog copies (§5). Where this document says "S02 §x" the pseudocode is there.

Evidence markers: plain = read in the 2016 code; *(inferred)* = deduced. No packets are involved (no annotations).

## 1. The library in the zone

Four layers, all statically linked into every server:

```
CServerInfo (0x4f8)  = { CCsl m_Csl }                    row lookups for *ServerInfo.txt (Z10 §1.1, §6.5)
CCsl : CToken (0x4f8)  formats, rows, includes, remarks  the script reader ("CSL")          S02 §2.3
CToken (0x294)         buffer, strtok-style tokenizer, quoted strings                       S02 §2.2
CGdp (0x15c)           file API wrapper; a packed-file container mode the servers never open S02 §3
```

Struct layouts (`CCsl`, `CToken`, `CCsl::CSL_FORMAT_LIST` 0x4c, `CSL_DATA_LIST` 0x10, `CSL_PARAMETER_LIST` 8,
`CSL_RESULT_MSG_LIST` 8 + text, the enums `CSL_CMD`, `CSL_PARAMETER`, `CSL_REMARK`, `CLS_CHUNK_ID`) are in S02 §2.1; the
zone PDB gives the same members and offsets *(pdb2016)*.

### 1.1 Zone functions

Every function of the zone copy with its role. The pseudocode is S02's (WM addresses there; the code is the same).

| Function | Zone | Role | S02 |
|---|---|---|---|
| `CCsl::ReadScript(file, hWnd, msgId, memText)` | FUN_00652500 | open file (or text in memory), main token loop: remark → command → row, else `"%s - UNKNOWNED."` + data error; `ReadScriptDone`; return 1 iff no errors | §2.3.1 |
| `CCsl::ProcRemark(tok)` | FUN_00650aa0 | `;` prefix, `/*` … `*/`, `#SEPRATOR`, `#REMARKLINE`, `#REMARKSTART`, `#REMARKEND` | §2.3.2 |
| `CCsl::ProcCmd(tok)` | FUN_00652000 | the ten `#` commands (§2.3) | §2.3.3 |
| `CCsl::MakeFormat()` / `AddFormat(f)` | FUN_00650cb0 / FUN_00650f60 | `#DEFINE` name, column types, `#ENDDEFINE`; append to the format list | §2.3.4 |
| `CCsl::ProcData(tok)` / `MakeData(id, fmt)` / `GetDataToken()` | FUN_006512a0 / FUN_00651050 / FUN_00650fa0 | row: first format whose name matches; one value per column; next non-remark token (EOF → `m_pDummyNull` "") | §2.3.5 |
| `CCsl::Parameter_filename(out)` | FUN_00651020 | next quoted string → `out` (unbounded copy into a 260-byte local) | §2.3.3 |
| `CCsl::IncludeFile()` / `CCsl::CCsl(parent)` / `ReadScriptDone()` | FUN_00651ea0 / FUN_00651cb0 / FUN_00651330 | `#INCLUDE`: child reader sharing the lists, cwd = including file's directory; hand the lists back; top level builds the pointer tables | §2.3.6, §2.3.8 |
| `CCsl::Read(file)` / `WriteFormat(file, h)` / `WriteData(file, h)` | FUN_00651540 / FUN_00651780 / FUN_006518a0 | binary chunk files for `#READ` / `#WRITE*` | §2.3.7 |
| `CCsl::MakeFormatTable()` / `MakeDataTable()` | FUN_00650780 / FUN_00650800 | pointer arrays over the two lists (built at the end of the top-level read) | §2.3.6 |
| `CCsl::GetFormat(i)` / `GetNumDatas()` / `GetDataInfo(i)` / `GetData(row, col)` | FUN_00650900 / FUN_00650950 / FUN_00650960 / FUN_006509b0 | accessors: format i; row count; row i `{dwID, dwSize, pData}`; pointer to column `col` = `pData + Σ size(col' < col)` (null if out of range) | §2.3.5; users Z10 §6.5 |
| `CCsl::AddResultMsg(text)` | FUN_00650880 | append a diagnostic line to `m_pResultMsgs` (the zone has no `ViewResultMsg` and never reads the list) | §2.6 |
| `CCsl::CCsl()` / `~CCsl()` / `Clear()` / `VarClear()` / `Close()` / `ClearFormats()` / `ClearDatas()` | FUN_00651c50 / FUN_00651bf0 / FUN_00651b10 / FUN_00650710 / FUN_00651a90 / FUN_006519b0 / FUN_00651a20 | construction (defaults of §2.2), teardown (a top-level `Close` frees messages, formats, rows, the remark array; an include child frees nothing) | §2.3.8 |
| `CToken::CToken` / `~CToken` / `Open` / `OpenFromMemory` / `Close` | FUN_0063aea0 / FUN_0063b310 / FUN_0063b3a0 / FUN_0063b4b0 / FUN_0063af10 | whole file into a `malloc(size + 1)` buffer, NUL-terminated; the handle stays open until `Close` | §2.2 |
| `CToken::SetSeprator` / `my_tcstok` / `GetToken` / `GoNextLine` | FUN_0063af70 / FUN_0063af90 / FUN_0063b010 / FUN_0063b150 | MBCS `strtok` over the buffer (`_mbspbrk`); line-remark skip | §2.2 |
| `CToken::GoStartString` / `GetTokenString(&len)` | FUN_0063b1a0 / FUN_0063b570 | quoted strings (§2.1) | §2.2 |
| `CToken::GoBegin` / `SaveTokenPositon` / `RestoreTokenPositon` | FUN_0063b090 / FUN_0063b1f0 / FUN_0063b200 | re-read the file (tokenising wrote NULs) and resume at a saved token (used after an include) | §2.2 |
| `CToken::IsTokenID(tok, list, n)` / `GetTokenID` | FUN_0063b270 / FUN_0063b2b0 | case-insensitive (`_mbsicmp`) keyword lookup → index or 0xFFFFFFFF; `GetTokenID` is zone-only (quest scripts, Z15) | §2.2, §2.5 |
| `CGdp::CreateFileA` / `ReadFile` / `WriteFile` / `GetFileSize` / `SetFilePointer` / `CloseHandle` | FUN_0063c3d0 / FUN_0063bab0 / FUN_0063bb40 / FUN_0063bc30 / FUN_0063bc70 / FUN_0063ba70 | with `m_bIsGDPOpen == 0` (always: nothing in the zone sets it) each one is the Win32 call of the same name | §3.2 |
| `CGdp::CGdp` / `~CGdp` / `Clear` / `GdpClose` | FUN_0063bd90 / FUN_0063c380 / FUN_0063b660 / FUN_0063c1e0 | zero the container state; `GdpClose` on a never-opened container only `Clear`s | §3.2 |
| `CServerInfo::CServerInfo` / `ReadServerInfo(file)` | FUN_0064d0e0 / FUN_0064d0f0 | `CCsl()`; `Clear()` then `ReadScript(file, 0, 0x401, 0)` (§3) | §2.5 |

`m_bIsGDPOpen` is only ever cleared in the zone (`CGdp::Clear`, `GdpClose`, `~CGdp`); no function sets it, so the
container branches of the `CGdp` wrappers are dead and every config file is a plain file on disk (same in WM / Login,
S02 §3.2).

## 2. File format specification

What a reader must do to load the original files exactly as the 2016 servers do. The bug paths are marked with the S02
bug IDs (they matter only for files the 2016 set does not contain; §4 lists what the shipped files use).

### 2.1 Buffer and tokens

- The whole file is read into memory and treated as a C string: an embedded NUL byte ends the script *(inferred from
  `my_tcstok` / `_mbspbrk` stopping at NUL)*. No BOM handling (a UTF-8 BOM becomes part of the first token, which is
  then unknown). Keyword compares are byte-wise ASCII-case-insensitive (`_mbsicmp`); text is passed through unchanged
  (MBCS code page of the machine; the shipped files are ASCII).
- **Delimiters**: the set `", \t\r\n"` (comma, space, tab, CR, LF; `#SEPRATOR` can replace it). A **token** is a maximal
  run of non-delimiter bytes; any number of delimiters separate tokens, so the comma is just whitespace and empty
  values (`1,,2`) do not exist. A quote is not a delimiter: `abc"x"` is one token.
- **Quoted string** (columns `<STRING>`, `<FILENAME>`, `<SHORTKEY>` and the argument of `#INCLUDE`, `#READ`,
  `#WRITE*`): the reader skips from the end of the previous token to the next `"` byte, wherever it is (other tokens,
  remarks, line ends are skipped without notice), and takes every byte up to the next `"`. No escapes; `""` is the
  empty string; a string may contain delimiters, `;`, `{}` and line breaks. A missing quote makes the original read
  past the buffer (S02-B13), as does `""` directly followed by another string column (S02-B13).
- **End of file**: a file whose last token is followed by delimiters produces one final empty token, which is an
  unknown item (error, S02-B14). So every top-level file and include must end with `#END` (all shipped files do, with
  no line break after it) or with a token and no trailing whitespace.

### 2.2 Remarks

Checked on every token, before commands and rows, also inside `#DEFINE` and between row values (not inside quoted
strings, which are found by the quote scan above):

| Token | Effect |
|---|---|
| starts with `;` (the line-remark marker, case-sensitive prefix) | the rest of the line is ignored. Implementation: if the byte after the token's delimiter is not LF, skip to the next LF. With CRLF files this is exact; with LF-only files a remark token that ends at the line end also eats the next line (S02-B16) |
| exactly `/*` | start a block remark: every following token is ignored up to a token that is exactly `*/` (no nesting; markers must be separate tokens: `/*x` is not a block start, `x*/` not an end) |
| exactly `*/` outside a block | ignored |
| `#SEPRATOR t` / `#REMARKLINE t` / `#REMARKSTART t` / `#REMARKEND t` | the next token becomes the delimiter set / line marker / block start / block end (end of file: back to `", \t\r\n"`, `;`, `/*`, `*/`). Unbounded copy into 64-byte fields (S02-B19). Inside an include they change the include only; an include's `#REMARKLINE` / `#REMARKSTART` / `#REMARKEND` affect only the prefix test, not the whole-token tests (S02 §2.3.6) |

The defaults are restored by every `CServerInfo::ReadServerInfo` (`CCsl::Clear` FUN_00651b10).

### 2.3 Commands

Case-insensitive whole tokens at item level (`CSL_CMD` order = `pCslCmd`):

| Command | Argument | Effect |
|---|---|---|
| `#END` | – | stop reading this file (an include: only the include) |
| `#DEFINE` | `NAME col… #ENDDEFINE` | define a format (§2.4) |
| `#INCLUDE` | quoted path | read another script into the same lists (§2.6) |
| `#CLEAR` | – | drop all formats and rows |
| `#CLEARFORMAT` | – | drop all formats; rows keep their format index, which then points into the new list |
| `#CLEARDATA` | – | drop all rows |
| `#READ` | quoted path | append formats and rows from a binary chunk file (§2.7); failure = data error |
| `#WRITE` / `#WRITEFORMAT` / `#WRITEDATA` | quoted path | write formats + rows / formats / rows as a binary chunk file (create always); failure = data error |

`#ENDDEFINE` outside a `#DEFINE` is an unknown item.

### 2.4 `#DEFINE`: formats and column types

```
#DEFINE NAME
    <TYPE> …           one column per type token, in order; any delimiters / line breaks between them
#ENDDEFINE
```

- `NAME` is the first non-remark token after `#DEFINE` (kept to 64 bytes); it may be any token. Names are compared
  case-insensitively. Duplicate names are accepted; rows always bind to the **first** format with the name.
- The format's index (`dwID` of its rows) is its position in the format list: definitions in file order, an include's
  definitions at the point of the `#INCLUDE`. `CServerInfo` depends on these indices (§3).
- A token naming an earlier format inserts that format's columns, but only format 0 is found correctly (S02-B12).
- Any other word: error `"%s - FORMAT DEFINING, UNKNOWNED PARAMATER."` (format error), ignored, the definition goes on.
- End of file before `#ENDDEFINE`: error `"FORMAT DEFINNING, EOF Come."`, the format is dropped.
- A format may have 0 columns.

Column types (`[TYPE]` "optional" forms behave exactly like `<TYPE>`: the value is not optional, S02-B21):

| Type | Value in the file | Stored as | Bytes |
|---|---|---|---|
| `<ID>`, `<INTEGER>` | token, `atoi` (leading sign and digits; anything else → 0, no error) | int32 | 4 |
| `<HEX>` | token, `sscanf("%x")` (no digits → 0, the zeroed slot) | uint32 | 4 |
| `<FLOAT>` | token, `atof` | float32 | 4 |
| `<STRING>` | quoted string | char[512], NUL-terminated (longer: overflow, S02-B19) | 512 |
| `<FILENAME>` | quoted string | char[260] (same) | 260 |
| `<SHORTKEY>` | quoted string | int32 = first byte, sign-extended (`""` → 0) | 4 |
| `<ARRAYSRT>` | none consumed | nothing written, but 4 bytes counted (S02-B11) | 4 |
| `<ARRAYEND>` | none consumed | – | 0 |

### 2.5 Rows

```
NAME value value …     one value per column of the format NAME; delimiters, line breaks and remarks may sit between
```

- A token at item level that is neither remark nor command is looked up as a format name (case-insensitive, first
  match). Unknown → `"%s - UNKNOWNED."` (data error), skipped, reading goes on with the next token.
- The row consumes exactly as many values as the format has columns, regardless of lines. **Too few values** on a line
  silently take the next line's tokens (the next row name becomes a value: `atoi("SERVER_INFO")` = 0), and the rest
  of that line then produces `UNKNOWNED` errors; **too many** values: every extra token is an `UNKNOWNED` error.
- End of file inside a row: every missing numeric value is `""` → 0 with `"DATA DEFINNING, EOF Come"` (counted as a
  format error, S02-B20); the row is still added. A missing string value at the end of the file is the unbounded quote
  scan of §2.1 (S02-B13). In an include the `""` fallback pointer is not set (S02-B15).
- Storage (`CSL_DATA_LIST`): `dwID` = format index, `dwSize` = Σ column bytes, `pData` = zeroed buffer with the values
  packed in column order, no padding. `GetData(row, col)` returns `pData + Σ bytes of the columns before col`.
  Example `SERVER_INFO` (STRING, 4 × INTEGER, STRING, 3 × INTEGER): name +0, ints +0x200…+0x20C, IP +0x210,
  ints +0x410…+0x418, `dwSize` 1052.

### 2.6 `#INCLUDE`

- The path is resolved **relative to the directory of the including file** (the reader takes `_fullpath` of the
  including file's name, sets the process's current directory to its drive + directory for the include, and restores
  it afterwards). Nested includes therefore chain naturally. Absolute paths work too.
- The include continues the same format and row lists (indices continue), starts with the includer's current
  delimiter and remark settings (changes inside do not come back), and its errors add to the includer's.
- Cannot open → `"INCLUDE OPEN ERROR(Code = %d) - %s"` (format error); reading of the includer goes on.
- A path containing a delimiter (space, comma) leaves its tail as a token after the include → `UNKNOWNED` (S02-B18).

### 2.7 Binary chunk files (`#READ` / `#WRITE*`)

A sequence of chunks `{u32 id, u32 size, size bytes}` (little-endian), read until the summed `8 + size` reaches the file
size: id 0x11111111 = format `{char Format[64]; i32 NumParameter; i32 type[NumParameter]}` (size `0x44 + 4·n`), id
0x22222222 = row `{u32 dwID, u32 dwSize, dwSize bytes}` (size `dwSize + 8`; `dwID` taken as is). An unknown id or a
short read fails the `#READ`; an empty file succeeds. `#WRITE` writes all formats, then all rows. `CCsl::Read`
FUN_00651540, `ProcCmd` cases 6–9 FUN_00652000, S02 §2.3.7 (handle leak S02-B17). No 2016 script uses them.

### 2.8 Result and diagnostics

- `ReadScript` returns 1 iff the format-error and data-error counters (file + all includes) are both 0. Every error
  above counts; numeric garbage (→ 0), duplicate format names, and a short row whose shift happens to consume the
  rest of the file exactly do not. On failure the formats and rows read so far stay loaded; the zone's callers do not use them
  (§3) and the next `ReadServerInfo` clears them.
- Diagnostics are appended as text lines to `m_pResultMsgs` (`"FILE PROCESSING - %s"`, `"Include - %s"`, the error texts
  above, `"FILE OPEN ERROR(Code = %d) - %s"` with `GetLastError`, `"%s - READ OK|READ ERROR|WRITE …"`, the per-file
  `"TOTAL|Include Format %d Defined, %d Errors"` / `"… Data …"` totals; complete list S02 §2.6). The zone never prints
  them: it has no `ViewResultMsg`, and nothing else reads the list (WM / Login print it, S02 §2.5).
- `ReadServerInfo` passes `hWnd = 0`, `msgId = 0x401` (`WM_USER + 1`). Both are stored in `m_hWnd` / `m_UseMsgID` and
  passed to includes, and never used: no window message is ever posted *(the two fields suggest the reader came from a
  Windows editor tool, inferred)*.

### 2.9 Limits (none checked)

Format name 64 bytes; type list unbounded (heap); string column 511 + NUL, filename column 259 + NUL; marker and
delimiter strings 63 + NUL; include / `#READ` path 259 + NUL (`m_ScriptFN` 260); rows and formats unbounded (linked
lists). Longer text overflows (S02-B19).

## 3. Zone: which file, read when, used how

```pseudo
ZoneServer::zs_start(server, cmdline):                                              @ FUN_005ab520   (Z10 §1.1)
    …
    CServerInfo::ReadServerInfo(&server.zs_serverinfo.serverinfo, "ZoneServerInfo/ZoneServerInfo.txt")    @ FUN_0064d0f0
    else assert "ZoneServer::zs_start : Fail to read ZoneServerInfo.txt"
         ReadServerInfo(…, "../9Data/ServerInfo/ZoneServerInfo.txt")
         else assert (same text) + ShineExit("ZoneServer::zs_start")
    GetMyServerInfo, GetServerInfo, GetWorldName …                                  (Z10 §1.1)

ZoneServer::zs_ServiceThreadFunction(server):                                       @ FUN_005a9d90   (Z10 §1)
    the same two-path read again into the same CServerInfo (server + 0x40 = zs_serverinfo.serverinfo *(pdb2016)*),
        same messages and exit; ReadServerInfo's Clear() discards the first read's lists
    GetMyServerInfo(→ server + 0x538 = zs_serverinfo.myserver) else assert "ZoneServer::zs_start : Fail Serverinfo" + ShineExit
```

- Paths are relative to the process's current directory, i.e. the zone's install directory
  (`w00_Zone00` …). The fallback `../9Data/ServerInfo/ZoneServerInfo.txt` does not exist in the 2016 set.
- `ZoneServerInfo.txt` defines `MY_SERVER` (format 0) and includes `"../../9Data/ServerInfo/ServerInfo.txt"`, relative to
  `w00_Zone0n/ZoneServerInfo/` (§2.6), i.e. `Files/Server/2016/9Data/ServerInfo/ServerInfo.txt`, which adds
  `NATION_NAME` 1, `WORLD_NAME` 2, `SERVER_INFO` 3, `ODBC_INFO` 4. The `CServerInfo` lookups test these indices
  (`GetMyServerInfo` dwID 0, `GetNationName` 1, `GetWorldName` 2, `GetServerInfo` / `GetServerIndex` 3; Z10 §1.1 /
  §6.5, `GetNumOfData` FUN_0064d120): a file that defined the formats in another order would make the zone see no
  rows *(inferred from those checks)*.
- `CServerInfo` is the zone's only `CCsl` user (the only callers of `CCsl::CCsl()` and `ReadScript` are
  `CServerInfo::CServerInfo` and `ReadServerInfo`); the quest scripts use the bare `CToken` (S02 §2.5, Z15).
- What the rows mean (server IDs, ports, `nServerIDFrom`, ODBC strings): Z10 knowledge "Server config files", W05 §5.2,
  `docs/knowledge/X03.md`.

## 4. Reference reader and test on every 2016 config file

A spec-level reader of §2 (not byte-faithful: S02's `tools/protocol-re/csl.py` emulates the buffer and the bug paths
exactly). It reproduces the two bug paths that change the result of real files (LF remarks S02-B16, missing `#END`
S02-B14) so that it loads what the 2016 servers load.

```python
"""Spec-level reader for the 2016 CSL config scripts (Z19 §2).  python3 -I cslread.py <script> [-v]"""
import os, struct, sys

TYPES = {'ID': 'i', 'INTEGER': 'i', 'HEX': 'x', 'FLOAT': 'f', 'STRING': ('s', 512), 'FILENAME': ('s', 260),
         'SHORTKEY': 'k', 'ARRAYSRT': 'a', 'ARRAYEND': 'e'}
CMDS = {'#END', '#DEFINE', '#INCLUDE', '#CLEAR', '#CLEARFORMAT', '#CLEARDATA', '#READ', '#WRITE', '#WRITEFORMAT', '#WRITEDATA'}


def atoi(t):
    t = t.lstrip(' \t'); n = 0; i = 1 if t[:1] in '+-' else 0
    while i < len(t) and t[i].isdigit(): n = n * 10 + int(t[i]); i += 1
    return -n if t[:1] == '-' else n


class Csl:
    def __init__(s):
        s.formats, s.rows, s.errors = [], [], []      # formats: [name, [type…]];  rows: (dwID, [values…])

    def read(s, path, include=False):
        try: buf = open(path, 'rb').read().decode('cp949')
        except OSError as e: s.errors.append(('INCLUDE' if include else 'FILE') + f' OPEN ERROR {path}: {e}'); return
        s.b, s.p, s.base = buf, 0, os.path.dirname(os.path.abspath(path))
        if not include: s.seps, s.rline, s.rstart, s.rend, s.inblock = ', \t\r\n', ';', '/*', '*/', False
        while True:
            t = s.word()
            if t is None or t.upper() == '#END': break    # file ending in a delimiter yields '' (S02-B14) → UNKNOWNED
            if s.remark(t): continue
            u = t.upper()
            if u == '#DEFINE': s.define()
            elif u == '#INCLUDE':
                name = s.string(); st = (s.b, s.p, s.base, s.seps, s.rline, s.rstart, s.rend, s.inblock)
                s.read(os.path.join(st[2], name), True)
                s.b, s.p, s.base, s.seps, s.rline, s.rstart, s.rend, s.inblock = st
                if any(c in s.seps for c in name): s.errors.append(f'{name}: include name with a delimiter (S02-B18)')
            elif u in ('#CLEAR', '#CLEARFORMAT'): s.formats = []; s.rows = [] if u == '#CLEAR' else s.rows
            elif u == '#CLEARDATA': s.rows = []
            elif u in CMDS: s.string(); s.errors.append(f'{u}: binary chunk files not supported here (§2.7)')
            else:
                fid = next((i for i, f in enumerate(s.formats) if f[0].upper() == u), None)
                if fid is None: s.errors.append(f'{t} - UNKNOWNED.')
                else: s.rows.append((fid, [s.value(ty) for ty in s.formats[fid][1]]))

    def word(s):                                         # next delimiter-separated token; '' at a trailing delimiter
        if s.p > len(s.b): return None
        while s.p < len(s.b) and s.b[s.p] in s.seps: s.p += 1
        e = s.p
        while e < len(s.b) and s.b[e] not in s.seps: e += 1
        t, s.p = s.b[s.p:e], e + 1
        return t

    def remark(s, t):
        if s.inblock: s.inblock = t.upper() != s.rend.upper(); return True
        u = t.upper()
        if u == s.rstart.upper(): s.inblock = True; return True
        if u == s.rend.upper(): return True
        if u in ('#SEPRATOR', '#REMARKLINE', '#REMARKSTART', '#REMARKEND'):
            v = s.word() or {'#SEPRATOR': ', \t\r\n', '#REMARKLINE': ';', '#REMARKSTART': '/*', '#REMARKEND': '*/'}[u]
            if u == '#SEPRATOR': s.seps = v
            elif u == '#REMARKLINE': s.rline = v
            elif u == '#REMARKSTART': s.rstart = v
            else: s.rend = v
            return True
        if t.startswith(s.rline):                       # rest of the line (CRLF files; LF: S02-B16)
            if s.b[s.p:s.p + 1] != '\n': e = s.b.find('\n', s.p); s.p = len(s.b) + 1 if e < 0 else e + 1
            return True
        return False

    def data_word(s):
        while True:
            t = s.word()
            if t is None: s.errors.append('DATA DEFINNING, EOF Come'); return ''
            if not s.remark(t): return t

    def string(s):                                       # next "…" anywhere after the current token; "" = empty
        a = s.b.find('"', s.p)
        if a < 0: s.errors.append('missing quote (S02-B13: the original reads past the buffer)'); s.p = len(s.b) + 1; return ''
        e = s.b.find('"', a + 1); e = len(s.b) if e < 0 else e
        s.p = e + 1; return s.b[a + 1:e]

    def value(s, ty):
        if ty == 'i': return atoi(s.data_word())
        if ty == 'x': t = s.data_word(); return int(t, 16) if t and all(c in '0123456789abcdefABCDEF' for c in t) else 0
        if ty == 'f':
            t = s.data_word()
            try: return struct.unpack('<f', struct.pack('<f', float(t)))[0]
            except ValueError: return 0.0
        if ty == 'k': v = s.string(); return ord(v[0]) if v else 0
        if ty in ('a', 'e'): return None                 # array markers take no value (S02-B11)
        v = s.string()
        if len(v.encode('cp949')) >= ty[1]: s.errors.append(f'string over {ty[1] - 1} bytes (original overflows, S02-B19)')
        return v

    def define(s):
        name, types = None, []
        while True:
            t = s.word()
            if t is None: s.errors.append('FORMAT DEFINNING, EOF Come.'); return
            if s.remark(t): continue
            if name is None: name = t[:64]; continue
            u = t.upper()
            if u == '#ENDDEFINE': s.formats.append([name, types]); return
            if len(u) > 2 and (u[0], u[-1]) in (('<', '>'), ('[', ']')) and u[1:-1] in TYPES: types.append(TYPES[u[1:-1]])
            elif s.formats and u == s.formats[0][0].upper(): types += s.formats[0][1]   # only format 0 (S02-B12)
            else: s.errors.append(f'{t} - FORMAT DEFINING, UNKNOWNED PARAMATER.')


if __name__ == '__main__':
    c = Csl(); c.read(sys.argv[1])
    print(f'{sys.argv[1]}: ok={int(not c.errors)} formats={len(c.formats)} rows={len(c.rows)} errors={len(c.errors)}')
    print('  formats:', ', '.join(f'{i}:{f[0]}({len(f[1])})' for i, f in enumerate(c.formats)))
    for e in c.errors[:5]: print('  ERROR', e)
    if '-v' in sys.argv:
        for fid, vals in c.rows: print(' ', c.formats[fid][0], vals)
```

Known simplifications against the original (none reachable with the shipped files): `<HEX>` takes only a pure hex
token (`sscanf("%x")` also accepts `0x` prefixes and trailing garbage); `<FLOAT>` takes only what Python's `float`
parses (`atof` takes the longest numeric prefix); the S02-B13 over-read and the include-remark quirk of §2.2 are not
emulated; `#READ` / `#WRITE*` are refused.

**Test.** Run on every CSL script of `Files/Server/2016` (the eleven `*ServerInfo.txt` incl. the shared one, and the two
`9Data/Shine/*CharacterData.txt` scripts, which the Character server reads with the same reader *(S02 §2.4; checked
in §5)*), as shipped, converted to LF line ends, and with the final `#END` removed (then ending in CRLF), and compared
row by row (format index and every value) with `tools/protocol-re/csl.py`:

| File | As shipped | LF line ends | Without `#END` | Rows equal to `csl.py` |
|---|---|---|---|---|
| `9Data/ServerInfo/ServerInfo.txt` | ok, 4 formats, 29 rows | ok, 29 | fails (`'' - UNKNOWNED.`), 29 | all three |
| `Login/LoginServerInfo.txt`, `w00_WorldManager/WMServerInfo.txt`, `w00_Zone00…03/ZoneServerInfo/ZoneServerInfo.txt`, `Account/DataServerInfo_Account.txt`, `AccountLog/DataServerInfo_AccountLog.txt`, `w00_Character/DataServerInfo_Character.txt`, `w00_GameLog/DataServerInfo_GameLog.txt` | ok, 5 formats (0 MY_SERVER 5 columns, 1 NATION_NAME 1, 2 WORLD_NAME 3, 3 SERVER_INFO 9, 4 ODBC_INFO 5), 30 rows | ok, 30 | fails, 30 | all three |
| `9Data/Shine/DefaultCharacterData.txt` | ok, 6 formats (CHARACTER 11, ITEM 3, SKILL 2, QUEST 2, MAXSHAPE 4, SHORTCUT 4), 530 rows | ok but **505** rows (S02-B16) | fails, 530 | all three |
| `9Data/Shine/TutorialCharacterData.txt` | ok, 3 formats (TUTORIAL_CHARACTER 9, DEFAULT_ITEM 3, TUTORIAL_ITEM 3), 10 rows | ok, 10 | fails, 10 | all three |

The shipped scripts use only `#DEFINE`, `#ENDDEFINE`, `#INCLUDE`, `#END`, `<INTEGER>`, `<STRING>`, `;` remarks
(`DefaultCharacterData.txt`, also after values), CRLF line ends, tab + comma separators, and no trailing line break
after `#END`. A rebuild that writes new files should keep exactly that subset.
