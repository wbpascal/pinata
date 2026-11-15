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
  unknown item (error, S02-B14). The same happens when the file's last byte is the closing `"` of a quoted value: after
  `GetTokenString` FUN_0063b570 the token start points at the terminating NUL, so the next `GetToken` returns `""` →
  `'' - UNKNOWNED.`. So every top-level file and include must end with `#END` (all shipped files do, with no line
  break after it) or with a non-quoted token and no trailing whitespace.

### 2.2 Remarks

Checked on every token, before commands and rows, also inside `#DEFINE` and between row values (not inside quoted
strings, which are found by the quote scan above):

| Token | Effect |
|---|---|
| starts with `;` (the line-remark marker, case-sensitive prefix) | the rest of the line is ignored. Implementation: if the byte after the token's delimiter is not LF, skip to the next LF. With CRLF files this is exact; with LF-only files a remark token that ends at the line end also eats the next line (S02-B16) |
| exactly `/*` | start a block remark: every following token is ignored up to a token that is exactly `*/` (no nesting; markers must be separate tokens: `/*x` is not a block start, `x*/` not an end) |
| exactly `*/` outside a block | ignored |
| `#SEPRATOR t` / `#REMARKLINE t` / `#REMARKSTART t` / `#REMARKEND t` | the next token becomes the delimiter set / line marker / block start / block end (end of file: back to `", \t\r\n"`, `;`, `/*`, `*/`). Unbounded copy into 64-byte fields (S02-B19). Inside an include they change the include only, and only partly: the include's `CCsl(parent)` FUN_00651cb0 copies the parent's `m_CslRemarks` pointer array, whose slots 0–2 point at the **parent's** `m_CslRemarkLine` / `m_CslRemarkStart` / `m_CslRemarkEnd`. So in an include `#SEPRATOR` works; `#REMARKLINE` changes only the prefix test (default branch of `ProcRemark` FUN_00650aa0, `_mbsnbcmp` against the child's `m_CslRemarkLine`), while the whole-token line-marker test keeps the parent's; `#REMARKSTART` / `#REMARKEND` write the child's +0x440 / +0x480, which nothing reads: no effect at all (S02 §2.3.6 for `#REMARKLINE`) |

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
`ReadFile` that returns FALSE fails the `#READ`; an empty file succeeds. A **short** read is not detected: only the
BOOL of `CGdp::ReadFile` FUN_0063bab0 (= Win32 `ReadFile`, TRUE at end of file) is tested, never the bytes-read count,
and neither `NumParameter` nor the row's `dwSize` is checked against the chunk size (Z19-B1). `#WRITE` writes all formats, then all rows. `CCsl::Read`
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
            if t is None: break
            if s.remark(t): continue                     # remarks first, as ReadScript: '/* #END */' is skipped
            u = t.upper()
            if u == '#END': break                        # file ending in a delimiter yields '' (S02-B14) → UNKNOWNED
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
emulated (an include's `#REMARKSTART` / `#REMARKEND` / `#REMARKLINE` act fully here, until the include ends); `#READ` / `#WRITE*` are refused.

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

## 5. The other servers' copies

### 5.1 Method and result

Every same-name function was compared at instruction level (objdump of the 2016 exe, absolute addresses normalised; the
method of S02's `tools/protocol-re/asmcmp.py`, extended to the data servers in a scratch copy):

- **Account, AccountLog**: functions by their NA2016 PDB names (`re-data/exports/account-pdb`, `accountlog-pdb`
  *(pdb2016)*), compared with the zone copy.
- **Character, GameLog** (no PDB): the copy was found by its strings (`"FILE PROCESSING - %s "` → `ReadScript`
  FUN_00446f50 / FUN_0040e7c0, `"%s - FORMAT DEFINING, UNKNOWNED PARAMATER."` → `MakeFormat` FUN_00445700 /
  FUN_0040cf70, `"Include Format %d Defined, %d Errors"` → `ReadScriptDone` FUN_00445d80 / FUN_0040d5f0), then every
  Account function was matched to the most similar function in 0x43a000–0x44c000 / 0x402000–0x414000. Every library
  function finds a partner with similarity 1.000, in the same address order as in Account; the names in
  `tools/protocol-re/names/{character,gamelog}/Z19.json` come from that match (the official names of identical code).

Result:

- **`CToken` (15), `CCsl` (29), `CGdp` (24) are identical in all seven 2016 builds** (Zone, WM, Login per S02 §2.7 /
  §3.6; Account, AccountLog, Character, GameLog here). The only differences lie after the final `ret` of
  `CCsl::MakeData`, `ProcRemark`, `ProcCmd` and `CGdp::CreateFileA`: their inline jump tables, which hold absolute
  addresses.
- **Constant tables equal.** `pCslCmd` (10 commands), `pCslParameter` (18 types + `#ENDDEFINE`), `pCslParameterSize`
  (20 sizes) and `pCslRemarks` (3 null slots, then `#SEPRATOR`, `#REMARKLINE`, `#REMARKSTART`, `#REMARKEND`) have the
  same content and relative layout in every exe (`pCslParameterSize` = `pCslParameter` − 0x50, `pCslCmd` =
  `pCslParameter` + 0x4c, `pCslRemarks` = `pCslCmd` + 0x28). `pCslCmd`: Zone 0x873864, WM 0x497b34, Login 0x43075c,
  Account 0x448584, AccountLog 0x4433b4, Character 0x4df7ac, GameLog 0x44a3b4. The default marker strings `"*/"`,
  `"/*"`, `", \t\r\n"` that `ProcRemark` restores are byte-equal (Zone 0x70cae0, Account 0x434164, AccountLog
  0x42f724, Character 0x4bbe68, GameLog 0x435acc). All 40 result-message strings of S02 §2.6 occur in every exe.
- **Build-specific members.** Zone: `CToken::GetTokenID` (quest scripts), no `CCsl::ViewResultMsg`. WM / Login:
  `CCsl::ViewResultMsg`, no `GetTokenID` (S02 §2.7). The four data servers: neither. So the format of §2 holds for
  every server's config files unchanged.
- **`CServerInfo` is per server** (a thin wrapper compiled with each server, not part of the library): the data
  servers share one variant (Account = AccountLog = Character = GameLog, all members identical), which differs from the
  zone's (§5.3).

`m_bIsGDPOpen` is only ever cleared (`CGdp::Clear`, `GdpClose`, `~CGdp`; §1.1), in Account as in the zone: no
function sets it. `CGdp::Open(ulong)` FUN_0063c290 and `CGdp::Open(char*)` FUN_0063c350 require it to be set already
and set only `m_bIsOpen`. The data servers therefore also read every config file as a plain file (S02 §3.2).

### 5.2 Function addresses per build

WM and Login addresses: S02 §2.7 / §3.6. `–` = no such function in that build. The data servers' `~CServerInfo`
(Close + `~CToken`, same code as `~CCsl`) is a jump thunk to `~CCsl` in Character and GameLog.

| Function | Zone | Account | AccountLog | Character | GameLog |
|---|---|---|---|---|---|
| `CServerInfo::~CServerInfo` | – | FUN_00401000 | FUN_00401000 | FUN_0043ed60 (thunk → ~CCsl) | FUN_00401000 (thunk → ~CCsl) |
| `CToken::CToken` | FUN_0063aea0 | FUN_00406ef0 | FUN_00406ac0 | FUN_00442350 | FUN_0040b280 |
| `CToken::Close` | FUN_0063af10 | FUN_00406f60 | FUN_00406b30 | FUN_004423c0 | FUN_0040b2f0 |
| `CToken::SetSeprator` | FUN_0063af70 | FUN_00406fc0 | FUN_00406b90 | FUN_00442420 | FUN_0040b350 |
| `CToken::my_tcstok` | FUN_0063af90 | FUN_00406fe0 | FUN_00406bb0 | FUN_00442440 | FUN_0040b370 |
| `CToken::GetToken` | FUN_0063b010 | FUN_00407060 | FUN_00406c30 | FUN_004424c0 | FUN_0040b3f0 |
| `CToken::GoBegin` | FUN_0063b090 | FUN_004070e0 | FUN_00406cb0 | FUN_00442540 | FUN_0040b470 |
| `CToken::GoNextLine` | FUN_0063b150 | FUN_004071a0 | FUN_00406d70 | FUN_00442600 | FUN_0040b530 |
| `CToken::GoStartString` | FUN_0063b1a0 | FUN_004071f0 | FUN_00406dc0 | FUN_00442650 | FUN_0040b580 |
| `CToken::SaveTokenPositon` | FUN_0063b1f0 | FUN_00407240 | FUN_00406e10 | FUN_004426a0 | FUN_0040b5d0 |
| `CToken::RestoreTokenPositon` | FUN_0063b200 | FUN_00407250 | FUN_00406e20 | FUN_004426b0 | FUN_0040b5e0 |
| `CToken::IsTokenID` | FUN_0063b270 | FUN_004072c0 | FUN_00406e90 | FUN_00442720 | FUN_0040b650 |
| `CToken::~CToken` | FUN_0063b310 | FUN_00407300 | FUN_00406ed0 | FUN_00442760 | FUN_0040b690 |
| `CToken::Open` | FUN_0063b3a0 | FUN_00407390 | FUN_00406f60 | FUN_004427f0 | FUN_0040b720 |
| `CToken::OpenFromMemory` | FUN_0063b4b0 | FUN_004074a0 | FUN_00407070 | FUN_00442900 | FUN_0040b830 |
| `CToken::GetTokenString` | FUN_0063b570 | FUN_00407560 | FUN_00407130 | FUN_004429c0 | FUN_0040b8f0 |
| `CGdp::Clear` | FUN_0063b660 | FUN_0040bba0 | FUN_00407220 | FUN_00444180 | FUN_0040b9e0 |
| `CGdp::GdpSetFilePointer` | FUN_0063b6e0 | FUN_0040bc20 | FUN_004072a0 | FUN_00444200 | FUN_0040ba60 |
| `CGdp::GdpDecryptData` | FUN_0063b760 | FUN_0040bca0 | FUN_00407320 | FUN_00444280 | FUN_0040bae0 |
| `CGdp::GdpWriteChunk` | FUN_0063b7a0 | FUN_0040bce0 | FUN_00407360 | FUN_004442c0 | FUN_0040bb20 |
| `CGdp::GdpUpdateChunk` | FUN_0063b860 | FUN_0040bda0 | FUN_00407420 | FUN_00444380 | FUN_0040bbe0 |
| `CGdp::UpdateWriteDataInfo` | FUN_0063b8c0 | FUN_0040be00 | FUN_00407480 | FUN_004443e0 | FUN_0040bc40 |
| `CGdp::GdpSearchFile` | FUN_0063b960 | FUN_0040bea0 | FUN_00407520 | FUN_00444480 | FUN_0040bce0 |
| `CGdp::GdpDeleteFile` | FUN_0063b9c0 | FUN_0040bf00 | FUN_00407580 | FUN_004444e0 | FUN_0040bd40 |
| `CGdp::GdpDeleteFile` (2nd overload) | FUN_0063ba40 | FUN_0040bf80 | FUN_00407600 | FUN_00444560 | FUN_0040bdc0 |
| `CGdp::CloseHandle` | FUN_0063ba70 | FUN_0040bfb0 | FUN_00407630 | FUN_00444590 | FUN_0040bdf0 |
| `CGdp::ReadFile` | FUN_0063bab0 | FUN_0040c000 | FUN_00407670 | FUN_004445d0 | FUN_0040be30 |
| `CGdp::WriteFile` | FUN_0063bb40 | FUN_0040c090 | FUN_00407700 | FUN_00444660 | FUN_0040bec0 |
| `CGdp::GetFileSize` | FUN_0063bc30 | FUN_0040c180 | FUN_004077f0 | FUN_00444750 | FUN_0040bfb0 |
| `CGdp::SetFilePointer` | FUN_0063bc70 | FUN_0040c1c0 | FUN_00407830 | FUN_00444790 | FUN_0040c000 |
| `CGdp::fclose` | FUN_0063bd40 | FUN_0040c290 | FUN_00407900 | FUN_00444860 | FUN_0040c0d0 |
| `CGdp::CGdp` | FUN_0063bd90 | FUN_0040c2e0 | FUN_00407950 | FUN_004448b0 | FUN_0040c120 |
| `CGdp::GdpCloseFile` | FUN_0063bdb0 | FUN_0040c300 | FUN_00407970 | FUN_004448d0 | FUN_0040c140 |
| `CGdp::GdpMakeEmptyChunk` | FUN_0063bdf0 | FUN_0040c340 | FUN_004079b0 | FUN_00444910 | FUN_0040c180 |
| `CGdp::GdpClose` | FUN_0063c1e0 | FUN_0040c730 | FUN_00407da0 | FUN_00444d00 | FUN_0040c570 |
| `CGdp::Open` | FUN_0063c290 | FUN_0040c7e0 | FUN_00407e50 | FUN_00444db0 | FUN_0040c620 |
| `CGdp::Open` (2nd overload) | FUN_0063c350 | FUN_0040c8a0 | FUN_00407f10 | FUN_00444e70 | FUN_0040c6e0 |
| `CGdp::~CGdp` | FUN_0063c380 | FUN_0040c8d0 | FUN_00407f40 | FUN_00444ea0 | FUN_0040c710 |
| `CGdp::GdpGetEmptyChunk` | FUN_0063c390 | FUN_0040c8e0 | FUN_00407f50 | FUN_00444eb0 | FUN_0040c720 |
| `CGdp::CreateFileA` | FUN_0063c3d0 | FUN_0040c920 | FUN_00407f90 | FUN_00444ef0 | FUN_0040c760 |
| `CCsl::VarClear` | FUN_00650710 | FUN_0040cb90 | FUN_00408200 | FUN_00445160 | FUN_0040c9d0 |
| `CCsl::MakeFormatTable` | FUN_00650780 | FUN_0040cc00 | FUN_00408270 | FUN_004451d0 | FUN_0040ca40 |
| `CCsl::MakeDataTable` | FUN_00650800 | FUN_0040cc80 | FUN_004082f0 | FUN_00445250 | FUN_0040cac0 |
| `CCsl::AddResultMsg` | FUN_00650880 | FUN_0040cd00 | FUN_00408370 | FUN_004452d0 | FUN_0040cb40 |
| `CCsl::GetFormat` | FUN_00650900 | FUN_0040cd80 | FUN_004083f0 | FUN_00445350 | FUN_0040cbc0 |
| `CCsl::GetNumDatas` | FUN_00650950 | FUN_0040cdd0 | FUN_00408440 | FUN_004453a0 | FUN_0040cc10 |
| `CCsl::GetDataInfo` | FUN_00650960 | FUN_0040cde0 | FUN_00408450 | FUN_004453b0 | FUN_0040cc20 |
| `CCsl::GetData` | FUN_006509b0 | FUN_0040ce30 | FUN_004084a0 | FUN_00445400 | FUN_0040cc70 |
| `CCsl::ProcRemark` | FUN_00650aa0 | FUN_0040cf20 | FUN_00408590 | FUN_004454f0 | FUN_0040cd60 |
| `CCsl::MakeFormat` | FUN_00650cb0 | FUN_0040d130 | FUN_004087a0 | FUN_00445700 | FUN_0040cf70 |
| `CCsl::AddFormat` | FUN_00650f60 | FUN_0040d3e0 | FUN_00408a50 | FUN_004459b0 | FUN_0040d220 |
| `CCsl::GetDataToken` | FUN_00650fa0 | FUN_0040d420 | FUN_00408a90 | FUN_004459f0 | FUN_0040d260 |
| `CCsl::Parameter_filename` | FUN_00651020 | FUN_0040d4a0 | FUN_00408b10 | FUN_00445a70 | FUN_0040d2e0 |
| `CCsl::MakeData` | FUN_00651050 | FUN_0040d4d0 | FUN_00408b40 | FUN_00445aa0 | FUN_0040d310 |
| `CCsl::ProcData` | FUN_006512a0 | FUN_0040d720 | FUN_00408d90 | FUN_00445cf0 | FUN_0040d560 |
| `CCsl::ReadScriptDone` | FUN_00651330 | FUN_0040d7b0 | FUN_00408e20 | FUN_00445d80 | FUN_0040d5f0 |
| `CCsl::Read` | FUN_00651540 | FUN_0040d9c0 | FUN_00409030 | FUN_00445f90 | FUN_0040d800 |
| `CCsl::WriteFormat` | FUN_00651780 | FUN_0040dc00 | FUN_00409270 | FUN_004461d0 | FUN_0040da40 |
| `CCsl::WriteData` | FUN_006518a0 | FUN_0040dd20 | FUN_00409390 | FUN_004462f0 | FUN_0040db60 |
| `CCsl::ClearFormats` | FUN_006519b0 | FUN_0040de30 | FUN_004094a0 | FUN_00446400 | FUN_0040dc70 |
| `CCsl::ClearDatas` | FUN_00651a20 | FUN_0040dea0 | FUN_00409510 | FUN_00446470 | FUN_0040dce0 |
| `CCsl::Close` | FUN_00651a90 | FUN_0040df10 | FUN_00409580 | FUN_004464e0 | FUN_0040dd50 |
| `CCsl::Clear` | FUN_00651b10 | FUN_0040dfa0 | FUN_00409600 | FUN_00446560 | FUN_0040ddd0 |
| `CCsl::~CCsl` | FUN_00651bf0 | FUN_0040e080 | FUN_004096e0 | FUN_00446640 | FUN_0040deb0 |
| `CCsl::CCsl()` | FUN_00651c50 | FUN_0040e0e0 | FUN_00409740 | FUN_004466a0 | FUN_0040df10 |
| `CCsl::CCsl(parent)` | FUN_00651cb0 | FUN_0040e140 | FUN_004097a0 | FUN_00446700 | FUN_0040df70 |
| `CCsl::IncludeFile` | FUN_00651ea0 | FUN_0040e330 | FUN_00409990 | FUN_004468f0 | FUN_0040e160 |
| `CCsl::ProcCmd` | FUN_00652000 | FUN_0040e490 | FUN_00409af0 | FUN_00446a50 | FUN_0040e2c0 |
| `CCsl::ReadScript` | FUN_00652500 | FUN_0040e990 | FUN_00409ff0 | FUN_00446f50 | FUN_0040e7c0 |
| `CServerInfo::CServerInfo` | FUN_0064d0e0 | FUN_0040f580 | FUN_0040b610 | FUN_0043eb40 | FUN_0040fde0 |
| `CServerInfo::ReadServerInfo` | FUN_0064d0f0 | FUN_0040f590 | FUN_0040b620 | FUN_00449410 | FUN_0040fdf0 |
| `CServerInfo::GetMyServerInfo` | FUN_0064d130 | FUN_0040f5c0 | FUN_0040b650 | FUN_00449440 | FUN_0040fe20 |
| `CServerInfo::GetServerInfo(info, row)` | FUN_0064d1c0 | FUN_0040f650 | FUN_0040b6e0 | FUN_004494d0 | FUN_0040feb0 |
| `CServerInfo::GetServerIndex` | FUN_0064d270 | FUN_0040f700 | FUN_0040b790 | FUN_00449580 | FUN_0040ff60 |
| `CServerInfo::GetODBCInfo` | – | FUN_0040f7d0 | FUN_0040b860 | FUN_00449650 | FUN_00410030 |
| `CServerInfo::GetServerInfo(info, id, world, zone[, from])` | FUN_0064d420 | FUN_0040f880 | FUN_0040b910 | FUN_00449700 | FUN_004100e0 |
| `CToken::GetTokenID` | FUN_0063b2b0 | – | – | – | – |
| `CServerInfo::GetNumOfData` | FUN_0064d120 | – | – | – | – |
| `CServerInfo::GetNationName` | FUN_0064d350 | – | – | – | – |
| `CServerInfo::GetWorldName` | FUN_0064d3a0 | – | – | – | – |

### 5.3 The data servers' `CServerInfo`

Members of the data-server variant (Account addresses; the others in §5.2). The structs are the same as in the zone
(`MY_SERVER`, `SERVER_INFO`, `ODBC_INFO`, Z10 §6.5) *(pdb2016)*; string members point into the row data (the CSL row
stores strings inline, S02 knowledge), so they stay valid until the next `ReadServerInfo` / `Close`.

```pseudo
CServerInfo::ReadServerInfo(file):        Clear(); return ReadScript(file, hWnd 0, msgId 0x401, mem 0)   @ FUN_0040f590
GetMyServerInfo(out MY_SERVER):                                                                    @ FUN_0040f5c0
    first row with dwID == 0 (MY_SERVER): pServiceName = col 0, pDisplayName = col 1, nServerID = col 2,
        nWorldNo = col 3, nZoneNo = col 4; return 1;  no such row: return 0
GetServerInfo(out SERVER_INFO, row):                                                               @ FUN_0040f650
    if GetDataInfo(row).dwID != 3: return 0          # no range check on row (GetDataInfo returns null → crash,
                                                     #   the zone's copy is the same; callers pass an index from GetServerIndex)
    pName = col 0, nServerID 1, nWorldNo 2, nZoneNo 3, nServerIDFrom 4, pIP 5, nPort 6, nBackLog 7, nMaxAccept 8; return 1
GetServerIndex(id, world, zone):                                                                    @ FUN_0040f700
    first row with dwID == 3 (SERVER_INFO) and col1 == id, col2 == world, col3 == zone → its index; else −1
    # the zone's GetServerIndex FUN_0064d270 also compares col 4 (nServerIDFrom) with a 4th argument;
    # the data servers' rows have one SERVER_INFO row each (nServerIDFrom 0), so the 3-key search finds it
GetServerInfo(out SERVER_INFO, id, world, zone):  i = GetServerIndex(id, world, zone); i == −1 → 0; else GetServerInfo(out, i)   @ FUN_0040f880
GetODBCInfo(out ODBC_INFO, dbId, world):                                                            @ FUN_0040f7d0
    first row with dwID == 4 (ODBC_INFO) and col1 == dbId, col2 == world:
        pName = col 0, nDBID = dbId, nWorldNo = world, pConnectInfo = col 3, pStartupCmd = col 4; return 1
    else return 0                                    # caller: CSessionWorker::DB_Init FUN_00405f20 (D01 §1)
```

As in the zone, the format indices 0, 3, 4 are fixed by the order of the `#DEFINE`s across the server file and the
included `ServerInfo.txt` (`MY_SERVER` 0 in `DataServerInfo_*.txt`, then `NATION_NAME` 1, `WORLD_NAME` 2,
`SERVER_INFO` 3, `ODBC_INFO` 4; §3).

### 5.4 Which files each server reads, and when

Every server's start function first sets the process's current directory to the exe's directory
(`GetModuleFileNameA`, cut at the last `\`, `_chdir`; read in Account `DataServer::Start` FUN_00401d20, the same
`_chdir` call sits in Login `LoginServer::Start` FUN_00402f30, WM `WorldManagerServer::Start` FUN_00407190, Zone
`ZoneServer::zs_start` FUN_005ab520, AccountLog FUN_00401d60, Character FUN_00402570, GameLog FUN_00401de0). Every
relative path below, and the include paths inside the files (§2.6, relative to the including file), therefore start
at the server's install directory.

| Server | File (paths tried in order) | Read by | Object | On failure |
|---|---|---|---|---|
| Login | `LoginServerInfo.txt` | `LoginServer::ReadDefineScriptor` FUN_00401380 (L00 §2 `LoadServerInfo`, L01 §1.2) | `gServer.m_ServerInfo` (+0) | `ViewErrorMsg` prints the result messages (S02 §2.5); start fails |
| WM | `WMServerInfo.txt` | `WorldManagerServer::ReadDefineScriptor` FUN_00403e70 (W01 §2, W05 §1) | `m_ServerInfo` (+0) | same |
| Zone | `ZoneServerInfo/ZoneServerInfo.txt`, then `../9Data/ServerInfo/ZoneServerInfo.txt` | `zs_start` FUN_005ab520 and `zs_ServiceThreadFunction` FUN_005a9d90 (§3) | `zs_serverinfo.serverinfo` (+0x40) | assert text + `ShineExit` |
| Account | `DataServerInfo_Account.txt` | `DataServer::ReadDefineScriptor` FUN_00401360 | `m_ServerInfo` (+0) | log, `Start` returns −1 |
| AccountLog | `DataServerInfo_AccountLog.txt` | `DataServer::ReadDefineScriptor` FUN_00401380 | `m_ServerInfo` (+0) | same |
| Character | `DataServerInfo_Character.txt` | `DataServer::ReadDefineScriptor` FUN_004013b0 | +0 | log, `Start` FUN_00402570 returns −1 |
| Character | `../../9Data/Shine/DefaultCharacterData.txt`, then `../9Data/Shine/DefaultCharacterData.txt` | `GameData_Load` FUN_00401550 (D02 §1) | second `CServerInfo` at +0x209890 | log `"*FAILED GLOBAL GAME DATA READ - DefaultCharacterData.txt"`, return 0 → start stops |
| Character | `../../9Data/Shine/TutorialCharacterData.txt`, then `../9Data/Shine/TutorialCharacterData.txt` | `GameData_Load` FUN_00401550 | third `CServerInfo` at +0x209f4c | same text with `TutorialCharacterData.txt` |
| GameLog | `DataServerInfo_GameLog.txt` | `DataServer::ReadDefineScriptor` FUN_00401370 (D05 §1.1) | +0 | log, `Start` returns −1 (D05 §7.1) |

All four `DataServerInfo_*.txt` define `MY_SERVER` and `#INCLUDE "../9Data/ServerInfo/ServerInfo.txt"`, which from
`Account/`, `AccountLog/`, `w00_Character/`, `w00_GameLog/` is the shared `Files/Server/2016/9Data/ServerInfo/ServerInfo.txt`.
For the Character server's two data scripts only the second path exists in the 2016 layout (`w00_Character/../9Data/Shine/`);
the first attempt fails with a file-open error, and the second `ReadServerInfo` starts with `Clear()`, so the failed
attempt leaves nothing behind. The Character server's three `CServerInfo` objects are built by its `DataServer`
constructor FUN_00401f20 (three calls of `CServerInfo::CServerInfo` FUN_0043eb40, at +0, +0x209890, +0x209f4c). Its rows
are read by D02's typed readers (D02 §3.3: format indices CHARACTER 0, ITEM 1, SKILL 2, QUEST 3, MAXSHAPE 4, SHORTCUT 5;
TUTORIAL_CHARACTER 0, DEFAULT_ITEM 1, TUTORIAL_ITEM 2). Both scripts parse with 0 errors (§4); `DefaultCharacterData.txt`
must keep CRLF line ends (LF loses 25 rows, S02-B16).

```pseudo
DataServer::ReadDefineScriptor(this):       @ Account FUN_00401360, AccountLog FUN_00401380, Character FUN_004013b0, GameLog FUN_00401370
    # the four are identical apart from the file name (instruction-level compare)
    if !CServerInfo::ReadServerInfo(&this.m_ServerInfo, "DataServerInfo_<Server>.txt"):
        log "*FAILED SCRIPTOR READ* " + file;  CToken::Close(&this.m_ServerInfo);  return 0
        # the result messages are never printed: the data servers have no ViewErrorMsg / ViewResultMsg
    log "<SUCCESSED SCRIPTOR READ> " + file;  CToken::Close(&this.m_ServerInfo)    # already closed by ReadScript; frees nothing new
    if !GetMyServerInfo(&this.m_MyServer (+0x4f8)):  log "*FAILED GetMyServerInfo*"; return 0
    log "<I AM THE %s, %s, WorldNo=%d, ZoneNo=%d>" (pDisplayName, GetShineServerIDName(nServerID), nWorldNo, nZoneNo)
    if !GetServerInfo(&info, m_MyServer.nServerID, .nWorldNo, .nZoneNo):
        log "FATAL ERROR - Can't found ServerInfo on funcition 'DataServer::ReadDefineScriptor()', need check scriptor data."
        return 0
    m_ConnectSocket_BindIP (+0x50c, 16 bytes) = strncpy(info.pIP, 16); [15] = 0;  return 1
```

`DataServer::Start` returns −1 when this fails (Account FUN_00401d20; Character FUN_00402570 also requires
`GameData_Load`). The later `SERVER_INFO` / `ODBC_INFO` lookups (`Start_Acceptor`, `DB_Init`) are the framework's
(D01 §1, D05 §1.1).

## 6. Original-server bugs

One new bug, in the binary chunk reader (found in the review; S02 lists only the handle leak S02-B17 for that
function). Same code in all seven builds (§5.1):

| ID | Function | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z19-B1 | `CCsl::Read` FUN_00651540 (`#READ`; Account FUN_0040d9c0, AccountLog FUN_00409030, Character FUN_00445f90, GameLog FUN_0040d800) | only the BOOL of `CGdp::ReadFile` FUN_0063bab0 is tested, never the bytes-read count (`ebp-4`, passed at 0x6515ae / 0x651601); a chunk's `NumParameter` (+0x48) drives `memcpy(…, n·4)` and a row's `dwSize` (+0xc) drives `new` + `memcpy`, neither checked against the chunk `size` (original bug) | a truncated chunk is accepted with uninitialised heap bytes (`operator new[]` does not zero), the loop then reaches the file size and `Read` returns 1; an inconsistent `NumParameter` / `dwSize` reads past the heap buffer | compare bytes read with the requested size; check `0x44 + 4·n == size` and `dwSize + 8 == size`. Unreachable from the shipped files (no script uses `#READ`) |

The other defects of the reader are S02's, and the copies of all seven servers share them (§5.1). Cross-reference of
those that can affect a config file, with the zone and data-server addresses (WM / Login addresses in S02 §5):

| S02 bug | Function | Zone / Account / AccountLog / Character / GameLog | Effect on the config files |
|---|---|---|---|
| S02-B11 | `CCsl::MakeData` (`<ARRAYSRT>`) | FUN_00651050 / FUN_0040d4d0 / FUN_00408b40 / FUN_00445aa0 / FUN_0040d310 | none shipped use array types; a file that did would misread later columns |
| S02-B12 | `CCsl::MakeFormat` (inheritance) | FUN_00650cb0 / FUN_0040d130 / FUN_004087a0 / FUN_00445700 / FUN_0040cf70 | not used by the shipped files |
| S02-B13 | `CToken::GoStartString` / `GetTokenString` | FUN_0063b1a0, FUN_0063b570 / FUN_004071f0, FUN_00407560 / FUN_00406dc0, FUN_00407130 / FUN_00442650, FUN_004429c0 / FUN_0040b580, FUN_0040b8f0 | a missing closing quote or `""` reads past the buffer |
| S02-B14 | `CToken::my_tcstok` | FUN_0063af90 / FUN_00406fe0 / FUN_00406bb0 / FUN_00442440 / FUN_0040b370 | a file without `#END` that ends in whitespace fails (§4 "Without `#END`") |
| S02-B15 | `CCsl::CCsl(parent)` | FUN_00651cb0 / FUN_0040e140 / FUN_004097a0 / FUN_00446700 / FUN_0040df70 | EOF inside a row of `ServerInfo.txt` (included) uses an uninitialised pointer |
| S02-B16 | `CToken::GoNextLine` | FUN_0063b150 / FUN_004071a0 / FUN_00406d70 / FUN_00442600 / FUN_0040b530 | LF-only `DefaultCharacterData.txt` loses 25 of 530 rows (§4) |
| S02-B18 | `CCsl::IncludeFile` | FUN_00651ea0 / FUN_0040e330 / FUN_00409990 / FUN_004468f0 / FUN_0040e160 | an include path with a space or comma fails the read |
| S02-B19 | `ProcRemark` / `MakeFormat` / `MakeData` (unbounded copies) | FUN_00650aa0, FUN_00650cb0, FUN_00651050 / FUN_0040cf20, FUN_0040d130, FUN_0040d4d0 / FUN_00408590, FUN_004087a0, FUN_00408b40 / FUN_004454f0, FUN_00445700, FUN_00445aa0 / FUN_0040cd60, FUN_0040cf70, FUN_0040d310 | a string value over 511 bytes (e.g. a long ODBC connect string) overflows the row |
| S02-B20 | `CCsl::GetDataToken` | FUN_00650fa0 / FUN_0040d420 / FUN_00408a90 / FUN_004459f0 / FUN_0040d260 | EOF in a row is counted as a format error (diagnostics only) |
| S02-B21 | `CCsl::MakeData` (`[…]` types) | as S02-B11 | not used by the shipped files |

S02-B17 (`#READ` handle leak) and S02-B22 (dead constructor path) are unreachable from the shipped files.

## 7. Not reconstructed / uncertain

- Character `CServerInfo::CServerInfo` FUN_0043eb40 is identified by identical code (Account FUN_0040f580) and by being
  the only caller of `CCsl::CCsl()` FUN_004466a0; it sits far from the other `CServerInfo` members (FUN_00449410 …),
  unlike in the other builds. Whether the Character / GameLog `~CServerInfo` thunks (FUN_0043ed60, FUN_00401000) are
  the original destructor or linker folding onto `~CCsl` cannot be told from the code (same behaviour either way).
- The `<I AM THE …>` and `*FAILED SCRIPTOR READ*` argument lists follow the format strings and the pushed
  addresses; the export drops the varargs of `_DebugMessageNew` / `Log`.
- `msgId 0x401` / `hWnd`: stored and never used in any of the seven builds (§2.8); their purpose is *(inferred)*.
- The 2015 server builds were not compared (out of scope: only 2016 is documented).

## 8. Coverage boundary

| Found (function / table / behaviour) | Covered by | Argument |
|---|---|---|
| `CToken` / `CCsl` / `CGdp` pseudocode (all builds) | S02 (done) §2.2–§2.3, §3 | identical code (§5.1); this document cites S02 instead of repeating it |
| `CGdp` container mode (`GdpSearchFile`, `GdpMakeEmptyChunk`, `GdpWriteChunk`, `Open` …, §5.2 rows) | S02 (done) §3.3–§3.5 | dead in every server (`m_bIsGDPOpen` never set, §5.1); S02 documents it |
| Zone `CServerInfo` lookups (`GetNationName`, `GetWorldName`, `GetNumOfData`, 4-key `GetServerIndex`) and what the rows mean | Z10 (done) §1.1, §6.5 | the zone's consumers of the rows |
| WM / Login `ReadDefineScriptor`, `ViewErrorMsg`, `GetNumOfWorld` / `GetWorldName` | W01 §2, W05 (done) §5.2 / §6.2, L00 §2 (done), L01 (done) §1, S02 (done) §2.5 / §4.3 | their callers and the row meanings are documented there |
| Data-server `Start`, `Start_Acceptor` (2nd `GetServerInfo`), `CSessionWorker::DB_Init` (`GetODBCInfo` caller) | D01 (done) §1, D05 (done) §1.1 | framework start sequence and DB connection; this document gives only the config read (§5.4) |
| Character `GameData_Load` FUN_00401550 (SHN tables, MapInfo) and the typed row readers of `DefaultCharacterData` / `TutorialCharacterData` | D02 (done) §1, §3.3, §8 | what the character server does with those rows; the CSL read itself is §5.4 |
| Contents and meaning of each config file (IDs, ports, ODBC rows, `_ServerGroup.txt`) | `docs/knowledge/X03.md` §4–§5, Z10 knowledge "Server config files", W05 §5.2 | deployment knowledge, not the reader |
| `9Data/ServerInfo/_ServerGroup.txt` | Z10 (done) §1.1 | not a CSL script: only the zone reads it (`zs_start`, `fopen` + `fscanf("%s")`, one word); no other 2016 exe references it |
| Zone quest scripts over the bare `CToken` (`CQuestParserScript`, `GetTokenID`) | Z15 (open; its plan names `QuestScript_Next` FUN_006387f0 = `CQuestParserScript::ParserNext` *(pdb2016)*) | uses only the tokenizer, not `CCsl`; S02 §2.5 for `GetTokenID` |
