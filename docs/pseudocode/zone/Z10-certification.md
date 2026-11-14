# Zone: certification and the downloaded start script (Z10)

Source binary: `Files/Server/2016/w00_Zone00/5ZoneServer2.exe` (the four zone exes are identical). Read the code with
`python3 -I tools/protocol-re/clean.py re-data/exports/zone-pdb - <addr>…` (official names and types from the NA2016
`Zone.pdb`, *(pdb2016)*: every `Class::method` name in this file comes from there unless marked otherwise) or with
`re-data/exports/zone` + `tools/protocol-re/names/zone`. String arguments that Ghidra drops from `fprintf`/`sscanf`
calls were read from the raw instructions (`objdump -d -M intel --start-address=…`). The replacement answer comes from
`Files/Server/NA2016/GamigoZR/GamigoZR.exe` (.NET IL, read with a metadata/IL parser; §4) and the keys from
`Files/Server/NA2016/GBO.reg` / `Fantasy.reg`. Evidence markers: *(pdb2016)*, *(inferred)*; nothing here is
*(captured)* yet. This item has no client-facing packets.

Related: Z01-core §2 (startup, data tables per stage; its "order unknown" and "retry once" statements are superseded
by §2 and §4 here), `docs/knowledge/Z01.md` §7, `docs/knowledge/S01.md` §1.5.

## 1. Overview

The zone process holds all start-up code, but nothing calls it directly. `ZoneServer::zs_ServiceThreadFunction`
downloads a small Lua script over HTTP, decrypts it, runs it, and the script calls the registered C stage functions:

```
zs_ServiceThreadFunction                     @ FUN_005a9d90  (Z01 called it "zs_start"; the real zs_start is FUN_005ab520)
    ReadServerInfo / GetMyServerInfo, som_Initialize, ddt_Initialize, LUA_PATH       (Z01-core §2.1)
    zs_start_old                             @ FUN_005b0f60
        zs_LuaFromHTML("127.0.0.1", 58492)   @ FUN_005b07a0   else zs_LuaFromHTML("cert1.fo.gamigo", 80)
            GET /GR.php?act=boot&…           (§2.3)
            "[a][b]{( … )}]<hex>" → RSA blocks → LZ ring expand → Lua text      (§3)
            ls_FromString(text)              # runs the chunk: defines tmfpemfjs, chrlghk, xlrfunction (§4.2)
            ls_FunctionCall("chrlghk")       # all zs_start_* data stages + run/walk factors
    g_ZoneServer = server
    ls_FunctionCall("tmfpemfjs")             # all zs_service_* : IOCP, sockets, main thread, acceptor, 2 threads
    wait while server.running
main thread, once per world minute           # certification counter / kill switch, lsf_Factor × 1.01, script's xlrfunction (§6.1)
certification thread, every 10 s             # answers the challenge over HTTP: act=<x> → [I][M]<2x³−3x²+5x−7> (§6.2)
```

So the data stages run **before** any network service exists, and the order of both groups is the order written in
the script (§4.3).

## 2. Fetching the script

### 2.1 zs_start_old

```pseudo
ZoneServer::zs_start_old(server):                         @ FUN_005b0f60
    truncate "Message.txt" and "MapLoad.txt" (fopen "w" + fclose)
    append "-" and "ZoneServer::zs_start_old" to Message.txt           # each Message.txt line: fopen "a", "%s\n", fclose
    g_LuaArgument.SkipNumber = 0; .Summary = 0; .CertifyArg = 0         # struct LuaArgument (§5.3) @ DAT_14d6fcd8
    if !zs_LuaFromHTML(server, "127.0.0.1", 58492 /*0xE47C*/):
        zs_LuaFromHTML(server, "cert1.fo.gamigo", 80)                    # result ignored
```

`cert1.fo.gamigo` is not a resolvable public name (`.gamigo` is no TLD); it only worked inside Gamigo's network
(hosts file / internal DNS) *(inferred)*. With no answer on 127.0.0.1:58492 the zone crashes later (§2.6, Z10-B6).

### 2.2 zs_LuaFromHTML

```pseudo
ZoneServer::zs_LuaFromHTML(server, host, port) → bool:    @ FUN_005b07a0
    log "HTML"
    attempt = 0
    loop:                                                  # runs exactly once (original bug) Z10-B8
        nation = CServerInfo::GetNationName(server.zs_serverinfo.serverinfo)   @ FUN_0064d350  (CSL entry with dwID 1 = NATION_NAME)
        text = HTTPString()                                @ FUN_00613680
        HTTPString::hs_HTMMRead(text, host, port, "boot", myserver.nWorldNo, myserver.nZoneNo, nation)  @ FUN_00613440 (§2.3)
        log "   Pass 0"
        g_LuaArgument.MaxSkip = 0; .Interval = 0; .Count = 0
        sscanf(text, "[%d][%d]", &g_LuaArgument.Interval, &g_LuaArgument.MaxSkip)   # targets read from the push order
        if not (1 <= Interval <= 10080 /*0x2760*/):        # unsigned (Interval-1) < 0x2760; 10080 = minutes of a week
            Interval = 100                                 # dead store: this attempt is abandoned (original bug) Z10-B7
        elif not (unsigned MaxSkip < 11):
            MaxSkip = 5                                    # dead store as well
        else:
            log "   Pass 1"
            if RegOpenKeyExA(HKLM, "SOFTWARE\\GBO", 0, KEY_QUERY_VALUE|KEY_WOW64_32KEY /*0x201*/) == 0:
                # the 32-bit view: on 64-bit Windows this is HKLM\SOFTWARE\Wow6432Node\GBO (as in GBO.reg)
                N = D = 0 (int64); size = 256; type = REG_SZ
                if RegQueryValueExA("Natural", buf[256], &size) == 0: sscanf(buf, "%I64d", &N)
                if RegQueryValueExA("Desert",  buf,      &size) == 0: sscanf(buf, "%I64d", &D)   # size not reset (original bug) Z10-B3
                if N == 0 or D == 0: log "   Code"           # only logged; decoding still runs (original bug) Z10-B4
                RegCloseKey
                HTTPString::hs_Decoding(text, N, D)          @ FUN_00613750 (§3.1)
            # no GBO key: decoding is silently skipped and the still-encrypted text goes on (original bug) Z10-B9
            log "   Pass 2"
            HTTPString::hs_Expand(text)                    @ FUN_00613950 (§3.2)
            log "   Pass 3"
            if LuaScript::ls_FromString(g_LUA_SCRIPT_SECURITY, text):   @ FUN_005d6d40 (§5.1)
                log "   Pass 4"
                overwrite every byte of text with ' ', then set its length to 0     # plaintext wiped from memory
                if LuaScript::ls_FunctionCall(g_LUA_SCRIPT_SECURITY, "chrlghk", lsa_NoLuaArgument):  @ FUN_005d7bc0
                    log "   Sun"; return true
                AssertFail "ZoneServer::zs_start_old : function call error"     # AssertClass::ac_AssertFail FUN_0063c710: log only
            else:
                AssertFail "ZoneServer::zs_start_old : Script error"
        Sleep(1000)
        attempt += 1
        if attempt > 0: log "   Fly"; return false
```

`Message.txt` of a successful start therefore reads `-`, `ZoneServer::zs_start_old`, `HTML`, `   Pass 0` … `   Pass 4`,
then the lines the stages and the script's `vmflsxm` write (`Script : Good`, §4.3), then `   Sun`. A missing key adds
`   Code` after `   Pass 1`; a failed attempt ends with `   Fly`.

`chrlghk` (the data stages) runs inside this function; `tmfpemfjs` (the services) is called afterwards by
`zs_ServiceThreadFunction` (§1).

### 2.3 HTTP request (CHttpConnect over WinINet)

```pseudo
HTTPString::hs_HTMMRead(out, host, port, act, world, zone, nation) → true:   @ FUN_00613440
    c = CHttpConnect(out)                                  @ FUN_00613ca0  (c.HTMLDocument = &out; object is 0x19A64 bytes on the stack)
    if !c.InitConnection(10000): printf "Error! %d" (GetLastError)      @ FUN_00614200
    c.SetPortA(port)                                       @ FUN_00613cb0  (only if port != 0 and not yet set)
    c.SetServer(host)                                      @ FUN_00613cf0  (strncpy 64)
    c.SetFuntion("GR.php")                                 @ FUN_00613d30  (sic "Funtion", strncpy 64)
    c.SetParameter("act", act)          # "boot"          @ FUN_00613d70  (each "%s=%s" into a 128-byte slot, max 12)
    c.SetParameter("title", "Fiesta")
    c.SetParameter("nation", nation)    # NATION_NAME of ServerInfo.txt, 2016: "EU_US_REAL"
    c.SetParameter("pw", "wkdbdmldutlstkd")   # Korean 2-set keyboard spelling of 자유의여신상 "Statue of Liberty" (inferred: the USA build's password)
    c.SetParameter("world", sprintf("%d", world))
    c.SetParameter("machine", sprintf("Zone%d", zone))
    if !c.QueryToServer(): printf "Error! %d"              @ FUN_006142c0
    c.GetToken(&tok)                                       @ FUN_00613f50  (result unused, see below)
    ~CHttpConnect (empty; ICF-folded with ShineObject::so_Gamble_ChangeCoin FUN_00417480)
    return true                                            # failures are never reported to the caller (original bug) Z10-B5

CHttpConnect::InitConnection(timeoutMs):                   @ FUN_00614200
    nError = 0; *HTMLDocument = ""; memset(UrlInfo, 0, 0xDA4)
    hInternet = InternetOpenA("HTTP_CONNECT", INTERNET_OPEN_TYPE_PRECONFIG, 0, 0, 0)  else nError = GetLastError, return 0
    InternetSetOptionA for options 2, 6, 5, 7, 8 (connect, receive, send, data-send, data-receive timeout) = timeoutMs
    return 1

CHttpConnect::MakeAddress() → sAddress:                    @ FUN_00613dd0
    (bUsePath → "/<sPath>", bUseVersion → "/<sVersion>": never set by the zone)
    "/" + sFuntion + "?" + join(parameters, "&")           # trailing "&" removed; returns NULL without a function name

CHttpConnect::QueryToServer() → int:                       @ FUN_006142c0
    bHtmlSuccess = false
    hConnection = InternetConnectA(hInternet, sServer, nPort, NULL, NULL, INTERNET_SERVICE_HTTP, 0, 0)
    hRequest = HttpOpenRequestA(hConnection, "GET", MakeAddress(), NULL /*HTTP/1.1*/, NULL, NULL, 0, 0)
    HttpSendRequestA(hRequest, no headers, no body)
    (any failure above: nError = GetLastError, return 0; the open handles are not closed: (original bug) Z10-B2)
    HttpQueryInfoA(hRequest, HTTP_QUERY_STATUS_CODE /*0x13*/, malloc(11) …)   # grown on ERROR_INSUFFICIENT_BUFFER;
                                                           # the status is never looked at and the buffer never freed (original bug) Z10-B1
    nHTMLDocumentLen = 0
    repeat:
        InternetReadFile(hRequest, chunk[256], 256, &n); chunk[n] = 0
        if nHTMLDocumentLen + n > 99999: bHtmlSuccess = false; break    # what was read so far stays (original bug) Z10-B11
        HTMLDocument.append(chunk, strlen(chunk))          # a NUL byte cuts the chunk (original bug) Z10-B11
        nHTMLDocumentLen += n; bHtmlSuccess = true
    until n == 0
    close hRequest, hConnection, hInternet; return 1
```

`CHttpConnect::GetToken` searches the body for the strings `s_token` / `s_token_secret` and copies the quoted values
into `GET_TOKEN { char sToken[128]; char sTokenSecret[128] }`; it is a leftover of a token-based (OAuth-like) client
(`CHttpConnect` also has unused `sSecret`, `sSig`, `bUseSharedSecret`, `sTokenSecret` members *(pdb2016)*), and the
zone throws the result away. The answer body itself is the HTTPString passed to the constructor.

**Wire format** of the request (WinINet adds `Host` and `User-Agent: HTTP_CONNECT`; other default headers *(inferred)*);
for `Files/Server/2016` Zone00 (`MY_SERVER "PG_W00_Z00", "_2015_Zone00", 6, 0, 0`, `NATION_NAME "EU_US_REAL"`):

```
GET /GR.php?act=boot&title=Fiesta&nation=EU_US_REAL&pw=wkdbdmldutlstkd&world=0&machine=Zone0 HTTP/1.1
Host: 127.0.0.1:58492
User-Agent: HTTP_CONNECT
```

The request carries no build version, no challenge and no nonce; the answer can be any static text. The flags `0` on
`HttpOpenRequestA` leave WinINet caching enabled (no `INTERNET_FLAG_RELOAD`) *(inferred: a cached answer could be
reused)*.

**Response:** only the body counts. The status code and all headers are ignored; the body is read up to 99 999
bytes, cut at the first NUL of each 256-byte chunk.

### 2.4 Answer format and header checks

```
"[" Interval "]" "[" MaxSkip "]" <free text up to and including the first ")}]"> <hex blocks…>
```

- `Interval` (decimal, 1…10080) and `MaxSkip` (decimal, 0…10; a negative value fails the unsigned check) go into
  `g_LuaArgument` and drive the run-time certification (§6.1, §6.2). The GamigoZR answer sends `[10000][10]`: both pass.
- The text between the brackets and `)}]` is not checked; it is a version tag (`{( USA V.0.001 )}`). Decoding starts
  right after the first `)}]`; without one, `find` returns npos and decoding starts at offset 2 (npos + 3).
- The cipher text is a sequence of hex blocks (§3.1). Whitespace and every byte below `!` between digits is skipped,
  so line breaks are free.

### 2.5 Registry keys

| Key (32-bit view) | Value | Read by | GBO.reg / Fantasy.reg (NA2016) |
|---|---|---|---|
| `HKLM\SOFTWARE\GBO` | `Natural` (REG_SZ, decimal int64) | zs_LuaFromHTML: RSA modulus N | `"126810443"` |
| `HKLM\SOFTWARE\GBO` | `Desert` (REG_SZ, decimal int64) | zs_LuaFromHTML: private exponent d | `"138127"` |
| `HKLM\SOFTWARE\GBO` | `Mountain`, `Ocean`, `Sabana` | nothing in the zone reads them by name; the script could via `fpwltmxmcheck` (§5.2, part 2), the GamigoZR script does not | `"30324"`, `"7241589632"`, `"2554545953"` (decoys? *(inferred)*) |
| `HKLM\SOFTWARE\Fantasy\Fighter` | `Insect` | the script (`fpwltmxmcheck`, §4.2): must be `Honet` or no service starts | `"Honet"` (sic) |
| `HKLM\SOFTWARE\Fantasy\Fighter` | `Bird` | the script: must be `Eagle` or no data stage runs | `"Eagle"` |

The `.reg` files write `HKEY_LOCAL_MACHINE\SOFTWARE\Wow6432Node\…`, which is the view a 32-bit process gets with
`KEY_WOW64_32KEY` on 64-bit Windows.

### 2.6 Failure paths

| Situation | What happens |
|---|---|
| no server on 127.0.0.1:58492 and cert1.fo.gamigo unreachable | each attempt: empty body → `sscanf` fails → `Interval` 0 → `Interval = 100`, `Sleep(1000)`, `   Fly`. Then `zs_ServiceThreadFunction` calls `ls_FunctionCall("tmfpemfjs")` on a `LuaScript` whose `ls_LuaObject` is still NULL (only `ls_FromString` creates a state) → `lua_getglobal(NULL, …)` dereferences NULL → access violation, the zone process dies *(inferred from the Lua 5.2.1 source)* (original bug) Z10-B6 |
| answer with a bad header (`Interval` ∉ 1…10080, or `MaxSkip` ∉ 0…10) | as above (the defaults 100 / 5 are written and never used) |
| no `HKLM\SOFTWARE\GBO` key | the encrypted text is expanded as if it were plain → Lua syntax error → `Script error`; the fallback host is tried; `ls_FromString` left a fresh Lua state, so `tmfpemfjs` is not found → `function call error`, `zs_ServiceThreadFunction` returns -3 (0xFFFFFFFD) as its thread exit code, which nobody reads: no services start, nothing listens, the Windows service stays RUNNING (§6.6, (original bug) Z10-B19) |
| `Natural` = 0 and `Desert` > 0 | 64-bit remainder by zero in `hs_Decoding` → divide-by-zero exception, crash (original bug) Z10-B4 |
| `Desert` = 0 (missing, or Z10-B3) | every block decodes to `01 00 00` → garbage → `Script error` (then as the row above) |
| wrong key values | garbage Lua → `Script error` |
| script runs but its registry check fails (`Fantasy\Fighter`) | `chrlghk` / `tmfpemfjs` only print `Bad`: nothing is loaded, no listener opens, the process idles forever with the service RUNNING (§4.3, §6.6, Z10-B19) |

The certification can therefore stop the server **at start** (no answer, wrong keys, wrong registry markers). It can
also stop a **running** server: the main loop asks for a challenge answer every `Interval` minutes and halts after
`MaxSkip + 1` failed answers in a row, and it exits the process if the script lost `xlrfunction`; a script that does not
call `dhsmfskfWk` every minute makes combat drift by 1 % per minute (§6).

## 3. Cipher

Two layers: textbook RSA on 24-bit blocks, then an LZ77-style decompressor with a 256-byte ring.

### 3.1 hs_Decoding: RSA blocks

```pseudo
HTTPString::hs_Decoding(text, N, D):                       @ FUN_00613750
    text.hs_Offset = text.find(")}]") + 3
    out = ""
    n = hs_Next(text)
    while n != -1:
        c = 0 (int64)
        repeat n times: c = c * 16 + hs_Next(text)         # n = number of hex digits of this block (one hex digit, 0…15)
        r = 1
        if D > 0: repeat D times: r = (r * c) mod N        # _allmul / _allrem: signed 64-bit, D multiplications (no square-and-multiply)
        out += byte(r), byte(r >> 8), byte(r >> 16)         # little-endian 24 bits; with D <= 0 the bytes are 01 00 00
        n = hs_Next(text)
    text = out                                             # the header is gone; hs_Offset keeps its value

HTTPString::hs_Next(text) → int:                           @ FUN_006135f0
    skip characters < '!' (spaces, CR, LF, tabs, control bytes)
    at end: hs_Offset += 1; return -1
    ch = text[hs_Offset++]
    ch < '0' → 0;  '0'…'9' → ch-'0';  ':'…'@' → 10;  'A'…'F' → ch-'A'+10;  > 'F' → 15     # lower case reads as 15
```

With the GBO.reg keys: **N = 126 810 443 = 11 113 × 11 411**, **d = 138 127**, so φ(N) = 126 787 920 and the public
exponent is **e = d⁻¹ mod φ(N) = 45 575 983** (computed; λ(N) gives the same value). Every plaintext block m < 2²⁴ <
N, every product r·c < 2⁵⁴ fits the signed 64-bit multiply. The zone needs D (138 127) multiplications per block: for
the 340 blocks of the GamigoZR answer about 47 million 64-bit mul/rem pairs at start.

An encoder (what Gamigo's `GR.php` did *(inferred)*): pad the compressed stream (§3.2) to a multiple of 3 bytes, take
each 3 bytes little-endian as m, write `c = m^e mod N` as `hex(len(H)) + H` with `H` = upper-case hex of c without
leading zeros (blocks of 5, 6 and 7 digits occur in the GamigoZR answer; `c = 0` would be `10`).

### 3.2 hs_Expand: LZ ring decompression

```pseudo
HTTPString::hs_Expand(s):                                  @ FUN_00613950
    ring[256] = all s[0]; p = 0                            # ExpandBuffer { char eb_Buffer[256]; int eb_Pointer } (pdb2016)
    out = s[0]                                             # the first byte is a raw literal and is not written to the ring
    i = 1
    while i < len(s):
        if s[i] == 0:                                      # literal token: 00 <byte>
            i += 1; out += s[i]; ring[p] = s[i]; p = (p + 1) & 0xFF
        else:                                              # copy token: <off 1…255> <len 0…255> <next byte>
            off = s[i]; n = s[i+1]; i += 2
            tmp = ExpandBuffer::eb_Get(ring, off, n)       @ FUN_006136d0: ring[(p + off + k) & 0xFF] for k = 0…n-1, read with p fixed
            tmp += s[i]
            for x in tmp: out += x; ring[p] = x; p = (p + 1) & 0xFF
        i += 1
    s = out
```

`off` is a position relative to the write pointer: `ring[(p + off) & 0xFF]` is the byte written `256 − off` steps ago
(still the fill byte `s[0]` early on). Because all `n` bytes are read before any is written, a copy cannot overlap
its own output (no run-length trick). A token cut by the end of the data reads the string terminator and one byte
beyond it (out-of-bounds read by one; an encoder must end on a token boundary). The decoded Lua text ends with a NUL
that `luaL_loadstring` stops at.

### 3.3 Test vectors (GamigoZR answer, keys of GBO.reg)

| Step | Value |
|---|---|
| first hex line after the header | `73B2CCC77269D6B77284E8AC733D962D5839326E5677672C9BCEB73CD8A7276A8` |
| block 1 | `7` digits `3B2CCC7` → c = 62 049 479 → m = c^d mod N = 1 704 237 = 0x1A012D → bytes `2D 01 1A` |
| block 2 … 4 | c = 0x269D6B7 → `0A 01 02`; 0x284E8AC → `20 00 3C`; 0x33D962D → `00 5B 00` |
| decoded stream (first 24 bytes) | `2d 01 1a 0a 01 02 20 00 3c 00 5b 00 7b 00 28 fb 01 55 00 53 00 41 f7 01` |
| expansion | `-` raw; token (1, 26, `\n`) → 26 × `-` + LF; token (1, 2, ` `) → `-- `; literals `<`, `[`, `{`, `(`; token (0xFB, 1, `U`) → ` U` … → `---------------------------\n-- <[{( USA V.0.001 )}]> --\n…` |
| totals | 2 680 hex digits in 340 blocks (305 × 7, 30 × 6, 5 × 5 digits) → 1 020 bytes → 1 257 bytes of Lua including the final NUL; SHA-256 of those 1 257 bytes `3d833a121c3a8390e57a22476ff25a8995f7a8b5cd0b8c4dfa560ddeea4675b3` |

Re-encrypting each decrypted block with e returns the original c for all 340 blocks.

### 3.4 Reference implementation (Python, tested on the GamigoZR answer)

```python
def hs_next(s, st):                      # st = [offset]
    while st[0] < len(s) and s[st[0]] < '!': st[0] += 1
    if st[0] >= len(s): st[0] += 1; return -1
    ch = ord(s[st[0]]); st[0] += 1
    if ch < 0x30: return 0
    if ch < 0x3a: return ch - 0x30
    if ch > 0x40: return 0xf if ch > 0x46 else ch - 0x37
    return 10

def hs_decoding(s, N=126810443, D=138127):
    st = [s.find(')}]') + 3]; out = bytearray(); n = hs_next(s, st)
    while n != -1:
        c = 0
        for _ in range(n): c = c * 16 + hs_next(s, st)
        r = pow(c, D, N) if D > 0 else 1         # same result as D repeated multiplications
        out += bytes([r & 0xff, (r >> 8) & 0xff, (r >> 16) & 0xff]); n = hs_next(s, st)
    return bytes(out)

def hs_expand(s):
    ring = bytearray([s[0]]) * 256; p = 0; out = bytearray(s[:1]); i = 1
    while i < len(s):
        if s[i] == 0:
            i += 1; out.append(s[i]); ring[p] = s[i]; p = (p + 1) & 0xff
        else:
            off, n = s[i], s[i + 1]; i += 2
            for x in bytes(ring[(p + k + off) & 0xff] for k in range(n)) + bytes([s[i]]):
                out.append(x); ring[p] = x; p = (p + 1) & 0xff
        i += 1
    return bytes(out)

def encrypt_block(m3: bytes, N=126810443, e=45575983):   # m3 = 3 bytes
    h = '%X' % pow(int.from_bytes(m3, 'little'), e, N); return '%X%s' % (len(h), h)
```

Usage: `script = hs_expand(hs_decoding(answer))` where `answer` is the whole body as text; decode the result as CP949.

## 4. The replacement answer: GamigoZR

### 4.1 The service (from its IL)

`Gamigo_Zone_Response_Service` (namespace and assembly; classes `Program`, `Main : ServiceBase`, `Responder`,
`ProjectInstaller`), .NET 4, service name `_GamigoZR`:

```pseudo
Program.Main:  ServiceBase.Run(new Main())
Main..cctor:   responseurl = "http://127.0.0.1:58492/"; responsestring = "<the answer, §4.2>"
Main.OnStart:  if !isRunning: ws = new Responder(SendResponse, [responseurl]); ws.Run(); isRunning = true
               else ServiceBase.Stop()            # exceptions → append "Message/StackTrace/Date" to ./ExceptionError.txt
Main.SendResponse(request) → responsestring      # the request (path, query, headers) is not looked at
Responder(prefixes, method): HttpListener with the prefixes; throws if HttpListener unsupported, prefixes empty, method null; Start()
Responder.Run: ThreadPool → while listener.IsListening: ThreadPool(handle(listener.GetContext()))
handle(ctx):   bytes = UTF8(method(ctx.Request)); ctx.Response.ContentLength64 = len(bytes)
               ctx.Response.OutputStream.Write(bytes); read and discard the request body; finally OutputStream.Close()
```

So every request to `http://127.0.0.1:58492/` (any path, any query, any method) gets `200 OK` (HttpListener default),
`Content-Length` set, no `Content-Type`, and the body below; all of it is ASCII. `Start Services.ps1` starts
`_GamigoZR` 5 s (`TIMEOUT /T 5`) before the five `_Zone0…4` services, which is all a zone needs (S01 §1.5).

### 4.2 The answer and the recovered script

Body: `[10000][10][{( USA V.0.001 )}]` LF, then 42 lines of hex (41 × 65 digits, 1 × 15) each ending in LF; 2 753
characters. Decrypted and expanded with §3 (comments are CP949 Korean; shown here as UTF-8 with translations):

```lua
---------------------------
-- <[{( USA V.0.001 )}]> --
---------------------------

-- 쓰레드 만들기                                  ("create the threads")
function tmfpemfjs()
	if fpwltmxmcheck("Fantasy\\Fighter", "Insect") == "Honet" then
		vmflsxm("Good")

		zs_service_iocp()
		zs_service_multisocket()
		zs_service_mainthread()
		zs_service_acceptor()
		zs_service_stackchecker()
		zs_service_certification()
	else
		vmflsxm("Bad")
	end
end


-- 초기화함수                                      ("initialisation function")
function chrlghk()
	if fpwltmxmcheck("Fantasy\\Fighter", "Bird") == "Eagle" then
		vmflsxm("Good")

		zs_start_sky()
		zs_start_earth()
		zs_start_black()
		zs_start_yellow()
		zs_start_home()
		zs_start_house()
		zs_start_wide()
		zs_start_tough()
		zs_start_sun()
		zs_start_moon()
		zs_start_full()
		zs_start_sink()
		zs_start_star()
		zs_start_sleep()
		zs_start_open()
		zs_start_long()

		ekfflrlthreh(127)--		runspeed 127
		rjerlthreh(33)--		walkspeed 33
	else
		vmflsxm("Bad")
	end
end


-- 매 1분마다 실행하는 함수                         ("function run every minute")
function xlrfunction()
	local year
	local month
	local date
	local hour
	local minute
	year, month, date, hour, minute = dhsmfskfWk()
	--vmflsxm("date " .. year .. " " .. month .. " " .. date .. " " .. hour .. " " .. minute)
	--vmflsxm("2. Interval " .. interval .. ", Skip " .. skip)


	-- 다른 기능 넣을 수 없을까????                    ("can't we put other features in here????")
end
```

(The original text uses tabs for indentation and ends with a NUL after the last `end`.) The function names are Korean
words typed on a QWERTY keyboard in the 2-set layout: `tmfpemfjs` = 스레드런 "thread run", `chrlghk` = 초기화
"initialise", `xlrfunction` = 틱function "tick function", `ekfflrlthreh` = 달리기속도 "run speed", `rjerlthreh` =
걷기속도 "walk speed", `vmflsxm` = 프린트 "print", `fpwltmxmcheck` = 레지스트check "registry check", `dhsmfskfWk` =
오늘날짜 "today's date" *(inferred: transliteration)*.

Whether Gamigo's own `GR.php` sent the same text is unknown: the tag `USA V.0.001`, the Korean comments and the
commented-out `Interval`/`Skip` debug line suggest the private-server author replayed a captured original answer
rather than writing one (they would have needed e, which is not in any file) *(inferred)*.

### 4.3 What the script does

1. **Chunk load** (`ls_FromString`): only defines the three globals; no code runs at top level.
2. **`chrlghk`**, called by zs_LuaFromHTML right after the load: checks `HKLM\SOFTWARE\Fantasy\Fighter` `Bird` ==
   `"Eagle"` (via `fpwltmxmcheck`, §5.2), prints `Script : Good` to Message.txt, then runs the 16 data stages in this
   order:

   `sky → earth → black → yellow → home → house → wide → tough → sun → moon → full → sink → star → sleep → open → long`

   and sets the movement factors: run speed **127**, walk speed **33** (`ekfflrlthreh` / `rjerlthreh`). These are the
   values `ChrCommon.txt` already holds, but `zs_start_long` overwrote them with 5 / 10 just before; without the script
   call players crawl (§5.4). Every registered stage is called exactly
   once; `zs_start_open` (which prints `Load end`) is not the last one: `zs_start_long` follows it.
3. **`tmfpemfjs`**, called by `zs_ServiceThreadFunction` after `zs_start_old` returned: checks `Insect` == `"Honet"`,
   prints `Good`, then starts the services:

   `iocp → multisocket → mainthread → acceptor → stackchecker → certification`
4. **`xlrfunction`** (called by the main thread once per world minute, §6.1): reads the date with `dhsmfskfWk` and does nothing else.
   The original design let Gamigo push time-based logic here (an expiry date, say); this answer has none. The call
   itself matters: `dhsmfskfWk` resets the combat factor (§6.3), and a missing `xlrfunction` exits the zone (§6.1).

A wrong marker value makes the function print `Script : Bad` and return normally: `ls_FunctionCall` still reports
success, so the zone logs `   Sun`, then idles with nothing loaded or nothing listening (§2.6).

## 5. Lua host

### 5.1 LuaScript / LuaScriptSecurity

`g_LUA_SCRIPT_SECURITY` (`LuaScriptSecurity : LuaScript`, 8 bytes: vftable + `lua_State* ls_LuaObject`) at
DAT_14d6fdf0, constructed by `_dynamic_initializer_for__g_LUA_SCRIPT_SECURITY__` FUN_0069b7c0 (`LuaScript::LuaScript`
FUN_005d6000 sets `ls_LuaObject = NULL`, then the vftable is switched to `LuaScriptSecurity::vftable` 0x0070466C:
slot 0 the deleting destructor FUN_00613f20, slot 1 `ls_FuncSet` FUN_005d7ca0). The embedded Lua is 5.2.1
(`$LuaVersion: Lua 5.2.1` string).

```pseudo
LuaScript::ls_FromString(L, text) → bool:                  @ FUN_005d6d40
    if L.ls_LuaObject: lua_close(it)
    L.ls_LuaObject = luaL_newstate(); luaL_openlibs(it)     # full standard library: io, os, package, debug … (original bug) Z10-B10
    if luaL_loadstring(text) != 0: return false            # syntax error
    if lua_pcallk(0 args, 0 results) != 0: return false    # error while running the chunk
    return L.vftable[1]()                                  # LuaScriptSecurity::ls_FuncSet: registers the C functions (§5.2)

LuaScript::ls_FunctionCall(L, name, arg) → bool:           @ FUN_005d7bc0
    lua_getglobal(L.ls_LuaObject, name)                    # NULL state → crash (original bug) Z10-B6
    nargs = arg.vftable[1](state)                           # push arguments; lsa_NoLuaArgument pushes none
    nres  = arg.vftable[3]()
    ok = lua_pcallk(state, nargs, nres, 0, 0, NULL) == 0
    if ok: arg.vftable[2](state)                            # read the results
    return ok
```

The C functions are registered **after** the chunk ran, so top-level code in the script cannot call them; only the
three functions it defines can, and only when the zone calls them. A rebuilt script cannot rely on calling stages
at load time.

### 5.2 Registered C functions (`LuaScriptSecurity::ls_FuncSet` FUN_005d7ca0)

Registered in this order with `lua_pushcclosure(f, 0)` + `lua_setglobal`; this is the **whole** C surface of the script
(no other `lua_setglobal`, no userdata, no C global is exported). Every function ignores surplus arguments; the
"returns" column is the number of Lua results. All run on the thread that called into Lua: `chrlghk` on the service
thread, `tmfpemfjs` on the service thread, `xlrfunction` on the main thread (§6.1).

| Lua name | C function | Arguments | Returns | Effect |
|---|---|---|---|---|
| `vmflsxm` | `cpp_Print` FUN_005d5c70 | text | 0 | `sprintf(buf[256], "Script : %s", text)` and append it as one line to `Message.txt` (unbounded: (original bug) Z10-B17) |
| `fpwltmxmcheck` | `cpp_RegCheck` FUN_005d5ce0 | subkey, value name | 1 string | `RegOpenKeyExA(HKLM, "SOFTWARE\\" + subkey, KEY_QUERY_VALUE \| KEY_WOW64_32KEY)`, `RegQueryValueExA(value)` into a 255-byte buffer with size 256; the buffer as a string. Missing key or value → uninitialised stack bytes are returned (original bug) Z10-B16 |
| `dhsmfskfWk` | `cpp_CurrentTime` FUN_005d5e10 | none | 5 numbers | first: if `!lsf_IsFreeze && lsf_IsRecover`: `lsf_Factor = 1.0` (§6.3). Then pushes `chargeditemcheck.ct_Current` (DAT_00aa43b8, the world time of the last per-minute block, Z09 §1.2): year **−2000** (two digits: 16 for 2016), month 1–12, day, hour, minute |
| `zs_service_multisocket` | FUN_00570b00 | none | 0 | nothing: an empty function, ICF-folded with `CGambleObject::GDTSO_GetGameStatus` (returns 0 in EAX, read as "0 results") |
| `zs_service_acceptor` | LAB_005aa7c0 (`ZoneServer_zs_service_acceptor`) | none | 0 | `zs_Start_Acceptor` FUN_005a9c60 (§6.5); false → `ac_AssertFail "ZoneServer::zs_servicestart : Acceptor fail"` + `ShineExit` |
| `zs_service_mainthread` | LAB_005ad780 | none | 0 | start `zs_mainthreadfunction` (§6.1); failure → `MainThread fail` + `ShineExit` |
| `zs_service_iocp` | FUN_005aa800 | none | 0 | `CIOCP::Start(zs_IOCP, 2 × CPUs + 1 workers, wait = 1)` FUN_006505f0; result ignored |
| `zs_service_stackchecker` | LAB_005ab800 | none | 0 | start `zs_stackcheckfunc` (§6.4); failure → `StackCheck fail` + `ShineExit` |
| `zs_service_certification` | LAB_005ac9b0 | none | 0 | start `zs_certification` (§6.2); failure → `Certification fail` + `ShineExit` |
| `zs_start_moon` … `zs_start_sun` (16) | Z01-core §2.2 | none | 0 | the data stages (§7, part 3); `zs_start_long` FUN_005b8c00 also resets the speed factors to 5 / 10 (§5.4) |
| `ekfflrlthreh` | `Parameter_RunSpeed` FUN_005ad890 | number | 0 | `shineparam.scp_param.chrrunspeed = (ulong) round(n)` (DAT_0da50470); no range check |
| `rjerlthreh` | `Parameter_WalkSpeed` FUN_005ad8d0 | number | 0 | `shineparam.scp_param.chrwalkspeed = (ulong) round(n)` (DAT_0da50474) |

Every name is a plain Lua global, so `xlrfunction` (or any function the script defines) could call any of them again
at run time: a second `zs_start_*` reloads tables under a running world, a second `zs_service_*` starts another
thread. Nothing prevents it; the GamigoZR script does not do it. Beyond these, the script has the full Lua standard
library (Z10-B10), so it can read and write files, environment and processes, but it has **no access to zone
memory** other than through this table.

### 5.3 Shared state

| Global | Address | Type *(pdb2016)* | Set by | Used by |
|---|---|---|---|---|
| `g_LuaArgument` | DAT_14d6fcd8 | `LuaArgument { int Count +0; int Interval +4; int MaxSkip +8; int Summary +0xC; int SkipNumber +0x10; int CertifyArg +0x14 }` | zs_start_old (SkipNumber, Summary, CertifyArg = 0), zs_LuaFromHTML (Count = 0; Interval, MaxSkip from the header), main thread (Summary, CertifyArg), certification thread (Interval, MaxSkip, SkipNumber, Count, CertifyArg = 0) | §6.1 / §6.2; `Count` is written only (number of certification rounds) |
| `g_LUA_SCRIPT_SECURITY` | DAT_14d6fdf0 | `LuaScriptSecurity` | §5.1 | zs_LuaFromHTML, zs_ServiceThreadFunction, main thread (`xlrfunction`) |
| `g_LUA_SCRIPT_SECURITYFactor` | DAT_00870dd8 | `LuaScriptFactor { double lsf_Factor +0; bool lsf_IsFreeze +8; bool lsf_IsRecover +9 }` (0x10 bytes; static data `1.0, false, true`) | main thread (× 1.01 per minute unless frozen), `dhsmfskfWk` (reset to 1.0), `&mobdamage` (§6.3) | hit rate and damage (§6.3); Z03 calls it `g_HitRateScale` |
| `shineparam.scp_param` | DAT_0da50470… | `ShineCommonParameter::ShineParameter` (`chrrunspeed` +0, `chrwalkspeed` +4, `chrattackspeed` +8, `shoutlevel` +0xC, `shoutdelay` +0x10, …) | `scp_Load` (ChrCommon.txt, in `zs_start_house`), `zs_start_long`, the two script setters | §5.4 |

### 5.4 Movement speed factors and the 0x0830 server parameters

`ShineCommonParameter::scp_Load` FUN_004c9be0 (called by `zs_start_house`) reads `../9Data/Shine/World/<world>/ChrCommon.txt`
(fallback `../9Data/Shine/World/ChrCommon.txt`; neither readable → `ShineExit`), table `Common`, `key` → `argument`.
2016 file: `RunSpeed 127`, `WalkSpeed 33`, `AttackSpeed 13`, `ShoutLevel 5` ("USA 5, others 0"), `ShoutDelay 2`,
`LevelLimit 125`, `MaxExpBonus 3000`, the rest-exp/buff times and the free-stat tables (those belong to Z05 / Z03).

```pseudo
zs_start_house → scp_Load:   chrrunspeed = 127, chrwalkspeed = 33, chrattackspeed = 13, shoutlevel = 5, shoutdelay = 2
zs_start_long  (FUN_005b8c00, first two statements):   chrrunspeed = 5; chrwalkspeed = 10
script chrlghk, after zs_start_long:   ekfflrlthreh(127); rjerlthreh(33)          # back to the file values
```

So the stage functions alone leave the speeds at 5 / 10: a zone started without the script, or with a script that
skips the two calls, moves every player at 5/127 of the run speed *(inferred: a deliberate trap for a bypassed
certification; the write in `zs_start_long` serves no other purpose)*. Readers:

```pseudo
ShinePlayer::so_RunSpeed  → u16:   @ FUN_005599c0   (vt 0x518)
    if script override (vt 0xe88): return vt 0xe90()
    base = riding (vt 0x484 == 6) ? sp_RideCast.runspd : smo_Param.Total.MoveSpeed (p+0x1c00, ‰ rate)
    return max(0, (s16)(base × chrrunspeed / 1000))
ShinePlayer::so_WalkSpeed → u16:   @ FUN_00559960   (vt 0x514)
    if override (vt 0xe84): return vt 0xe8c()
    base as above (sp_RideCast.walkspd when riding)
    return (base × chrwalkspeed / 1000) & 0xFF        # 8-bit: a walk speed ≥ 256 wraps (base > 7 757 ‰ with 33)
ShineMover::so_RunSpeed / so_WalkSpeed:   @ FUN_0055ec40 / FUN_0055eb20   (mounts and movers, Z07 / Z09 §17)
    (MoverMain.RunSpeed|WalkSpeed + upgrade bonus + owner's (+0xc40) − 1000) × (s16) chrrunspeed|chrwalkspeed / 1000 × mover rate / 1000
```

Both values reach the client in `0x203E NC_ACT_MOVESPEED_CMD { u16 walkSpeed, u16 runSpeed }`
(`ShinePlayer::so_SendSpeedInformation` FUN_00459540, Z02 §2.2) and are used by the server's own movement checks. The
setters do not resend 0x203E; changing them at run time (from `xlrfunction`) would only reach a player on the next
speed update *(inferred)*. `chrattackspeed` and `shoutlevel` / `shoutdelay` are not touched by the script: the 0x0830
`NC_MISC_SERVERPARAMETER_ACK { u8 shoutlevel, u16 shoutdelay }` (Z01-core §9, `sp_NC_MISC_SERVERPARAMETER_REQ`
FUN_005517c0) sends the `ChrCommon.txt` values 5 / 2, and `sp_NC_ACT_SHOUT_CMD` FUN_00458e80 (Z02) uses them as the
shout level bound and the delay (`shoutdelay × 10` ticks = seconds). This answers Z01-core's open question: the
writer of DAT_0da5047c / DAT_0da50480 is `scp_Load`.

## 6. Threads and the run-time certification

`ZoneServer` *(pdb2016)* has four thread blocks of 0x10 bytes `{ u8 activ; u8 stop; HANDLE handle; ulong id; ulong
looping }`: `zs_mainthread` +0x00, `zs_stackcheck` +0x10, `zs_ServiceThread` +0x20, `zs_Certify` +0x30. Every thread
gets the `ZoneServer*` as its argument. The three `zs_service_*` starters share one pattern:

```pseudo
zs_service_mainthread / stackchecker / certification:     @ LAB_005ad780 / LAB_005ab800 / LAB_005ac9b0
    block.activ = 0; block.stop = 0
    block.handle = CreateThread(threadfunc, g_ZoneServer, &idSlot)   # idSlot: mainthread → zs_mainthread.id (+8);
                                                                     # stackchecker AND certification → zs_stackcheck.id (+0x18) (original bug) Z10-B14
    if handle: wait (Sleep 5) until block.activ == 1; ok
    else: ac_AssertFail "ZoneServer::zs_servicestart : <MainThread|StackCheck|Certification> fail"; ShineExit("ZoneServer_zs_service_<name>")
```

`ShineExit(name)` FUN_0063c7c0 appends `"<hh:mm:ss> : AssertClass::ac_AssertFail : <name>"` to
`ExitLog<YYYYMMDD><HH>.txt` (local time) and calls `exit(0)`: the whole process ends.

### 6.1 Main thread: the per-minute certification counter

`ZoneServer::zs_mainthreadfunction` FUN_005aca30 is the zone's game loop (Z09 §1.1 documents it). Its per-minute block
(once per world-time minute, i.e. per WM `0x0821` time message whose minute differs, Z09 §1.2) holds the certification
logic, in this order:

```pseudo
PerMinute (certification part):                            @ FUN_005aca30
    if g_LuaArgument.MaxSkip < g_LuaArgument.SkipNumber:
        zs_mainthread.stop = 1                             # THE KILL SWITCH: the loop ends at its next turn (§6.6)
    else:
        Summary += 1
        if Summary >= Interval:
            repeat: CertifyArg = rndbox.rb_box[100].next() − 50     # ring of values 0…99 (Z09 §8) → −50…49
            until CertifyArg != 0
            Summary = 0                                    # the certification thread picks the challenge up (§6.2)
    … (rest of the minute block: Z09 §1.2)
    if !g_LUA_SCRIPT_SECURITYFactor.lsf_IsFreeze:
        lsf_Factor *= 1.01                                 # constant 0x3FF028F5C28F5C29
    if !ls_FunctionCall(g_LUA_SCRIPT_SECURITY, "xlrfunction", no arguments):
        ac_AssertFail "ZoneServer::zs_mainthreadfunction : function call error"
        ShineExit("ZoneServer::zs_mainthreadfunction")     # process exits
```

With the GamigoZR header (`Interval` 10000, `MaxSkip` 10) the first challenge comes after 10 000 world minutes
(6 d 22 h 40 min) of main-loop time, the next 10 000 minutes after that, and so on. While the WM link is down no
minute passes, so nothing is counted.

### 6.2 Certification thread

```pseudo
ZoneServer::zs_certification(server):                      @ FUN_005ab9c0  (thread, zs_Certify block)
    zs_Certify.activ = 1; zs_Certify.looping = 0
    loop:
        if g_LuaArgument.CertifyArg != 0:
            x = CertifyArg
            expected = ((2x − 3)·x + 5)·x − 7              # = 2x³ − 3x² + 5x − 7, int32
            # one attempt at the local host (loop "for i = 0; i < 1"):
            nation = GetNationName(); text = HTTPString()
            hs_HTMMRead(text, "127.0.0.1", 58492, act = sprintf("%d", x), myserver.nWorldNo, myserver.nZoneNo, nation)   (§2.3)
            sscanf(text, "[%d][%d]%d", &interval, &maxskip, &answer)          # locals never initialised (original bug) Z10-B12
            if interval > 0 and maxskip > 0 and answer == expected:          # no upper bounds here (original bug) Z10-B13
                Interval = interval; MaxSkip = maxskip; ok = true
            else:
                ok = zs_CertifyRoutine("cert1.fo.gamigo", 80)                 @ FUN_005ab880 (same request and check, one attempt)
            SkipNumber = ok ? 0 : SkipNumber + 1
            Count += 1
            CertifyArg = 0
        Sleep(10000)
        if zs_Certify.stop: zs_Certify.activ = 0; return 0  # stop is never set by anything: the thread runs until the process ends
```

The request is the boot request of §2.3 with `act=<challenge>` instead of `act=boot`, e.g. for challenge 17:

```
GET /GR.php?act=17&title=Fiesta&nation=EU_US_REAL&pw=wkdbdmldutlstkd&world=0&machine=Zone0 HTTP/1.1
→ expected body: "[<Interval>][<MaxSkip>]9037"   (anything may follow the number)
```

Test vectors for `expected`: x = 1 → −3; x = −1 → −17; x = 17 → 9037; x = 49 → 228333; x = −50 → −257757. The
answer is unencrypted, the "secret" is the polynomial; `Interval` and `MaxSkip` of a good answer replace the boot
values, so the certification server can retune or shorten the period at run time. HTTP status and headers are ignored
as at boot (Z10-B1). No log line is written for a failed round.

### 6.3 The combat factor `lsf_Factor`

| Who | What *(pdb2016 names)* |
|---|---|
| main thread, per minute (§6.1) | `lsf_Factor *= 1.01` unless `lsf_IsFreeze` |
| `dhsmfskfWk` (cpp_CurrentTime, §5.2) | `lsf_Factor = 1.0` if `!lsf_IsFreeze && lsf_IsRecover` |
| `&mobdamage <freeze> <recover> <factor>` (`AmpersandCommand::ac_mobdamage` FUN_0041d460 → `ShineMob::sm_DamageSet` FUN_0055e5f0; GM command, Z11) | `lsf_IsFreeze = freeze is 'Y'/'y'`; `lsf_IsRecover = recover is not 'N'/'n'`; if factor given and `> 0` (`%lg`): `lsf_Factor = factor`; replies `"%g"` of the factor to the GM (vt 0x784) |
| `ShineMobileObject::smo_SwingDamage` FUN_00432f30 (Z03 §4.3, "g_HitRateScale") | hit chance: `RulesOfNormalAttack.HitRate × lsf_Factor ≥ rand(1000)` → hit, for every attacker |
| `RulesOfEngagement::roe_CalcDamage` FUN_00505c00 (Z03 §4.5) | damage `/ lsf_Factor` when the attacker is a player (vt 0x4d0 == 2), `× lsf_Factor` otherwise |

Start value (static data at DAT_00870dd8): `1.0`, not frozen, recover on. The growth and the reset happen in the same
main-loop tick (`×1.01`, then `xlrfunction` → `dhsmfskfWk` → `1.0`), and combat runs on the same thread, so with the
GamigoZR script the factor is always exactly 1.0 when damage is computed. If the script's `xlrfunction` does **not**
call `dhsmfskfWk` (a hand-written replacement script, say), the factor compounds: ×2 after 70 minutes, ×1.7·10⁶
after a day, `+inf` after about 71 300 minutes (49.5 days). Long before that every swing hits and players' damage
falls towards 0 while mob damage explodes. This is a hidden, delayed degradation for a tampered script *(inferred
intent)*; it never stops the process.

### 6.4 Stack checker thread (watchdog)

```pseudo
ZoneServer::zs_stackcheckfunc(server):                     @ FUN_005a9f10  (thread, zs_stackcheck block)
    zs_stackcheck.activ = 1; zs_stackcheck.looping = 0
    do:
        now = zs_mainthread.looping                        # incremented once per main-loop turn (Z09 §1.1)
        if zs_stackcheck.looping == now:                   # main loop did not advance in 10 s
            FunctionCallingAnalyzer::fca_printf(&funcallanalizer, "ShineStackStruct")   @ FUN_00467930
        zs_stackcheck.looping = now
        Sleep(10000)
    while !zs_stackcheck.stop                              # never set: runs until the process ends
    zs_stackcheck.activ = 0
```

`fca_printf(prefix)` creates (mode `"w"`) `<prefix><YYYYMMDDHH>.txt` (world-adjusted time `mysecond`), e.g.
`ShineStackStruct2016111412.txt`, writes the prefix, 64 lines `"%d/%d"` (the ring `fca_NetCommand[64]` of the last
handled opcodes, dept/cmd *(inferred from the type)*) and every non-NULL entry of `fca_stack[128]` (the profiler's
function-name stack, filled by the `pr_Entrance` prologues) as `"%c %s[%u]"`. So a hung main loop leaves, every 10 s,
the name of the function it is stuck in; within one hour the file is overwritten. It is purely diagnostic: no restart,
no exit. It is unrelated to certification apart from being started by the script.

### 6.5 The other service stages

```pseudo
zs_service_iocp:   CIOCP::Start(zs_IOCP, n = 2·dwNumberOfProcessors + 1, wait = 1)      @ FUN_005aa800 → FUN_006505f0
    create the completion port once; Stop(-1) old workers; n worker threads CIOCP::WorkThread (Sleep 50 ms after each);
    wait until every worker left status 1; m_NumOfWorkThread = n         # worker body: network core, §8 boundary
zs_service_multisocket:   no-op                                                          @ FUN_00570b00
zs_service_acceptor → ZoneServer::zs_Start_Acceptor:                                     @ LAB_005aa7c0 → FUN_005a9c60
    row = ServerInfo entry (myserver.nServerID, nWorldNo, nZoneNo, type 0x14 = client listen)
          else AssertFail "zs_Start_Acceptor : No data for client listen" → false
    ClientSessionManager::InitSessions(zs_clientsessionmanager, row.nMaxAccept)  else "Init session fail" → false
    CSocket_Acceptor::Listen_Start(zs_Acceptor)                                    else "Listen Start fail" → false
    for every ServerInfo entry with this server's (nServerID, nWorldNo, nZoneNo):
        Listen_Add(zs_Acceptor, pIP, nPort, nServerIDFrom, nBackLog)               else "Listen fail" → false
    true                                   # false → "Acceptor fail" + ShineExit (§6)
```

The script order (§4.3) starts the IOCP before the acceptor and the main thread before the acceptor; the two
watchdog threads come last.

### 6.6 What happens when the certification fails at run time

```
minute k·Interval:  challenge → 127.0.0.1:58492 → cert1.fo.gamigo:80 → both wrong → SkipNumber += 1
… after MaxSkip + 1 consecutive failures, at the next minute:  zs_mainthread.stop = 1
```

- The main loop finishes its turn, sets `zs_mainthread.activ = 0` and returns.
- `zs_ServiceThreadFunction` FUN_005a9d90, which polls `zs_mainthread.activ` every second, sees 0, sets `stop`, waits
  for `activ == 0` and returns 0. Its return value goes nowhere (thread exit code).
- `WinService::serviceLoop` FUN_00653480 is not told: it waits only for SCM stop/shutdown controls (1, 5), so the
  service stays **RUNNING**, the process stays alive, and the IOCP workers, the listeners, the stack checker (now
  writing a `ShineStackStruct` file every 10 s) and the certification thread keep running. Clients can still connect,
  but no packet is processed, no DB / WM / log traffic is handled. Nothing is written to `Message.txt` or an ExitLog
  (original bug) Z10-B15.
- A later SCM stop runs `OnStop_Service` FUN_0049dc10 → `zs_serviceend` FUN_005a9930 (set `zs_mainthread.stop`, wait
  for `activ == 0`: already 0) → service STOPPED.

**With GamigoZR** the run-time certification always fails: the service answers every request with the boot text
`[10000][10][{( USA V.0.001 )}]…`, whose third field is `[`, so `%d` does not convert and `answer` keeps an
uninitialised stack value (practically never equal to the challenge) *(inferred: stack contents)*; `cert1.fo.gamigo`
does not resolve. So `SkipNumber` reaches 11 at minute 110 000 and the zone's game loop halts at minute 110 001 of
world time after the main thread started: **about 76 days 9 hours of uptime** *(inferred: no capture; S01 §1.3 shows
the NA2016 hook patches do not touch this code)*. A shorter-lived private server (restarted at least every 11 weeks)
never notices. A rebuilt certification answer must return `[I][M]<2x³−3x²+5x−7>` for `act=<x>`, or a rebuild drops the
mechanism (part 3 recommendation).

**Summary of what the certification can do to a running zone:** halt the game loop (failed challenges, above);
exit the process (`xlrfunction` missing or failing: `ShineExit`); retune its own period (`Interval`, `MaxSkip` of a
good answer); and, through the script, degrade combat (§6.3) or slow movement (§5.4). It never sends a packet, never
logs a failed round and has no expiry date in the code: the only date reader is the script's `dhsmfskfWk`.

## 7. Start stages and their order (part 3)

*To be written in part 3: what each stage needs from the earlier ones, checked against the script order of §4.3.*

## Original-server bugs

(Rows added per part; the sweep part completes the table.)

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z10-B1 | CHttpConnect::QueryToServer FUN_006142c0 | queries `HTTP_QUERY_STATUS_CODE` into a `malloc` buffer, never checks it, never frees it | any body is accepted (a 404/500 page is decoded as a script and fails as `Script error`); 11+ bytes leaked per fetch | refuse non-200 answers; free the buffer |
| Z10-B2 | CHttpConnect::QueryToServer FUN_006142c0 | on `InternetConnectA` / `HttpOpenRequestA` / `HttpSendRequestA` failure returns 0 without closing the handles already opened | WinINet handles leak (at most 2 fetches per start, so harmless in practice) | close the handles on every path |
| Z10-B3 | ZoneServer::zs_LuaFromHTML FUN_005b07a0 | the `RegQueryValueExA` size variable (in/out) is not reset between `Natural` and `Desert` | if `Desert`'s string (with NUL) is longer than `Natural`'s, the second query fails with `ERROR_MORE_DATA`, D stays 0 and the script decodes to garbage (GBO.reg: 10 vs 7 bytes, works) | reset the size to 256 before each query |
| Z10-B4 | zs_LuaFromHTML / HTTPString::hs_Decoding FUN_00613750 | a zero key only logs `   Code`; decoding runs anyway | `Natural` = 0 with `Desert` > 0: 64-bit remainder by zero → divide-by-zero exception, the zone crashes | abort the start with a clear error |
| Z10-B5 | HTTPString::hs_HTMMRead FUN_00613440 | always returns true; connection errors only go to `printf("Error! %d")` | a Windows service has no console: a failed fetch leaves no trace except `   Fly` in Message.txt | return the error and log it |
| Z10-B6 | ZoneServer::zs_ServiceThreadFunction FUN_005a9d90 / LuaScript::ls_FunctionCall FUN_005d7bc0 | calls `tmfpemfjs` even when no script was ever loaded; `ls_LuaObject` is still NULL | `lua_getglobal(NULL, …)`: access violation, the zone dies without a message when no certification server answers *(crash inferred from the Lua 5.2.1 source)* | check the result of `zs_start_old` and stop cleanly |
| Z10-B7 | zs_LuaFromHTML FUN_005b07a0 | on a bad header writes `Interval = 100` or `MaxSkip = 5`, then abandons the attempt | dead stores: the defaults are never used | either start with the defaults or drop them |
| Z10-B8 | zs_LuaFromHTML FUN_005b07a0 | retry loop with counter `0`, `++`, `if counter > 0 return false` | exactly one attempt per host (plus a 1 s sleep); the loop never repeats | several retries (e.g. `counter > N`) |
| Z10-B9 | zs_LuaFromHTML FUN_005b07a0 | if `HKLM\SOFTWARE\GBO` cannot be opened, decryption is skipped silently and the hex text is run as Lua | `Script error` with no hint that the key is missing | log the missing key and stop |
| Z10-B10 | LuaScript::ls_FromString FUN_005d6d40 | `luaL_openlibs` on a state that runs text received over plain, unauthenticated HTTP | anyone who answers on 127.0.0.1:58492 (or poses as `cert1.fo.gamigo`) and knows e and N can run `os.execute` / `io` code inside the zone; the RSA layer is only obfuscation (N factors at once) | open only the base library; authenticate the answer |
| Z10-B11 | CHttpConnect::QueryToServer FUN_006142c0 | appends each chunk with `strlen` (cut at a NUL) but adds the full chunk size to `nHTMLDocumentLen`; past 99 999 bytes stops reading but keeps the partial body and returns success | a body with a NUL or over 99 999 bytes is silently truncated | reject or read binary-safe |
| Z10-B12 | ZoneServer::zs_certification FUN_005ab9c0 / zs_CertifyRoutine FUN_005ab880 | `sscanf("[%d][%d]%d")` into locals that are never initialised; the result count is not checked | a short or empty answer is compared with stale stack values (the frame of the thread lives forever, so the same garbage each round); a false pass is possible in principle | initialise the locals and require `sscanf(...) == 3` |
| Z10-B13 | zs_certification / zs_CertifyRoutine | the run-time answer only needs `Interval > 0` and `MaxSkip > 0`; boot (§2.2) requires `1 ≤ Interval ≤ 10080` and `0 ≤ MaxSkip ≤ 10` | a run-time answer can set any period (e.g. 2³¹−1 minutes: certification effectively off) or any skip count; `MaxSkip = 0` is valid at boot but refused at run time | one shared range check |
| Z10-B14 | zs_service_certification LAB_005ac9b0 | `CreateThread(…, &zs_stackcheck.id)` (+0x18) instead of `&zs_Certify.id` (+0x38) | the stack checker's thread id is overwritten, `zs_Certify.id` stays 0; nothing reads either *(inferred: no reader in the decompiled code)* | pass `&zs_Certify.id` |
| Z10-B15 | ZoneServer::zs_mainthreadfunction FUN_005aca30 (kill switch) | after `MaxSkip + 1` failed certification rounds sets `zs_mainthread.stop`, logging nothing; only the game loop ends | the process and the Windows service keep RUNNING, sockets accept clients, nothing is processed: a silent zombie zone (with GamigoZR after ≈ 76 days, §6.6) | log the reason and stop the service (or `ShineExit`) |
| Z10-B16 | cpp_RegCheck FUN_005d5ce0 (`fpwltmxmcheck`) | value buffer 255 bytes but `cbData = 256`; on a missing key or value (or a non-string value) the buffer is returned uninitialised; no NUL guaranteed | 1-byte stack overflow for a 256-byte value; a missing marker yields random bytes instead of `""` (the comparison in the script still fails, so the effect is only "Bad") | size 255 / zero the buffer first |
| Z10-B17 | cpp_Print FUN_005d5c70 (`vmflsxm`) | `sprintf(buf[256], "Script : %s", text)` with no length limit; the `fopen` result is not checked | text > 246 characters overflows the stack; a non-writable Message.txt → `fprintf(NULL)` crash | `snprintf`; check the file |
| Z10-B18 | g_LuaArgument (main thread ↔ certification thread) | `CertifyArg`, `Interval`, `MaxSkip`, `SkipNumber` are shared by two threads without a lock; the certification thread clears `CertifyArg` after its round | a challenge set by the main thread during a running round is wiped: that round is lost (no failure counted, next challenge only after another `Interval`) | hand over the challenge atomically (interlocked exchange) |
| Z10-B19 | ZoneServer::zs_ServiceThreadFunction FUN_005a9d90 / WinService::serviceLoop FUN_00653480 | when `tmfpemfjs` fails (returns -3) or did not start the main thread (`Bad`), the service thread just ends; the service status was already set RUNNING by `onServiceStart` | an unusable zone shows as running in the service manager, with no hint beyond Message.txt | report SERVICE_STOPPED with an exit code |
