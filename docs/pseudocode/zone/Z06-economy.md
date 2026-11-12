# Zone: trade, street booths, gambling, dice (Z06)

Source: `Files/Server/2016/w00_Zone00/5ZoneServer2.exe`, export `re-data/exports/zone`. Read any function with
`python3 -I tools/protocol-re/clean.py re-data/exports/zone tools/protocol-re/names/zone <addr>`; names from this item are in
`tools/protocol-re/names/zone/Z06.json`, verified layouts in `docs/protocol/annotations/Z06.json`. Where the decompiler dropped
call arguments (booth OPEN, several gamble handlers) the values were read from the disassembly (`objdump -d --x86-asm-syntax=intel
--start-address=… Files/Server/2016/w00_Zone00/5ZoneServer2.exe`). Client error texts come from the client's own switch over the
code (decoded jump tables, `client FUN_…`), not from `client-error-codes.json` (these departments have their own text tables).

Evidence markers as in `CLAUDE.md`: *(pdb2017)*, *(db-backup)*, *(inferred)*; plain = read in the 2016 code. No capture covers
these departments.

Conventions used below: `p` = the requesting ShinePlayer; `p ← 0xNNNN {…}` = packet to p; `so_SendErrorCode(dept, cmd, code)`
(`vt 0x308`) sends `{u16 code}` with opcode `dept<<10|cmd`; `so_SendProtocol(dept, cmd)` (`vt 0x304`) sends an empty packet;
`L` = the player's InventoryLocking (`vt 0x7d4`, Z04 §1.4 / Z05 §1); `mode` = `*(p+0xe9c)` (Z01 §4.3). Every handler first tests
the mode against a static mask; the mask is named per handler. `g_Now` counts tenths of a second (Z02 knowledge).

---

## 1. Player-to-player trade (dept 19 `NC_TRADE_*`)

### 1.1 State

Trade block at `p+0x17d4c` (`vt 0x31c` returns its address):

| Offset | Field *(names ours)* | Meaning |
|---|---|---|
| +0x00 (p+0x17d4c) | u16 proposeeHandle | the player I proposed to (0xFFFF = none) |
| +0x02 (p+0x17d4e) | u32 proposeeCharNo | |
| +0x06 (p+0x17d52) | u16 proposerHandle | the player who proposed to me |
| +0x08 (p+0x17d54) | u32 proposerCharNo | |
| +0x0c (p+0x17d58) | u32 proposeTimer | `g_Now` value; see `so_tradepropose_timecheck` |
| +0x10 (p+0x17d5c) | u16 tradeLock | lock index reserved at the proposal; the board's cell locks live under it |
| +0x12 (p+0x17d5e) | u8 tradeCommitted | set to 1 after the DB request (`vt 0x328(1)`), read by `vt 0x324`; cleared by the reset |
| +0x13 (p+0x17d5f) | **TradeBoard** | `vt 0x320` returns its address |

TradeBoard (`p+0x17d5f`): `+0 ShinePlayer* partner` (non-zero = trade window open), `+4 u8 locked` (p+0x17d63), `+5 u8 decided`
(p+0x17d64), `+6 u8 slot[12]` (inventory slot per board slot, 0xFF = empty), `+0x12 u64 cen` (p+0x17d71/75).
`TradeBoard_tb_Clear` FUN_00593600 empties slots and money; `tb_OnBoard` FUN_00595170 puts an inventory slot into the first free
board slot (returns the board slot or −1 when all 12 are used); `tb_OffBoard` FUN_00594dd0 empties one (−1 if `≥12` or already empty,
log "Down empty"); `tb_Get` FUN_00593c60, `tb_Home` FUN_00593fe0 / `tb_Next` FUN_00593ce0 iterate the used slots.

Helpers:

```pseudo
TradeReset(p)  = vt 0x628 @ FUN_00559eb0 (ours: ShinePlayer_TradeReset)
    proposee = proposer = 0xFFFF / −1; board.partner = 0; proposeTimer = 0; tradeCommitted = 0 (vt 0x328(0))
TradeBegin(p, partner) = vt 0x62c @ FUN_00559e80
    tb_Clear(board); board.partner = partner; board.locked = board.decided = 0
so_CloseTradeMenu(p)   @ FUN_005924c0
    L.vt[0x28](tradeLock)               # free every reservation under the trade lock (board cell locks)
    TradeReset(p); MenuOpenClear(2)     # open-menu kind 2 (trade AND street booth, see §2.1)
sp_tradebreak(p)       @ FUN_005931d0
    if board.partner: so_CloseTradeMenu(p); p ← 0x4C0C; so_CloseTradeMenu(partner); partner ← 0x4C0C NC_TRADE_CANCEL_CMD
so_tradepropose_timecheck(p) = vt 0x630 @ FUN_005930d0
    if board.partner ≠ 0: return false                       # already trading
    if proposeTimer < g_Now: so_CloseTradeMenu(p); proposeTimer = g_Now + 600 (60 s)
    return true
BoardUnlock(other, mover) = vt 0x7d0 @ FUN_00593670 (ours: ShinePlayer_TradeBoardUnlock)
    if other.board.locked: other.board.locked = 0; other ← 0x4C1D NC_TRADE_BOARDUNLOCK_CMD; mover ← 0x4C1E NC_TRADE_OPPOSITBOARDUNLOCK_CMD
```

Every board change (up/down/money) calls `partner.vt[0x7d0](p)`: the **partner's** lock is undone and both sides are told.
The changer's own lock is not touched (it cannot change a locked board anyway).

Who breaks a trade from outside: `so_CloseByLink` (`vt 0x310`, FUN_005934b0: `sp_tradebreak`, `sp_partylogout`, `sp_CloseStreetBooth`),
the four layer-move entries `vt 0xdbc/0xdc0/0xdc8/0xdcc` (FUN_0054ab90 / FUN_0054ac70 / FUN_0054ad30 / FUN_0054ae10: tradebreak,
close booth, CancelOnAction, riding off, then the move; callers: GM `&`-command handlers FUN_00419930 / FUN_00419970 (Z11) and
`cMoveLayer` FUN_005e7c90 (Z09/Z14)). `sp_ReviveReqProcess` and `so_LinkTo` call `so_CloseTradeMenu` (without telling the partner).

Open-menu kinds (`DuplicatedMenuControl`, `p+0x18248`, matrix DAT_00754380, 7 × 7): kind 2 (trade/booth) can be opened only while
kinds 0–3 and 6 are closed; kinds 4 and 5 may stay open. (Kinds 0 shop/menu, 1 storage per Z02 §6.1; 3 and 6 not identified.)

Client side (`GameFrameWork`, C01): only `0x4C02`, `0x4C09`, `0x4C0F`, `0x4C10`, `0x4C13`, `0x4C14`, `0x4C18` read payload. Every
FAIL/NO packet is shown as one fixed text; **the client never reads the error codes** listed below.

### 1.2 Proposal

```pseudo
0x4C01 NC_TRADE_PROPOSE_REQ { u16 proposee }                                    @ FUN_005925a0
    err → p ← 0x4C04 NC_TRADE_PROPOSENO_ACK { u16 err }   (client: "Trade was rejected by the other.", err not read)
    mode ∉ {1,2,6} (0x46):                                         0x6C1
    no field or MapInfo.CanTrade (map row +0x9c) == 0:              0x6C6
    proposee == p.handle:                                           0x6C2
    t = som_GetObject(proposee); t absent or not a player:          0x6C2
    p has an NPC menu open (ServerMenuActor p+0x17d90 not empty, `ServerMenuActor_IsEmpty` FUN_0050ec90) or
      t.vt[0x978]() false (t's ServerMenuActor not empty):          0x6C8
    dist²(p, t) > 1 000 000 (1000 units):                           0x6C3
    t.mode ∉ {1,2,6}:                                               0x6CA
    any of p.proposee/proposer, t.proposee/proposer set (≠ −1):     0x6C4
    !p.dmc_CanMenuOpen(2) or !t.dmc_CanMenuOpen(2):                 0x6C8
    !so_tradepropose_timecheck(p):                                  0x6CB   (p is already trading)
    !so_tradepropose_timecheck(t):                                  0x6CC
    t.tradeLock = t.L.index++; p.tradeLock = p.L.index++
    p.MenuOpenSet(2); t.MenuOpenSet(2)
    p.proposee = {t.handle, t.charNo}; t.proposer = {p.handle, p.charNo}
    t ← 0x4C02 NC_TRADE_PROPOSE_ASK_REQ { u16 proposer = p.handle }
```

Client: `0x4C02` (`On_NC_TRADE_PROPOSE_ASK_REQ`, client FUN_004ad0b0) opens a yes/no box "Would you accept the trade?" with a timer;
if the "refuse trades" option (client DAT_00b44f11) is set or a dice game is running it answers "no" by itself (message 0x73 →
`0x4C03`).

```pseudo
0x4C03 NC_TRADE_PROPOSE_ASKNO_ACK {} (proposee says no)                         @ FUN_00592b80
    mode ∉ 1–6 (0x7E): return
    q = p.proposer; so_CloseTradeMenu(p)
    if q alive and q.charNo == p.proposerCharNo: so_CloseTradeMenu(q); q ← 0x4C04 { 0x6C7 }

0x4C07 NC_TRADE_PROPOSE_CANCEL_CMD {} (proposer withdraws)                       @ FUN_00592a30
    mode ∉ 0x7E or p.proposee == −1: return
    t = p.proposee; so_CloseTradeMenu(p)
    if t alive and t.charNo == p.proposeeCharNo: so_CloseTradeMenu(t); t ← 0x4C08 NC_TRADE_PROPOSE_CANCELED_CMD {}

0x4C06 NC_TRADE_PROPOSEYES_ACK {} (proposee accepts)                            @ FUN_00592cd0
    mode ∉ 0x7E: return
    q = som_GetObject(p.proposer); q absent or q.charNo ≠ p.proposerCharNo: return
    if q.mode ∈ 0x7E and q.proposee == p.handle (and its charNo field ≠ 0xFFFF) and q.proposeeCharNo == p.charNo:
        if p's ServerMenuActor empty and q.vt[0x978]():
            p ← 0x4C09 NC_TRADE_START_CMD { u16 opposite = q.handle }
            q ← 0x4C09 { u16 opposite = p.handle }
            TradeBegin(q, p); TradeBegin(p, q)
            return
        so_CloseTradeMenu(p); target = q
    else target = p                                                # (the decompiled flow closes p here)
    so_CloseTradeMenu(target); q ← 0x4C04 { 0x6C8 }
```

The proposal state (`proposee`/`proposer`) is not cleared when the trade starts; it is cleared only by `so_CloseTradeMenu`.

```pseudo
0x4C0A NC_TRADE_CANCEL_REQ {}                                                   @ FUN_00592fb0
    mode ∉ 0x7E: return
    partner = board.partner; so_CloseTradeMenu(p); p ← 0x4C0B NC_TRADE_CANCEL_ACK {}   ("The trade has been cancelled.")
    if partner: so_CloseTradeMenu(partner); partner ← 0x4C0C NC_TRADE_CANCEL_CMD {}       ("Trade was canceled by the other.")
```

### 1.3 Board

All three board handlers: mode ∉ 0x7E → return; no partner → error `0x842` (log "Not activ"); `dist²(p, partner) > 1 000 000` →
`sp_tradebreak(p)` (both get `0x4C0C`); own board locked → `0x843` (log "Locked").

```pseudo
0x4C0D NC_TRADE_UPBOARD_REQ { u8 slotinven }                                     @ FUN_00595280
    err → p ← 0x4C0E NC_TRADE_UPBOARDFAIL_ACK { u16 err }   ("Failed to register the item in the trade window.")
    L.vt[0x0c](9, slotinven) (cell locked):                    0x843
    slotinven ≥ inventory size (vt 0x48c, §1.5):               0x844  (log "Too large slot")
    cell empty:                                                0x845
    !Item_BelongCheck(BelongType_CanTrade, cell) or igc_ChargedDuringUse(cell): 0x851
    ItemInfo missing or cell lot > ItemInfo.MaxLot:            0x843
    b = tb_OnBoard(slotinven); b == −1 (board full):           0x846
    L.vt[0x2c](tradeLock, 9, slotinven)                        # cell lock under the trade lock
    BoardUnlock(partner, p)
    p ← 0x4C0F NC_TRADE_UPBOARD_ACK { u8 slotinven, u8 slotboard = b }
    partner ← 0x4C10 NC_TRADE_OPPOSITUPBOARD_CMD { u8 slotboard = b, SHINE_ITEM_STRUCT iteminfo }   (variable length:
        Item_WriteItemStruct FUN_006406c0 = u16 itemID + the attribute class's own encoding, attr vt 4)
```

The same inventory slot can be put on the board twice: `tb_OnBoard` does not look for duplicates and the cell-lock test
`L.vt[0x0c]` is made before the lock (it is the same lock index, so the second test still sees the cell locked → 0x843 *(inferred
from the lock semantics; not traced into `vt 0x0c`)*).

```pseudo
0x4C11 NC_TRADE_DOWNBOARD_REQ { u8 slotboard }                                   @ FUN_00594ed0
    L.vt[0x24](9, tb_Get(slotboard))                           # release that cell's lock (done before the slot is validated)
    if tb_OffBoard(slotboard) == −1: p ← 0x4C12 NC_TRADE_DOWNBOARDFAIL_ACK { 0x847 }; return
    BoardUnlock(partner, p)
    p ← 0x4C13 NC_TRADE_DOWNBOARD_ACK { u8 slotboard }; partner ← 0x4C14 NC_TRADE_OPPOSITDOWNBOARD_CMD { u8 slotboard }

0x4C15 NC_TRADE_CENBOARDING_REQ { u64 cen }                                       @ FUN_005936b0
    err → p ← 0x4C16 NC_TRADE_CENBOARDINGFAIL_ACK { u16 err }  ("Failed to register money in the trade window.")
    cen > p.money (p+0x7f77):                                  0x848  (log "Upboarding too many money")
    board.cen = cen                                            # replaces, not adds; money is not reserved here
    BoardUnlock(partner, p)
    p ← 0x4C17 NC_TRADE_CENBOARDING_ACK { u64 cen }   (client ignores it); partner ← 0x4C18 NC_TRADE_OPPOSITCENBOARDING_CMD { u64 cen }

0x4C19 NC_TRADE_BOARDLOCK_REQ {}                                                 @ FUN_00593940
    no partner or already locked: p ← 0x4C1A NC_TRADE_BOARDLOCKFAIL_ACK {} (empty; "Failed to lock the trade window."); return
    too far: sp_tradebreak(p); return
    board.locked = 1; p ← 0x4C1B NC_TRADE_BOARDLOCK_ACK {}; partner ← 0x4C1C NC_TRADE_OPPOSITBOARDLOCK_CMD {}
```

### 1.4 Decide and commit

```pseudo
0x4C1F NC_TRADE_DECIDE_REQ {}                                                    @ FUN_00594870
    mode ∉ 0x7E: return
    no partner or board.decided:  log "Not activ or already decide"; p ← 0x4C20 NC_TRADE_DECIDEFAIL_ACK {} (empty); return
    !board.locked or !partner.board.locked: log "Not lock"; p ← 0x4C20 {}; return
    if partner.board.partner is not p (charNo compare) or dist² ≥ 1 000 001 or p.L busy (vt 0x10) or partner.L busy:
        sp_tradebreak(p); return
    board.decided = 1
    if !partner.board.decided:
        p ← 0x4C21 NC_TRADE_DECIDE_ACK {} (client ignores); partner ← 0x4C22 NC_TRADE_OPPOSITDECIDE_CMD {}; return
    # both decided: p is "A", partner is "B"
    p ← 0x4C24 NC_TRADE_TRADECOMPLETE_CMD {}; partner ← 0x4C24 {}        ("Trade has been completed." — before the DB answer: (original bug) Z06-B15)
    lockA = A.L.index++; lockB = B.L.index++
    A.L.vt[0x28](A.tradeLock); B.L.vt[0x28](B.tradeLock)                # drop the board cell locks
    req = 0x343B NC_ITEMDB_ITEMTRADE_REQ                               (layout = PROTO_NC_ITEMDB_ITEMTRADE_REQ (pdb2017), same offsets)
        { ref A {handle, charNo}, ref B, u16 lockindexA, u16 lockindexB, cen{…}, u8 tradenumber = 0, tradeitem[] }
    tb_FillCen(A.board, A, B, B.board, …, &req)                         @ FUN_00593aa0
    if !tb_FillTradeBuffer(A, B, &req, &err):                          @ FUN_00594090
        p ← 0x4C23 NC_TRADE_TRADEFAIL_CMD { err }; partner ← 0x4C23 { err }   ("Trade has been failed.")
        so_CloseTradeMenu(A); so_CloseTradeMenu(B); A.L.vt[0x28](lockA); B.L.vt[0x28](lockB)
        return
    send req (size 0x2A + 0x1A × tradenumber) to GameDB (SessionPool_Pick(g_GameDBSessions))
    title counters: if cen.from == 'A': TitleTradeGive(A.title, cen, B.charNo) FUN_005cbcd0, TitleTradeReceive(B.title, cen, A.charNo) FUN_005cbd50
                    if cen.from == 'B': the reverse
    A.vt[0x328](1); B.vt[0x328](1)                                      # tradeCommitted
    # the answers 0x343D / 0x343C come per partner: Z05 §9.10 (apply or free, so_CloseTradeMenu, 0x4C23 on failure)
```

Money (`tb_FillCen`): only the difference moves. If `A.cen > B.cen`: `cen.from = 'A' (0x41)`, `cen.cen = A.cen − B.cen`,
reservations `A.L.vt[0x48](lockA, cen, −1)` and `B.L.vt[0x48](lockB, cen, +1)`, `result_money_from = A.money − cen`,
`result_money_to = B.money + cen`. `B.cen > A.cen`: the same with `'B'`. Equal: the five money fields are zeroed and **`cen.from`
is not written** (stale `g_buf` byte; (original bug) Z06-B1: a stale 'A'/'B' there also makes the title counters run with 0).
No check that the payer still has the money now (cen was checked only when it was put on the board; spending it later makes
`result_money_from` wrap) (original bug) Z06-B2, and no cap on the receiver's money.

Items (`tb_FillTradeBuffer`): walks A's and B's used board slots in parallel. Per step one 0x1A-byte entry
`{invenA {u64 regnum, u16 id, u16 lot, u8 invenloc}, invenB {…}}`:

| A has an item | B has an item | Entry | Reservations |
|---|---|---|---|
| yes | yes | A's item with B's slot as `invenB.invenloc`, B's item with A's slot (a swap) | `A.L.vt[0x40](lockA, …)`, `B.L.vt[0x40](lockB, …)` |
| yes | no | `invenA` = A's item; `invenB = {regnum −1, id 0xFFFF, lot 0, invenloc = next empty cell of B}` | A clear (`vt 0x30`), B move-in (`vt 0x40`) |
| no | yes | mirror: next empty cell of A | A move-in, B clear |
| no | no | done → true | |

Each item is re-checked by `FUN_00593560` (ours: `Trade_ItemTradable`): lot ≤ MaxLot, `BelongType_CanTrade`, not
`ChargedDuringUse`. Errors: cell empty `0x845`, not tradable `0x851`, no empty cell left on the receiving side `0x849`. The empty-cell
iterators (`ItemBoxIterEmpty` over the inventory limited by `vt 0x498`, FUN_004879d0 first / FUN_00487a30 next) skip locked cells.
The lot written for an item without attribute class is 1 on one path and 0 on the others *(harmless: such items do not exist in
practice, inferred)*.

Title counters (`p.vt[0x420]` CharTitle block, Z07 §1.3): `TitleTradeGive` adds `cen` to the u64 at `+0x4f8` and re-evaluates title
type 6 (`FUN_005cb5f0`, title engine, Z07), `TitleTradeReceive` the u64 at `+0x508` and type 7; each only when more than 30 s
(`time()` + DAT_00aa4408 offset, FUN_00450360) passed since the last counted trade **and** the partner differs from the last one
(anti-farming; *(type names 6/7 = money given/received inferred)*).

### 1.5 Inventory sizes used here

`vt 0x48c` (FUN_0055a290) = usable inventory cells = `(p+0x2a5aa × 3 + 6) × 8`, max 0xC0 (192) (`p+0x2a5aa` = bought inventory
pages, *(inferred)*). `vt 0x498` (FUN_0055a2f0) = `p+0x2a5a0`, the limit object passed to the inventory iterators.

---

## 2. Street booths (dept 26 `NC_BOOTH_*`)

### 2.1 State

- Player mode **5** = booth open (set by OPEN, back to 1 by close). Booth and trade share open-menu kind 2.
- `p+0x29344` → current booth object. Initial value / after INTERIORSTART: the static base `StreetBooth` object `DAT_13282670`
  (ours: `g_NoBooth`). OPEN points it at `p+0x29348` (**StreetBoothSell**, vftable with `sb_Clear`/`sb_Close`/…) or
  `p+0x294b8` (**StreetBoothBuy**).
- `p+0x29340` = `g_Now` of the last OPEN / ENTRY / REFRESH *(no reader found; inferred: idle timer)*.
- Saved shape: OPEN copies the character's brief shape data (`charblock+0x25`, 0x2B bytes) into `p+0x292ac` once
  (`p+0x292d7` = saved, shared with the tent/mini-house code, Z02 §7) and writes the booth brief into it:
  `CHARBRIEFINFO_BOOTH { CHARBRIEFINFO_CAMP camp (+0x25, made by sp_MakeTentBriefInfo FUN_0056e720 from the equipped mini-house),
  u8 issell (+0x31), STREETBOOTH_SIGNBOARD signboard[30] (+0x32) }` *(pdb2017 struct, offsets match)*.

Booth object (common base `StreetBooth`, RTTI): `+0 vftable`, `+4 char signboard[30]`, `+0x24 u16 ownerHandle`, entries at `+0x28`,
stride 0x10, 20 entries:

| | StreetBoothSell | StreetBoothBuy |
|---|---|---|
| entry | `+0 u8 invenslot, +4 ItemCell* cell, +8 u64 unitcost` | `+0 u16 itemID (0xFFFF free), +2 u16 restquantity, +8 u64 unitcost` |
| `+0x168` | u16 booth lock index | (unused) |
| vt 0x04 | `sb_RefreshError` FUN_0058cce0 (all booth classes) | same |
| vt 0x08 | `sb_Clear` FUN_0058cdb0: boothLock = L.index++ | no-op FUN_00549070 |
| vt 0x0c | `sb_Close` FUN_0058ce20: `L.vt[0x28](boothLock)` | no-op |
| vt 0x10 | `sb_Clear` FUN_0058ced0: all cell pointers = 0 | `sb_Clear` FUN_0058cf50: all itemIDs = 0xFFFF |
| vt 0x14 | `sb_Boarding(L, cell, item, owner)` FUN_0058cfe0: entry = {invenslot, cell, unitcost}; `L.vt[0x2c](boothLock, 9, invenslot)` | `sb_Boarding` FUN_0058d120: entry = {cell.itemID, totallot, unitcost} (no lock) |
| vt 0x18 | `sb_Show2Client` FUN_0058f260 | FUN_0058d770 |
| vt 0x1c | `sb_Trade` FUN_00591850 | FUN_0058ffe0 |
| vt 0x20 | returns 0 (FUN_004b8d20) | returns 0 |

The base object `g_NoBooth` has vt 0x20 = FUN_005af8d0 (returns 1) and empty slots 0x08–0x1c except `sb_RefreshError`.
ShinePlayer slots: `vt 0x9ec` (FUN_0058cda0) = `booth.vt[0x20]()` = **"booth under repair / not open"**; `vt 0x7c8` (FUN_0058cd50)
= if mode 5: `booth.vt[0x18](owner, viewer, isEntry)`; `vt 0x7cc` = `booth.vt[0x1c](owner, trader, req)`.

Booth size: `vt 0x494` (FUN_0055a2d0) = `p+0x2a5ac (u8) + p+0x29310 (u32)`, max 20 (the two summands are set by charged items
/ the mini-house, *(inferred)*). `so_ply_SendBoothSize` (`vt 0x3e0`, FUN_00535390) sends `0x9010 NC_CHARGED_BOOTHSLOTSIZE_CMD
{ u8 size }` whenever the value differs from the last one sent (`p+0x2a75c`); called from `sp_NC_MINIHOUSE_ACTIV_REQ`,
`so_ply_ChatColorInfoApply`, `so_Routine`, `UseItemChargedBuff::uib_Effect`. Client: stores the value if < 0x15.

`sb_RefreshError(viewer, err)` (FUN_0058cce0): `viewer ← 0x680B NC_BOOTH_REFRESH_SELL_ACK { u16 err, + 3 unwritten bytes }`
(packet length 7; (original bug) Z06-B3: `boothhandle`/`numofitem` are stale `g_buf` bytes). It is used for **every** booth error of
ENTRY/REFRESH, also for buy booths. Client `0x680B` (FUN_004a9070): 0xA5B → "Fixing interior", otherwise "Wrong Vendor.".

**Booth search index** (`BoothManager`, FieldMap `+0x1f0`, one per map instance; class names from its log strings):
`+0` BoothStoreManager list of open sell booths `{+8 u16 owner, xy, +0x14 list of item handles}`, `+0xc` BoothItemManager list
of `{+8 u8 category (FUN_0062ddc0(ItemInfo.Class)), +9 u32 itemHandle (FUN_00439760: counter), +0xd u16 owner, +0xf u64 unitprice,
+0x17 u16 itemID, +0x19 attribute}`. Only **sell** booths are indexed. Functions: `BoothManager_OpenStore` FUN_0043b820 →
`BoothStoreManager_OpenStore` FUN_0043b6a0; `BoothManager_AddItem` FUN_0043ab80 (→ `BoothItemManager_AddItem` FUN_0043a6c0 +
`BoothStoreManager_AddItem` FUN_0043aa30, rollback `BoothItemManager_RemoveItem` FUN_0043a890); `BoothManager_CloseStore`
FUN_0043b410 (→ `BoothItemManager_RemoveItemsOfOneStore` FUN_0043a950 + `BoothStoreManager_CloseStore` FUN_0043b2a0);
`BoothManager_RemoveItem` FUN_0043ad30 (Z05: after a SELL_ALL); `BoothManager_UpdateItem` FUN_0043ae40 (after SELL_MERGE/SPLIT:
lot −= traded, remove + re-add, so the item gets a new handle); `BoothStoreManager_GetStorePosition` FUN_00439a20,
`BoothStoreManager_GetStoreItem` FUN_00439950, `BoothItemManager_GetItem` FUN_004398c0, `BoothStoreManager_CheckStoreIsOpening`
FUN_00439ad0, `BoothManager_CheckItem` FUN_00439b70 (ours). List internals (STL list insert/find/erase): FUN_0043b450, FUN_0043a590,
FUN_0043a5e0, FUN_004397e0, FUN_0043b170; the item copy uses the item-cell helpers FUN_006447b0 / FUN_0043c110 / FUN_0062dc70 (Z04).

### 2.2 Open

```pseudo
0x6801 NC_BOOTH_OPEN_REQ { STREETBOOTH_SIGNBOARD signboard[30], u8 flag (bit0 issell, bits1–7 itemnum),
                           BoothItem { u8 invenslot, u8 boardslot, u64 unitcost, u16 totallot }[itemnum] }   @ FUN_0058e900
    reply → p ← 0x6802 NC_BOOTH_OPEN_ACK { u16 err }   (codes read from the disassembly; texts = client FUN_004a87b0)
    mode ∉ {1,2,5} (0x26):                                            0xA42 "Attempting to open from another mode."
    no field or MapInfo.CanBooth (row +0xa2) == 0:                    0xA55 "Cannot open the Vendor in this area."
    L busy (vt 0x10):                                                 0xA45 "Handling the item now."
    p.CancelOnAction() (vt 0x8d0)
    itemnum ≥ inventory size (vt 0x48c):                              0xA43 "There are too many registered items."  (log "Too many items")
    a resting player, mini-house or tent NPC within 45 units (so_AllOfRange_Class0 radius 400, so_TentPoint, Z02 §7):
                                                                      0xA53 "Cannot open a Vendor near an NPC or another Vendor."
    for i < j: items[i].invenslot == items[j].invenslot or items[i].boardslot == items[j].boardslot:  0xA44
    any item's cell locked (L.vt[0x0c]):                              0xA43
    buy booth (issell 0), per item: ItemInfo of the cell's item missing or ItemInfo.Type (+0x62) == 0:   0xA58
        same item id at two entries with different unitcost:          0xA57      ("Failed to open Vendor.")
    per item: cell missing, !BelongType_CanTrade, or ChargedDuringUse: 0xA59 "The item cannot be sold."
    so_mobile_StopHere(p) (vt 0xa48)
    booth = issell ? p+0x29348 : p+0x294b8; p.booth = booth
    booth.vt[0x10]() (clear entries); booth.vt[0x08](L) (sell: take a booth lock)
    sell booth: registered = BoothManager_OpenStore(map+0x1f0, p.handle, x, y)   (failure only logs)
    per item:
        invenslot > 0xBF: log "Invalid slot"; 0xA43; booth.vt[0x0c](L); return
        cell missing or !CanTrade:  0xA44; booth.vt[0x0c](L); return
        booth.vt[0x14](L, cell, item, p)                              # Boarding; boardslot ≥ size or used → only a log
        sell booth and registered: BoothManager_AddItem(mgr, p.handle, cell.key, unitcost, cell item struct)
    booth.signboard = signboard; booth.owner = p.handle
    save the brief shape once (p+0x292ac, p+0x292d7 = 1); brief.signboard = signboard; brief.issell = flag & 1
    if !sp_MakeTentBriefInfo(p, &brief.camp):                         0xA56; booth.vt[0x0c](L); restore the shape; return
    p.mode = 5
    if p.petSystemState (p+0x2ab60) ∈ {5,6}: p+0x2abd4 = g_Now + 6000, p+0x2abd8 = 6000      (pet reaction for 600 s, inferred)
    p ← 0x6802 { 0xA41 }  "Vendor has been opened."
    broadcast in sight (so_AllOfRange_Class1) 0x6803 NC_BOOTH_SOMEONEOPEN_CMD
        { u16 handle, CHARBRIEFINFO_CAMP tent (12 bytes), u8 issell, STREETBOOTH_SIGNBOARD signboard[30] }      (0x2D bytes)
    p.MenuOpenSet(2); p+0x29340 = g_Now
```

Notes: `itemnum` is only compared with the inventory size (up to 127), not with the booth size (≤ 20): extra items fail silently in
`sb_Boarding` ("Too many board" log) and the booth opens with fewer items. A buy booth's items are **sample cells of the owner's
inventory**: `sb_Boarding` takes the item id from the cell, so the owner must hold one of each item he wants to buy; nothing is
locked. `OPEN` while mode 5 (re-open after INTERIORSTART) does not close the previous sell booth's lock first
(`booth.vt[0x08]` simply takes a new index), but INTERIORSTART already freed it.

### 2.3 Close and repair ("interior")

```pseudo
0x6804 NC_BOOTH_CLOSE_REQ {}   (handler string says sp_NC_BOOTH_CLOSE_CMD)                 @ FUN_0058d320
    mode ≠ 5 (0x20): p ← 0x6805 NC_BOOTH_CLOSE_ACK { 0xA44 }; return
    sp_CloseStreetBooth(p)
    BoothManager_CloseStore(map+0x1f0, p.handle)              # failure only logs (always fails for a buy booth)

sp_CloseStreetBooth(p)                                                                      @ FUN_005932b0
    if p.booth == 0 or mode ≠ 5: return
    booth.vt[0x10](); booth.vt[0x0c](L)                       # clear entries, free the cell locks
    p.mode = 1
    restore the saved brief shape (p+0x292d7)
    p ← 0x6805 { 0xA41 }
    broadcast in sight 0x6806 NC_BOOTH_SOMEONECLOSE_CMD { u16 handle, 0x2B bytes brief shape (CHARBRIEFINFO_NOTCAMP) }
    broadcast in map  0x6817 NC_BOOTH_SEARCH_BOOTH_CLOSED_CMD { u16 nClosedBoothOwnerHandle }
    MenuOpenClear(2)
    # p.booth keeps pointing at the closed booth object
```

`sp_CloseStreetBooth` is also called by `so_CloseByLink` (link/logout) and the layer moves listed in §1.1. Leaving the map is
covered: `ShineObject::so_Logout` (FUN_0054b780) removes the store from the index when `BoothStoreManager_CheckStoreIsOpening`
(FUN_00439c50 → FUN_00439ad0) finds it. The layer moves do not: the player stays on the map in mode 1 and the index keeps the
booth and its items ((original bug) Z06-B4: market search lists them and `SEARCH_BOOTH_POSITION` finds the store; buying then
fails with 0xA42). The `0x6817` broadcast still goes out.

```pseudo
0x6810 NC_BOOTH_INTERIORSTART_REQ {}                                                      @ FUN_0058e680
    mode ≠ 5 or L busy: return (no answer)
    booth.vt[0x0c](L)                                         # sell booth: free its cell locks
    p.booth = g_NoBooth                                       # vt 0x20 now true → "under repair"
    brief.signboard = ScrString("BoothInterior") (World script ETC.txt: "Repairing"), max 29 chars
    broadcast in sight 0x6812 NC_BOOTH_SOMEONEINTERIORSTART_CMD { u16 boothowner, signboard[29] }   (packet 0x22: the 30th byte is not sent)
    p ← 0x6811 NC_BOOTH_INTERIORSTART_ACK {}                  (client: switches the booth window to edit mode)
    broadcast in map 0x6817 { p.handle }
    BoothManager_CloseStore(map+0x1f0, p.handle)
```

The player stays in mode 5 with the camp shape; the client edits the item list and sends `0x6801` again (allowed in mode 5). The
booth entries are not cleared (`vt 0x10` is not called), but the booth object is detached.

### 2.4 Visit and refresh

```pseudo
0x6807 NC_BOOTH_ENTRY_REQ { u16 booth }                                                   @ FUN_0058d600
    errors → p.booth.vt[4](p, err) = sb_RefreshError → p ← 0x680B { err }
    mode ∉ {1,2,6}:                                     0xA42
    o = som_GetObject(booth); o absent or o.mode ≠ 5:   0xA46
    o.vt[0x9ec]() (under repair):                        0xA5B
    o.vt[0x7c8](o, p, 1)                                # Show2Client with isEntry = 1
    p+0x29340 = g_Now

0x680A NC_BOOTH_REFRESH_REQ { u16 booth }                                                 @ FUN_0058d480
    if p.booth == 0: return     (never 0: g_NoBooth)
    p+0x29340 = g_Now
    mode ∉ {1,2} (0x06):                                0xA42 (via sb_RefreshError)
    same checks as ENTRY (0xA46, 0xA5B); o.vt[0x7c8](o, p, 0)
```

`Show2Client(owner, viewer, isEntry)`:

```pseudo
StreetBoothSell::sb_Show2Client                                                           @ FUN_0058f260
    viewer ← (isEntry ? 0x6808 NC_BOOTH_ENTRY_SELL_ACK : 0x680B NC_BOOTH_REFRESH_SELL_ACK)
        { u16 err = 0xA41, u16 boothhandle = booth.owner, u8 numofitem,
          BoothItemList { u8 datasize, u8 boothslot, u64 unitcost, SHINE_ITEM_STRUCT item (variable) }[] }
    (sbs_FillBufferItem FUN_0058d900: for each slot < owner booth size with a cell; a cell whose item became 0xFFFF is dropped
     from the booth; datasize = 9 + item struct length)
StreetBoothBuy::sb_Show2Client                                                            @ FUN_0058d770
    viewer ← (isEntry ? 0x6809 NC_BOOTH_ENTRY_BUY_ACK : 0x680C NC_BOOTH_REFRESH_BUY_ACK)
        { u16 err = 0xA41, u16 boothhandle, u8 numofitem, { u8 boothslot, u16 item, u64 unitcost, u16 restquantity }[] }
```

Entries whose rest quantity reached 0 are still listed in a buy booth.

### 2.5 Buying from / selling to a booth

```pseudo
0x680D NC_BOOTH_ITEMTRADE_REQ { u16 booth, u8 slot, u16 itemnum }                       @ FUN_0058da30
    err → p ← 0x680E NC_BOOTH_ITEMTRADE_ACK { u16 err }   (texts: client FUN_004a8620, table below)
    mode ∉ {1,2,6}:                                     0xA42
    o = som_GetObject(booth); absent or o.mode ≠ 5:     0xA42
    p.L busy or o.L busy:  p ← 0x3004 NC_ITEM_BUY_ACK { 0x204 }      (original bug) Z06-B5: wrong department
    o.vt[0x9ec]() (repair): p ← 0x3004 { 0xA5B }                       (original bug) Z06-B5
    dist²(p, o) ≥ 90 000 (300 units):                   0xA4C
    o.vt[0x7cc](p, req)                                 # booth.sb_Trade(owner o, trader p, req)
```

Success has no direct answer: the DB answer `0x3456` (Z05 §9.11) applies both sides' reservations (cell/money packets) and on failure
sends `0x680E { err }` to the buyer.

**Sell booth** (`StreetBoothSell::sb_Trade` FUN_00591850; trader = buyer):

```pseudo
    slot ≥ owner booth size:                                        0xA44
    owner.L.vt[4](9, entry.invenslot, boothLock) (locked by someone else):  0xA45
    entry.cell == 0:                                                0xA47
    entry.invenslot ≥ owner inventory size: log "Invalid invenslot"; entry.cell = 0; 0xA44
    cell empty (item 0xFFFF): log "Invalid Item"; entry.cell = 0;   0xA47
    lot = cell lot; lot < itemnum:                                  0xA48
    price = unitcost × itemnum (u64)
    buyer.money < price:                                            0xA59
    !BelongType_CanTrade(cell):                                     0xA44
    maxLot = attr.IsLot ? ItemInfo.MaxLot : 1; lot > maxLot:        0xA44  (log "Too many lot")
    look through the buyer's inventory cells with the same item id (FUN_0043c0a0 iterator):
        first stack with stack.lot + itemnum ≤ maxLot → sbs_SellMerge
    no such stack: itemnum ≥ lot → sbs_SellAll, else sbs_SellSplitCreate
```

`itemnum = 0` is not refused ((original bug) Z06-B6): price 0, and the request goes to the DB as a MERGE with `mergelot 0` (or a
SPLITCREATE of a 0-lot item when the buyer has no stack).

| Function | DB request (layout = PROTO, pdb2017, offsets match) | Reservations |
|---|---|---|
| `sbs_SellAll` FUN_005905b0 (needs an empty buyer cell, else 0xA49) | `0x3453 NC_ITEMDB_BOOTHTRADE_ALL_REQ { ref seller, ref buyer, u32 boothSeller = seller charNo, u32 boothBuyer = buyer charNo, u16 lock seller, u16 lock buyer, u8 isSellBooth = 1, u64 itemregnum, u16 itemid, u8 invenslotBuyer, u64 nLot = cell lot, u64 price, u64 sellerResult = seller.money + price, u64 buyerResult = buyer.money − price }` | seller: money +price, clear cell; buyer: money −price, move into the empty cell |
| `sbs_SellMerge` FUN_005909c0 (target must have the same item id, else log "Merge to other item" + 0xA44) | `0x3454 NC_ITEMDB_BOOTHTRADE_MERGE_REQ { …, u16 itemid, u64 lotseller, u64 lotbuyer, u16 mergelot = itemnum, u64 price, u8 allmove = (itemnum ≥ seller lot), u16 sellerResultLot, u16 buyerResultLot, u64 sellerResultMoney, u64 buyerResultMoney }` | seller: money, cell (allmove → clear, else lot change `vt 0x40`); buyer: money, lot change |
| `sbs_SellSplitCreate` FUN_00590ec0 (needs an empty buyer cell, else 0xA49) | `0x3455 NC_ITEMDB_BOOTHTRADE_LOT_REQ { …, u16 itemid, u64 lotseller, PROTO_ITEM_CREATE lotcreate { u32 owner = buyer charNo, MAPPOS {map name, x, y of the buyer}, ITEM_INVEN location, u64 new key = ItemKey_Make(id, kind 4, zone, world), u16 id, u16 attr (not written) }, u16 createlot = itemnum, u64 price, u16 sellerResultLot, u16 buyerResultLot, u64 money × 2 }` | seller: money, lot change; buyer: money, new item in the empty cell |

Each takes a fresh lock index on both sides (`L.index++` after use). `lotcreate.attr` is left stale ((original bug) Z06-B7,
uninitialised bytes to the DB). The buyer's empty-cell search does not check the item's `CanTrade` again on the buyer side.

**Buy booth** (`StreetBoothBuy::sb_Trade` FUN_0058ffe0; trader = seller, owner = buyer; `req.slot` is the **seller's inventory
slot**, not a booth slot):

```pseudo
    slot ≥ seller inventory size:                                  0xA44
    seller cell locked:                                            0xA45
    cell missing / no attribute / empty / attr.vt[0x34] reports a flag (e.g. sealed, inferred): 0xA44
    lot < itemnum:                                                 0xA54 "Attempting to sale to many quantities."
    !CanTrade:                                                     0xA44;  lot > maxLot: 0xA44 (log "Too many lot")
    booth slot = the entry with this item id and the largest restquantity; none:  0xA44
    restquantity < itemnum:                                        0xA54
    price = entry.unitcost × itemnum; owner.money < price:         0xA5A "The purchaser has insufficient fund."
    target = owner stack of the same id with maxLot − lot ≥ itemnum, else the first empty owner cell; none: 0xA49
        (the stack test is `maxLot < lot or itemnum ≤ maxLot − lot`: an already overfull stack is chosen too, (original bug) Z06-B18)
    target holds another item:                                     0xA49
    seller lot == itemnum: target empty → sbb_BuyAll FUN_0058f3e0 (0x3453) else sbb_BuyMerge FUN_0058f6c0 (0x3454)
    otherwise:            target used  → sbb_BuyMerge                 else sbb_BuySplitCreate FUN_0058fb20 (0x3455)
    entry.restquantity −= itemnum                                    # at once, before the DB answer
    owner ← 0x680F NC_BOOTH_BUYREFRESH_CMD { u8 boothslot, u16 restlot }
```

The buy-side requests use the same layouts with `isSellBooth = 0`, seller = trader, buyer = owner. The rest quantity is lowered
before the DB answers and never given back when the DB refuses ((original bug) Z06-B8). `itemnum = 0` is accepted here too (Z06-B6).

Client texts of `0x680E` (client FUN_004a8620): 0xA41 "Item has been successfully sold." (never sent on this opcode), 0xA42 "Attempting
to open from another mode.", 0xA43 "There are too many items registered.", 0xA44 "Incorrect Iitem.", 0xA45 "The item is in use.",
0xA46 "Cannot find the Store.", 0xA47 "Item has been sold out.", 0xA48 "Not enough quantity.", 0xA49 "The inventory is full.", 0xA4A
"Not enough money.", 0xA4B "Incorrect location.", 0xA4C "You are too far from the store.", 0xA4D–0xA52 the DB failure texts ("DB An
error has occurred when adding money to the seller.", "… transfer an item …", "… clear the sold items from seller's Lot.", "… set the
item lot of the purchaser.", "… get item attributes …", "… create item for the purchaser …"), 0xA53 "Too close to NPC or another
Store.", 0xA54 "Attempting to sale to many quantities.", 0xA55 "Cannot open the Store in this area.", 0xA56–0xA58 "Failed to sell the
item.", 0xA59 "You have insufficient fund.", 0xA5A "The purchaser has insufficient fund.". The `0x6802` table (client FUN_004a87b0)
uses the same codes with vendor wording (0xA59 there = "The item cannot be sold.").

### 2.6 Market search

```pseudo
0x6813 NC_BOOTH_SEARCH_ITEM_LIST_CATEGORIZED_REQ { u32 Category (MarketSearch), u8 bReqOnlyMyClass, u8 bIsOpeningReq }   @ FUN_00439c70
    reply 0x6814 NC_BOOTH_SEARCH_ITEM_LIST_CATEGORIZED_ACK { u16 nError, u8 nNumOfItems, BoothItemInfo[] }
    no mode check
    rate limit (time() seconds): bIsOpeningReq == 1 → less than 3 s since p+0x2ab3c; else 3 s since p+0x2ab40
        → { 0x31D8, 0 }  ("Please wait a moment and then try again.")
    no field: 0x31C9; no BoothManager: 0x31CA; no item list: 0x31CB          (client: "No one is selling this item." for any ≠ 0x31C8)
    for each indexed booth item:
        ItemInfo missing → log, skip
        Category ≠ 0 and MarketSearchInfo(ItemInfo.ItemAuctionGroup +0x72) (FUN_0062df10, table DAT_13388240) ≠ Category → skip
        bReqOnlyMyClass == 1 and !UseClass check (FUN_00640e40(&DAT_14d42140, ItemInfo.UseClass, p.class vt 0x4dc): bit `class` of the 64-bit class mask that FUN_006409a0 builds for the UseClass row) → skip
        append BoothItemInfo { u8 bii_nDataSize, u32 bii_nItemHandle, u16 bii_nOwnerHandle, u64 bii_nUnitPrice, SHINE_ITEM_STRUCT }
        flush a packet (nError 0x31C8) when 250 items or more than 7500 bytes are collected
    send the rest (nError 0x31C8) — also an empty one if nothing was sent at all
```

Item handles are the index counter of `BoothItemManager`, not object handles. `ItemInfo` row offsets as in Z04 §1.2.

```pseudo
0x6815 NC_BOOTH_SEARCH_BOOTH_POSITION_REQ { u32 nBoothItemHandle, u16 nTargetBoothOwnerHandle }                   @ FUN_0043a140
    reply 0x6816 NC_BOOTH_SEARCH_BOOTH_POSITION_ACK { u16 nError, u16 nTargetBoothOwnerHandle, SHINE_XY_TYPE BoothPosition }   (always 0xC bytes)
    owner == 0xFFFF: 0x31D1;  itemHandle == −1: 0x31D2;  no field: 0x31C9;  no BoothManager: 0x31CA
    r = BoothManager_CheckItem(mgr, owner, itemHandle)        @ FUN_00439b70
        store not found 0x31D3; item not in that store 0x31D4; item not in the item list 0x31D4; (null manager 0x31CF / 0x31CC)
    r ≠ 0x31C8: nError = r
    else xy = BoothStoreManager_GetStorePosition(owner) (FUN_00439c30 → FUN_00439a20); none: 0x31D3
         else { 0x31C8, owner, x, y }
    # error replies leave handle/xy as stale g_buf bytes (original bug) Z06-B9
```

Client `0x6816` (FUN_004bb3f0): 0x31C8 → "Showing store location..." and marks the position; any other → "The item is sold out or the
store is closed.". `0x6817` → "The seller's store is either closed or under repairs.".

---

## 3. Mini-house TaiSai dice table (dept 43 `NC_DICE_TAISAI_*`)

A "dice table" item placed in a mini-house turns the house into a TaiSai (Sic Bo) table run by the house object
(`ShineMiniHouse`, type 3). The house owner earns a share of the house edge, collected through a money-card item. Players bet
money on 52 bet kinds (`DICE_TAISAI_BETTING` *(pdb2017)*: 0 even, 1 odd, 2 big, 3 small, 4–9 pair 1–6, 10–15 triple 1–6, 16 any
triple, 17–30 sum 4–17, 31–45 domino 12…56, 46–51 single 1–6). Bets are **not** taken from the purse when placed; the net result
is booked once per roll.

### 3.1 Tables and state

| Table (global) | Loaded @ | Use |
|---|---|---|
| `DiceGame.shn` (DAT_1328bd38) | inline in the load stage (0x5ae0c8) | one row per dice-table item: `ItemID, UseMinLv, GetSysRate (‰ house cut), GetMasterRate (owner share), MinGetMoney, MaxBetMoney, CastTime (ms), DelayTime (ms), WinCode[3], LoseCode[3]` (emotion ids); 2016 rows: items 51002–51006, level 40, cut 15 ‰, owner 600, max bet 1 500 / 15 000 / 150 000 / 1 500 000, 30 s betting, 15 s pause |
| `DiceRate.shn` (DAT_1328bef8, "gMiniHouseDiceRate") | same | 216 weights, one per ordered outcome of 3 dice |
| `DiceDividind.shn` (DAT_133886f8, "gMiniHouseDiceDividind") | same | `DividendRate[15]` + `AnyTriple`; the class `DiceTaiSaiDividind` *(pdb2017 name)* adds `bIsInitDividendRate[15]` and `ConertDividendRateTable[52]` (bet → dividend group) |

House TaiSai state (offsets in the ShineMiniHouse object; reset by vt 0x1bc FUN_00511400, set up from the item by vt 0x1c0
FUN_00511560):

| Offset | Field |
|---|---|
| +0xc6e0 / +0xc6e2 | DiceGame row index / item id |
| +0xc6e4 / +0xc6ec | u64 key of the active dice-table item / pointer to its cell; vt 0x214 (FUN_005149e0) = "TaiSai active": the cell still holds that key and its byte +10 bit 0 |
| +0xc6f0 … +0xc712 | the DiceGame row: min level, sys rate, master rate, MinGetMoney, MaxBetMoney, CastTime and DelayTime converted to `g_Now` units (ms / 100), win/lose emotion codes |
| +0xc730 | status `DICE_TAISAI_GAME_STATUS`: 0 no bets, 1 betting, 2 rolling, 3 stand-by |
| +0xc734 | mode `DICE_TAISAI_GAME_MODE`: 0 auto, 1 manual |
| +0xc738 / +0xc73c | timer running / timer end (`g_Now`) |
| +0xc740 | `DiceTaiSaiInfo DiceHistory[7]` (3 bytes each; newest first, shifted by vt 0x1d4) |
| +0xc755 / +0xc756 | "fixed dice" flag / the dice of the current roll (3 bytes) |
| +0xc759 / +0xc75c | gamer count (max 99) / gamers `{ShinePlayer*, u32}[99]` |
| +0xcc00 | per bet kind `{u64 total, u16 number of players}` (stride 0x10) |
| +0xcf40 | u64 total of all bets |
| +0xcf48 / +0xd0f8 | the 216 outcome weights (copied from DiceRate) / their sum |

Player side (`p+0x5d00` u32 game type, 1 = mini-house TaiSai; `p+0x5d20` = `GI_DiceTaiSai` *(pdb2017)*: `+0 u8 bGameLeaveReserve,
+1 u8 bRoomLeaveReserve, +4 u32 nBetMoney[52], +0xd4 u32 nBetSumMoney, +0xd8 i64 nTotalDividend`). Player slots *(names ours)*:
`vt 0x170 InGame(type)` FUN_00510e50, `0x174 GetGameInfo` FUN_00510e70, `0x178 SetGame(type)` FUN_00510e90, `0x17c CanAutoRoll`
FUN_00510ed0 (5 s wait in stand-by), `0x184/0x188` get/set game-leave reserve, `0x18c/0x190` get/set room-leave reserve,
`0x194/0x198` set/get saved map and position (`p+0x5d08`, used by the gamble house §4), `0x19c` game info, `0x1a0` clear bets,
`0x1a4 AddBet` FUN_00511360 (sets "first bet on this kind"), `0x1a8 SubBet` FUN_00511120, `0x1ac so_SendExpectIncomeMoney`
FUN_005111a0, `0x1b0 so_SendReceiptIncomeMoney` FUN_00511230, `0x1b4/0x1b8` TaiSai win-count title counters (FUN_005cc490 /
FUN_005cc4c0 on the CharTitle block, Z07).

All dept-43 player handlers share: no field → `…1`, not in a mini-house (`vt 0x130`, house handle `p+0x5cf6`) → code `…2`/`…3`,
house object gone → next code; then they call a house method and send its result. Codes are in the 0x1C80–0x1D2F block; the
client (`MHDiceGameTask`, C01) shows texts for the ones listed.

### 3.2 Join, leave, mode

```pseudo
0xAC01 NC_DICE_TAISAI_GAME_JOIN_REQ {}                                                     @ FUN_00514f40
    reply 0xAC02 NC_DICE_TAISAI_GAME_JOIN_ACK (PROTO_NC_DICE_TAISAI_GAME_JOIN_ACK, pdb2017; packet length 0x34)
    no field 0x1C81; inventory busy (L.vt[0x10]) 0x1C82; not in a house 0x1C83; house gone 0x1C84
    h.vt[0x220] CanEnter (FUN_00511e70): p null 0x1C88; gamers > 98 0x1C85; p already in a game 0x1C86; TaiSai inactive 0x1C8B;
        p already listed 0x1C87
    h.vt[0x218] SendTaiSaiGameInfo(p) (FUN_005119d0): p.level < UseMinLv → JOIN_ACK { 0x1C8C, nUseMinLv } and stop;
        else JOIN_ACK { 0x1C80, DiceHistory[7], nGameStatus, bModeType, nTimer = CastTime, nInterval = (status 1 ? end − g_Now : 0),
                        nGetSysRate, u64 nMaxBetMoney, nUseMinLv, nGamerCnt, u16 handles of the other gamers[] }
    h.vt[0x21c] SendTaiSaiBettingInfo(p) (FUN_00511c70): 0xAC04 NC_DICE_TAISAI_GAME_BETTING_INFO_CMD (the board totals);
        accepted results 0x1C80 and 0x1C89
    h.vt[0x224] Enter (FUN_00511f30): same checks as CanEnter; p.SetGame(1), clear both reserves and the bets; append to gamers
    h.vt[0x228] BroadEnter (FUN_00512040): other gamers ← 0xAC03 NC_DICE_TAISAI_GAME_JOIN_CMD { u16 nPlayerHnd }
```

Client `0xAC02`: shows the table with "Exciting Fiesta Dice Game - Max Prize per Bet %s"; for 0x1C8C "You must be higher …".

```pseudo
0xAC05 NC_DICE_TAISAI_GAME_LEAVE_REQ {}                                                    @ FUN_005151b0
    reply 0xAC06 NC_DICE_TAISAI_GAME_LEAVE_ACK { u16 nError }
    no field 0x1C91; inventory busy 0x1C92; not in a house 0x1C93; house gone 0x1C94
    r = h.vt[0x22c] Out(p) (FUN_00512160):
        p null 0x1C95; no game info 0x1C96; not in a TaiSai 0x1C97; inactive 0x1C9A
        status 2 or 3 (rolling / stand-by): 0x1C99 (leave is reserved instead; p.vt[0x188](1))
        else: undo all of p's bets on the board totals; remove p from the gamer list (0x1C98 if not found); p.SetGame(0)
              no gamers left → timer off; no bets left and auto mode in status 1 → gamers ← 0xAC2C NC_DICE_TAISAI_TIMER_CMD {0,0,0}, status 0
              → 0x1C90
    p ← 0xAC06 { r }
    r ∈ {0x1C90, 0x1C99}: h.vt[0x23c] (FUN_00512930, owner check only) and h.vt[0x230] BroadOut(p, reserved)
        (FUN_00512460): gamers ← 0xAC07 NC_DICE_TAISAI_GAME_LEAVE_CMD { u8 bReserve, u16 nPlayerHnd }

0xAC13 NC_DICE_TAISAI_GAME_MODE_CHANGE_REQ {}  (owner only)                                @ FUN_00515890
    reply 0xAC14 NC_DICE_TAISAI_GAME_MODE_CHANGE_ACK { u16 nError, u32 bModeType }
    no field 0x1CA1; not in a house 0x1CA2; house gone 0x1CA3
    r = h.vt[0x234] (FUN_00512570): not in game 0x1CA5/0x1CA6, inactive 0x1CA7, p not the owner (vt 0x80) 0x1CA8, p not a gamer 0x1CA9;
        mode = !mode; 0x1CA0
    p ← 0xAC14 { r, mode (vt 0x2a4) }
    r == 0x1CA0: h.vt[0x238] BroadModeChange (FUN_00512660): gamers ← 0xAC15 NC_DICE_TAISAI_GAME_MODE_CHANGE_CMD { u32 mode };
        status 1: auto → restart the bet timer (end = now + CastTime); manual → stop it
```

### 3.3 Betting

```pseudo
0xAC1A NC_DICE_TAISAI_BETTING_REQ { DiceTaiSaiBetting { u32 nBetting, u32 nMoney }, u16 nBettingIndex }     @ FUN_00515c40
    reply 0xAC1B NC_DICE_TAISAI_BETTING_ACK { u16 nError, u16 nBettingIndex (echoed) }
    no field 0x1CB1; inventory busy 0x1CB2; not in a house 0x1CB3; house gone 0x1CB4
    r = h.vt[0x248] CanBetting (FUN_00512ea0):
        not in game 0x1CB7 / 0x1CB6; inactive 0x1CBD; status ∉ {0,1} 0x1CBB; nMoney == 0 0x1CBC; nBetting ∉ 0..51 0x1CBE
        p.money < nBetSumMoney + nMoney (only tested when the purse is < 2^32): 0x1CB9
        bet limit: MaxBetMoney × 100 / DividendRate[group(nBetting)] < p.nBetMoney[nBetting] + nMoney, or group invalid: 0x1CBA
            (FUN_006341d0 on DiceDividind)
    if r == 0x1CB0: r = h.vt[0x24c] Betting (FUN_00513030): same checks, p.AddBet, board totals += nMoney, players-on-kind +1 if first
    p ← 0xAC1B { r, index }
    r == 0x1CB0: h.vt[0x244] BroadSetTimer(&bet, 0) (FUN_00512bf0): first bet of a round in auto mode → status 1, timer = CastTime,
                     gamers ← 0xAC2C NC_DICE_TAISAI_TIMER_CMD { u8 bIsStart 1, u16 nTimer, u32 nInterval }
                 h.vt[0x250] BroadBetting (FUN_005131f0): gamers ← 0xAC1C NC_DICE_TAISAI_BETTING_CMD { u16 nPlayerHnd, DiceTaiSaiBetting }

0xAC1D NC_DICE_TAISAI_BETTING_CANCEL_REQ { DiceTaiSaiBetting, u16 nBettingCancelIndex }                     @ FUN_00515ee0
    reply 0xAC1E NC_DICE_TAISAI_BETTING_CANCEL_ACK { u16 nError, u16 index }
    no field 0x1CC1; inventory busy 0x1CC2; not in a house 0x1CC3; house gone 0x1CC4
    h.vt[0x254] CanBettingCancel (FUN_005132f0) / h.vt[0x258] BettingCancel (FUN_00513410): null 0x1CC5; no game info 0x1CC6;
        not in a TaiSai 0x1CC7; table inactive 0x1CCC; status ∉ {0,1} 0x1CC8; amount 0 0x1CC9; kind ∉ 0..51 0x1CCD; no bet info 0x1CCA;
        amount > own bet on that kind 0x1CCB; else p.SubBet, board totals −= amount → 0x1CC0
    success: h.vt[0x244](&bet, 1): no bets left → status 0, gamers ← 0xAC2C {0,0,0};
             h.vt[0x25c] BroadBettingCancel (FUN_00513570): gamers ← 0xAC1F NC_DICE_TAISAI_BETTING_CANCEL_CMD { u16 nPlayerHnd, DiceTaiSaiBetting }
```

### 3.4 The roll (house routine)

Driven by `ShineMiniHouse::so_Routine` (FUN_00567400) when the timer ends (`+0xc738` set and `+0xc73c ≤ g_Now`):

```pseudo
status 1 and mode auto:
    h.vt[0x264] (FUN_00513760: active, auto, status 1, total > 0) and h.vt[0x268] Roll (FUN_005137c0):
        fixed-dice flag set (GM): use the stored dice once, clear the flag      (decompiler shows this inverted; checked in the disassembly)
        else: r = ((rand() << 15) | rand()) % weightSum + 1; pick the outcome by the 216 weights; FUN_006338a0 → 3 dice
        status = 2
    h.vt[0x26c] BroadDiceRoll (FUN_005138d0): each gamer ← 0xAC22 NC_DICE_TAISAI_DICE_ROLL_CMD { u16 nError }
        0x1CE0 ok; 0x1CE1 not in game; 0x1CE2 no game info; 0x1CE3 purse < own bet sum; 0x1CE4 inventory busy
    h.vt[0x274] Result_DiceRoll (FUN_005161d0) → GameDB 0xAC23 NC_DICE_TAISAI_DB_DICE_ROLL_RESULT_REQ
        { ref owner {handle, charNo} (the house owner object, vt 0x84; none → nothing is sent), u64 nActiveDiceTaiSaiKey,
          DiceTaiSaiInfo DiceNum, u16 nResultCnt, DiceRollApplyResult { u16 nError 0, u16 lockindex, u32 nPlayerNo, i64 nTotalDividend }[] }
        per gamer that can cover its bet sum and whose inventory is free:
            winners of this outcome (FUN_00633830/FUN_00633920 on table DAT_13386e30 → winning bet kinds and multiplicity)
            net = Σ_win (dividend(kind, multiplicity, bet) (FUN_00634230) − dividend × GetSysRate / 1000) − Σ_lose bet
            L.vt[0x48](lock, |net|, net < 0 ? −1 : +1); L.index++
        timer off
status 3 (stand-by over): h.vt[0x298] BroadLargeAmount (FUN_00514280: 0xAC2A NC_DICE_TAISAI_LARGE_AMOUNT_CMD, big wins),
    vt 0x1d4 (shift the history, clear the board, status 0), vt 0x1dc (clear the gamers' bets), vt 0x208 (FUN_00514660: gamers with a
    room-leave reserve are sent out of the house, vt 0x600), vt 0x210 (FUN_00516f40: dice-table item checks, see §3.6),
    owner.so_DiceTaiSaiChargedItemLimitCheck(…) (§3.6), vt 0x20c (FUN_00514860: execute reserved game leaves: Out + BroadOut),
    gamers ← 0xAC2B NC_DICE_TAISAI_BET_START_CMD { u32 bModeType, DiceTaiSaiInfo CurrentRollingDice }; status 0
```

The first loop of `Result_DiceRoll` calls the bet-limit check per bet and ignores the result (dead check, (original bug) Z06-B17).

```pseudo
0xAC24 NC_DICE_TAISAI_DB_DICE_ROLL_RESULT_ACK { u16 nError, i32 nGameNo, ref, u64 key, u16 nResultCnt, DiceRollApplyResult[] }   (GameDB, @ FUN_005171c0)
    only if nError == 0x1CF0 and the ref player (owner) is alive, charNo matches, in a house with a field, and owns that house:
        h.vt[0x270] MoneyResult (FUN_00513a70): per result of a current gamer: result 0x1CF0 → L.vt[0x1c] apply (log on failure) else
            L.vt[0x28] free; gamer.nTotalDividend = max(0, result.nTotalDividend)
        h.vt[0x278] ResultLog(nGameNo) (FUN_005165c0) → GameDB 0xAC25 NC_DICE_TAISAI_DB_DICE_ROLL_RESULT_LOG_CMD (one DiceRollApplyResultLog
            per bet, split at 7500 bytes) and the win-count title counter (vt 0x1b4)
        h.vt[0x27c] BroadResult (FUN_00513d00): gamers ← 0xAC26 NC_DICE_TAISAI_DICE_ROLL_RESULT_CMD { u16 0x1CE8 (or 0x1CE9), dice }
        h.vt[0x280] (FUN_00513e00): map ← 0xAC27 NC_DICE_TAISAI_DICE_ROLL_RESULT_EMOTION_CMD { u8 n, {u16 handle, u32 emotion}[] }
            emotion = a random one of the 3 WinCode (net > 0) or LoseCode (net < 0); nothing for net 0
        h.vt[0x284] (FUN_00513ff0): status 2 → 3, timer = DelayTime
```

**(original bug) Z06-B10**: a refused or lost `0xAC24` (or one arriving after the owner left the house) is dropped: the money
reservations of every gamer stay open (their inventory stays locked until relog) and the table stays in status 2 forever.
**(original bug) Z06-B11**: manual mode has no way to roll: the routine rolls only in auto mode, the manual check `vt 0x260`
(FUN_00513670, owner-only "can roll") has no caller and `0xAC20 NC_DICE_TAISAI_DICE_ROLL_REQ` *(pdb2017)* is not registered.
Bets placed in manual mode stay until the owner switches back to auto.

`0xAC28 NC_DICE_TAISAI_LARGE_AMOUNT_REQ { u32 nMoney }` (LAB_00516180) is an empty stub: it only pushes and pops the profiler name
(the function is not even created in the Ghidra export); no answer ((original bug) Z06-B16).

### 3.5 Owner income and ranking

```pseudo
0xAC0B NC_DICE_TAISAI_EXPECT_INCOME_MONEY_REQ { ITEM_INVEN nInvenSlot }  (owner)                   @ FUN_00515400
    reply 0xAC0E NC_DICE_TAISAI_EXPECT_INCOME_MONEY_ACK { u16 nError, ITEM_INVEN, u32 nGameCnt, u64 nExpectIncomeMoney }
    no field 0x1D01; not in a house 0x1D02; house gone 0x1D03; p not the owner 0x1D05
    h.vt[0x288] (FUN_00516970): slot not in box 16 (0x4000) 0x1D06; slot > 0x61 0x1D07; empty 0x1D08; item not an active dice-table
        item (ItemActive list DAT_00aa4084) 0x1D0B; ItemInfo.Type ≠ 1 0x1D0A; owner gone 0x1D04
        → GameDB 0xAC0C NC_DICE_TAISAI_DB_EXPECT_INCOME_MONEY_REQ { ref owner, ITEM_INVEN, u64 key, u64 nRewardMoney = MinGetMoney, u16 GetMasterRate }
    0xAC0D …_DB_EXPECT_INCOME_MONEY_ACK (GameDB @ FUN_00517330): player alive, charNo ok, in a house → p.vt[0x1ac]: p ← 0xAC0E { copied }

0xAC0F NC_DICE_TAISAI_RECEIPT_INCOME_MONEY_REQ { ITEM_INVEN nInvenSlot }  (owner)                   @ FUN_00515600
    reply 0xAC12 NC_DICE_TAISAI_RECEIPT_INCOME_MONEY_ACK { u16 nError, ITEM_INVEN, u64 ReceiptIncomeMoney }
    0x1D01/0x1D02/0x1D03/0x1D05 as above; inventory busy 0x1D06
    h.vt[0x28c] (FUN_00516c40): slot not in box 16 0x1D07; > 0x61 0x1D08; empty 0x1D09; item ≠ the money-card item (DAT_14d504ca) 0x1D0B;
        owner gone 0x1D04; reserve money +0 and clear the card cell under a new lock
        → GameDB 0xAC10 NC_DICE_TAISAI_DB_RECEIPT_INCOME_MONEY_REQ { u16 lockindex, ref, ITEM_INVEN, u64 key }
    0xAC11 …_DB_RECEIPT_INCOME_MONEY_ACK (GameDB @ FUN_00517410) → p.vt[0x1b0] (FUN_00511230): nError 0x1D00 → L apply, then
        p.money += ReceiptIncomeMoney directly (vt 0x440, outside the lock); other code → L.vt[0x28] free; p ← 0xAC12 in both cases

0xAC16 NC_DICE_TAISAI_RANK_REQ {}                                                                  @ FUN_00515aa0
    reply 0xAC19 NC_DICE_TAISAI_RANK_ACK; no field 0x1D19; not in a house 0x1D1A; house gone 0x1D1B
    h.vt[0x290] GetRank (FUN_00516df0): inactive / owner gone 0x1D1C / 0x1D1D → GameDB 0xAC17 NC_DICE_TAISAI_DB_RANK_REQ { ref owner, u32 nReqCharNo, u64 key }
    0xAC18 …_DB_RANK_ACK (GameDB @ FUN_005174f0) → h.vt[0x294] SendRank (FUN_00514070): requester ← 0xAC19
        { u16 0x1D18, u8 nRankHistoryCnt, DiceRankInfo[20] (DB), u8 nRankCurrCnt, DiceRankInfo current (from the gamers' win counters) }
```

### 3.6 Dice-table item and money card

`ShinePlayer::sp_DiceTaiSaiItemIDChange(cell, box, slot)` (FUN_00514b40): when the dice-table item has expired (its ItemActive entry
is gone, or its ItemInfo.Type is 1) and it is a DiceGame item of the house the player is in, the zone asks the DB to turn it into the
money card: GameDB `0xAC2C NC_DICE_TAISAI_DB_ITEM_ID_CHANGE_REQ { ref, ITEM_INVEN, u16 lockindex, u64 key, u16 nGameItemID,
u16 nMoneyCardItemID = DAT_14d504ca, u64 nRewardMoney = MinGetMoney, u16 GetMasterRate }` (the same command number as
`TIMER_CMD`, 44, on another link *(pdb2017 enum has both)*) and reserves an item-id change (`L.vt[0x68]`). Answer `0xAC2D`
(GameDB @ FUN_005175f0): `nError 0x1D28` → apply (log on failure) and `h.vt[0x2a8]` (FUN_00514a40); any answer frees the lock.
`so_DiceTaiSaiChargedItemLimitCheck(box, 0x10, flag, status)` (FUN_00517770, vt 0x180) walks the owner's box 16 and calls it for
every item whose expiry date (packed `y/m/d/h/min` bits from `attr.vt[0x34]`) is before the current date (DAT_00aa43b8).
The house routine calls it in stand-by (§3.4); `vt 0x210` (FUN_00516f40) also checks the active key and folds the table:
`h.vt[0x29c]` (FUN_005143e0) sends `0xAC0A NC_DICE_TAISAI_BOARD_FOLD_CMD` to the gamers and clears their game state.

GM commands `&ts_DiceFix` / `&ts_DiceProbability` (Z11: FUN_00420860 / FUN_004209f0) call `vt 0x1cc` (FUN_005117d0: store fixed
dice, allowed in status 0/1) and `vt 0x1d0`-family FUN_00511830 (set the weight of one outcome, or reload all weights from DiceRate).
---

## 4. Gamble house: coins, exit, seats, TaiSai (dept 47 `NC_GAMBLE_*`)

The gamble house is a map whose FieldList row has map type 7 (`FieldMap+0x10 → row +0x3a == 7`, `vt 0xaf8` FUN_00615cf0
"in gamble house"). Inside, players use **coins** instead of money. Its games are objects of the gamble manager
`DAT_14d70e58` (ours: `g_GambleMgr`): `+0/+4` vector of all game objects, `+0x10/+0x14` TaiSai tables (`CGambleDiceTaiSaiObject`,
stride 0x570), `+0x1fc/+0x200` slot-machine clusters (stride 0xb8). Lookups: by dealer NPC handle FUN_00615830, by gamer charNo
FUN_00615890, by charNo and game type FUN_00615490 (1 TaiSai, 2 slot machine); `CGambleObject` member test FUN_00614b10.

`CGambleObject` (RTTI; base of both games): `+4 NPC*` (dealer), `+8 u8 max gamers`, `+9 u8 gamers`, `+0xc ShinePlayer*[]`,
`+0x10 u8 seats`, `+0x11 next seat`, `+0x14 u16 seat handles[]`. Slots: `0x00` add gamer (FUN_00614a60; when the table becomes full
the dealer NPC gets an abstate shown in its brief info), `0x04` remove gamer (FUN_006152d0; removes abstate 0x1A3 from the NPC),
`0x0c` game type, `0x10` has room (FUN_00614cb0), `0x14` take next free seat (FUN_00614cc0), `0x18` seat free (FUN_00614d40),
`0x1c` level ok (TaiSai FUN_00614d70: level ≥ +0x28), `0x30 go_PlayerAction` (FUN_00615180: `0xBC1E NC_GAMBLE_PLAYERACT_CMD`),
`0x38` status.

### 4.1 Player coin state and its persistence

| Player field | Accessor | Meaning |
|---|---|---|
| `p+0x2aa58` char[12] | `vt 0xafc` set (FUN_0055a680) | map to return to when leaving the house |
| `p+0x2aa68` u64 | `vt 0xb10`/`0xb14` (FUN_0055a6e0 / FUN_0055a6f0) | coins exchanged (bought) since the daily reset |
| `p+0x2aa70` u64 | `vt 0xb04`/`0xb08` (FUN_0055a6b0 / FUN_0055a6c0) | coins |
| `p+0x2aa78` u32 | `vt 0xb1c` (FUN_00615e60) = "in no game" (type == 0; callers pass an argument it ignores), `0xb20` is type, `0xb24 IsInGambleGame`, `0xb28` set | current gamble game type |
| `p+0x2aa7c/80` | `vt 0xb2c` (FUN_00615ee0) | TaiSai auto-roll wait (5 s in stand-by), as `vt 0x17c` in §3 |

- `so_Gamble_ChangeCoin` (`vt 0xb0c`, FUN_00617260): `p ← 0xBC04 NC_GAMBLE_COIN_CHANGE_CMD { u64 coin }`.
- `so_Gamble_ChangeExchangedCoin` (`vt 0xb18`, FUN_00617360): `p ← 0xBC05 NC_GAMBLE_EXCHANGECOIN_CHANGE_CMD { u64 remaining }`,
  remaining = `GBExchangeMaxCoin[level] − exchanged` (0 if negative).
- **Open from Z07:** WM `0x10DD NC_CHAR_ZONE_COININFO_CMD { ref, u64 coin, u64 exchangedCoin }` (FUN_00617830, the handler carries
  the `…GAMBLE_ZONE_PREVMAPNAME_CMD` profiler string by copy-paste) → `p.vt[0xb00]` (FUN_00615d10, ours `so_Gamble_SetCoinInfo`):
  coin = …, exchanged = …, then `p ← 0x10DE NC_CHAR_CLIENT_COININFO_CMD *(pdb2017)* { u64 coin, u64 remaining exchangeable }` (remaining as above, from `GBExchangeMaxCoin`
  DAT_13296dc8 by level). Sent while the character loads (W01 §6 login blobs).
- WM `0xBC01 NC_GAMBLE_ZONE_PREVMAPNAME_CMD { ref, char map[12] }` (FUN_00617750) → `p.vt[0xafc]` stores the return map.
- Save (in `WholeSaver::ws_save2worldmanager`, Z01): `sp_Gamble_PrevMapNameSave2World` FUN_00617010 → WM `0xBC1D NC_GAMBLE_WORLD_PREVMAPNAME_CMD *(pdb2017)* { u16 wmHandle,
  char savedMap[12] (p+0x7f7f), u32 charNo }`; `sp_Gamble_CoinDataSave2World`
  FUN_00617130 → WM `0x402C { u16 wmHandle, u64 coin, u64 exchanged, u32 charNo }`.
- Daily reset: WM `0xBC09 NC_GAMBLE_EXCHANGEDCOIN_INIT_CMD { u32 date }` (FUN_00617e50): for every player on the zone: inventory
  busy → GameDB `0xBC0A NC_GAMBLE_EXCHANGEDCOIN_DB_INFO_REQ { u32 charNo, u32 date }` (asks the DB later); else exchanged = 0 and
  `0xBC05`. Answer `0xBC0B …_DB_INFO_ACK { u32 charNo, u64 exchanged }` (FUN_00617900, player by charNo) → set and `0xBC05`.
- Coin reservations use `L.vt[0x70]` (`InventoryCellLockList_icl_StoreGBCoin` FUN_00489d90 → releaser `CoinChange`, applied by
  `icr_Apply` FUN_00489be0, which sends `0xBC04`).

### 4.2 Buying and selling coins

The exchange window is opened by the NPC menu: `NPCRole_MenuOpen` (FUN_004c4140, Z02) sends `0xBC0C NC_GAMBLE_COIN_EXCHANGEMACHINE_UI_OPEN_CMD {}`
and records the NPC range object at `p+0x17d84` that BUY/SELL test with `NPCRangeCheck_Check`.

```pseudo
0xBC0F NC_GAMBLE_COIN_BUY_REQ { u64 nCoin }                                                    @ FUN_00616330
    err → p ← 0xBC10 NC_GAMBLE_COIN_BUY_ACK { u16 nError }
    mode ∉ {1,2,6}, in a gamble game, inventory busy, menu bits 2/3 open, not at the exchange NPC (NPCRangeCheck p+0x17d84),
      nCoin == 0, level not in GBExchangeMaxCoin, GBHouse missing:                                 0x280B
    nCoin > GBExchangeMaxCoin[level].ExchangeMaxCoin − exchanged:                                  0x280C
    price = GBHouse.GB_GameMoney (10 in 2016) × nCoin; price > p.money:                             0x280D
    date = today at GBHouse reset time (06:00:00), or yesterday's if now is earlier
    GameDB 0xBC11 NC_GAMBLE_COIN_DB_BUY_REQ { ref, u16 nLockIndex, u64 nCoin, u64 nMoney = price,
                                             u32 nCanExchangeMaxCoin, i32 tExchangedCoinDate }    (PROTO, pdb2017; offsets match)
    reserve coins +nCoin (and exchanged +nCoin) and money −price; L.index++
0xBC12 …_DB_BUY_ACK { ref, u16 lock, u16 nError }  (GameDB @ FUN_006179f0)
    0x2808 → apply (log on failure) else free; p ← 0xBC10 { nError }

0xBC13 NC_GAMBLE_COIN_SELL_REQ { u64 nCoin }                                                   @ FUN_00616770
    err → p ← 0xBC14 NC_GAMBLE_COIN_SELL_ACK { u16 nError }
    mode, in game, busy, menu bits, not at the NPC:                    0x2813
    nCoin > coins:                                                     0x2814  ("Cannot exchange more than the total amount of coins you have.")
    GBHouse missing:  p ← 0xBC10 (BUY_ACK) { 0x2813 }                  (original bug) Z06-B12: wrong opcode
    money = GB_GameMoney × nCoin; tax = money × GB_ExchangeTax (20 ‰) / 1000; money −= tax, or −= 1 when tax is 0
    money == 0:                                                        0x2813
    GameDB 0xBC15 NC_GAMBLE_COIN_DB_SELL_REQ { ref, u16 lock, u64 nCoin, u64 nMoney }; reserve coins −nCoin, money +money
0xBC16 …_DB_SELL_ACK (GameDB @ FUN_00617b40): 0x2810 → apply else free; p ← 0xBC14 { nError }
```

Client (`MHDiceGameTask`, C01): `0xBC10` (client FUN_00706a60) shows text only for 0x280D "Cannot exchange coins due to exchange
limit exceeded." (the server's code for *not enough money*) and 0x280C "Cannot exchange more than total daily allotment of coins.";
every other code, including success 0x2808, is silent (the coin change comes as `0xBC04`). `0xBC14` (FUN_00706ad0): 0x2814 "Cannot
exchange more than the total amount of coins you have.", others silent. `0xBC0E` (FUN_00706270) opens the VIP window only on 0x2818.

The decompiler shows the first u16 of `0xBC11/0xBC15` as a third handler argument: player handlers receive `(packet, length,
handle)` from `ClientSession::zbs_Parsing` (FUN_004fb9f0), the third being the session's player handle (Z01 §5.2 uses it the same
way), so `ref.handle` is correct.

```pseudo
0xBC0D NC_GAMBLE_COIN_USE_VIPCARD_REQ { u8 slot }                                              @ FUN_00616ad0
    reply 0xBC0E NC_GAMBLE_COIN_VIPCARD_UI_OPEN_ACK { u16 nError }  (some errors on 0x300E, see below)
    mode ∉ {1,2,6}, inventory busy, abstate 0x146 present (vt 0x9e4), slot ≥ inventory size: 0x2819
    map row +0x9e (gamble allowed) == 0:                               0x281E
    cell locked (L.vt[4]):        p ← 0x300E { 0x281D }               (original bug) Z06-B13: dept 12 instead of 47
    empty cell / no ItemInfo:                                          0x281F
    ItemInfo.Type ≠ 5:            p ← 0x300E { 0x281A }               (Z06-B13)
    level < ItemInfo.DemandLv:                                         0x281C
    lot 0:                                                             0x281F
    else                                                               0x2818 (client opens the VIP exchange window; nothing is consumed)
```

`0xBC1A NC_GAMBLE_COIN_DB_USE_COINITEM_ACK { ref, u64 coins, u16 lock, u16 err }` (GameDB @ FUN_00617c90) answers the coin item
(`UseEffect::UseItemCoin::uib_AfterCast`, Z04 §6): `0x700` → apply, `p.vt[0x91c](0x700, 9)` (item-use result), `p ← 0xBC1B
NC_GAMBLE_COIN_USE_COINITEM_MESSAGE_CMD { u64 coins }` ("Earned %d coins"); else free and `vt 0x91c(err, 9)`.

### 4.3 Leaving the house, seats

```pseudo
0xBC02 NC_GAMBLE_GAMBLEHOUSE_EXIT_REQ {}                                                       @ FUN_00616000
    reply 0xBC03 NC_GAMBLE_GAMBLEHOUSE_EXIT_ACK { u16 }
    mode ∉ {1,2,6} or not in a gamble house:                0x2801
    CancelOnAction; so_mobile_StopHere
    in a gamble game whose status is 2 or 3 (rolling / stand-by): 0x2813 (a COIN_SELL code reused; the client FUN_007064e0 acts only on
        0x2800, so every refusal is silent)
    return map (p+0x2aa58) known in MapInfo: p ← 0xBC03 { 0x2800 }; so_LinkTo({map, map, MapInfo regen xy (+0x32/+0x36)}, 6, 9, 10)
        (link failure only logs)
    unknown map: p ← 0xBC02 { 0x2803 } (original bug) Z06-B14: sent with the request's own opcode (the client registers no 0xBC02
        handler); sp_2Roumen(p)
sp_2Roumen(p)                                                                                   @ FUN_0043cf80
    FieldList row of the current map (FUN_0063e160, prefix match): its return map (+0x6e) and xy (+0x7a), else "RouN" (6445, 8630)
    so_LinkToReserv (vt 0x3fc)

0xBC17 NC_GAMBLE_TYPE_AND_WHERE_STAND_REQ { u16 npcHandle }                                     @ FUN_00616dd0
    reply 0xBC18 NC_GAMBLE_TYPE_AND_WHERE_STAND_ACK { u16 nError, u16 npc, u32 type, u8 seat (0xFF) }
    no field 0x2601; inventory busy 0x2602; already a gamer somewhere 0x2608; no game at that NPC / NPC gone 0x2604;
    dist² ≥ 1 000 001 0x2607; level check (obj vt 0x1c, level byte p+0x7f56) 0x2609; full 0x2605; no free seat 0x2606
    else { 0x2600, npc, type, seat }
```

### 4.4 Gamble-house TaiSai (`CGambleDiceTaiSaiObject`)

The same game as §3, run by a dealer NPC instead of a house, with coins instead of money, always in auto mode, no owner share.
Object fields: 13 seats, gamers 1–6 (`GBJoinGameMember` game type 23), `GBDiceGame.shn` (DAT_13388248: `MaxBetMoney 150000,
CastTime 30000, DelayTime 15000`) copied to `+0x20/+0x24/+0x26`, `GBDiceDividind` (DAT_13388578) for limits and dividends,
`GBDiceRate` for the outcome weights, status `+0x44`, timer `+0x48/+0x4c`, dice `+0x66`. All methods are in the vtable (names from
the binary): `GDTSO_DiceTaiSai_Enter/BroadEnter/Out/BroadOut/BroadSetTimer/CanBetting/Betting/BroadBetting/CanBettingCancel/
BettingCancel/BroadBettingCancel/CanAutoDiceRoll/DiceRoll/BroadDiceRoll/MoneyResult_DiceRoll/Result_DiceRoll/ResultLog_DiceRoll/
BroadResult_DiceRoll/BroadEmotion_DiceRoll/PrepareNextGame/ExcuteLeaveGame/BroadLargeAmount`, `go_Routine` FUN_006181e0,
`go_SendGameInfo` FUN_006183d0, `GDTSO_SendTaiSaiBettingInfo` FUN_006185f0, `go_PlayerUnmarking` FUN_0061b1d0 (player leaves the
map: reserved leave or Out), GM `GDTSO_SetDiceFix` / `SetDiceProbability` (`&GB_DiceFix`, `&GB_DiceProbability`, Z11).

```pseudo
0xBC64 NC_GAMBLE_DICE_TAISAI_GAME_JOIN_REQ { u16 npc, u8 seat, u8 direction }                  @ FUN_0061ccc0
    reply 0xBC65 NC_GAMBLE_DICE_TAISAI_GAME_JOIN_ACK (client: "Lucky House Dice Game - MAX BET %d coins"; level refusal "You must be
        higher than level %d to join the game.")
    no field 0x2611; busy 0x2612; already in a game 0x261B; no table / NPC 0x2613; too far 0x2614; full 0x2615; seat taken 0x2616
    face the table: p.direction = direction; sight ← 0xBC1C NC_GAMBLE_ENTER_PLAYER_DIRECT_CMD { u16 handle, u8 dir }  (FUN_00615f50)
    obj.go_SendGameInfo(p) (0x2610 / 0x2617), SendTaiSaiBettingInfo (0xBC67, 0x2610/0x2618/0x2619), DiceTaiSai_Enter (0x2615, 0x2617,
        0x261B), BroadEnter (0xBC66 NC_GAMBLE_DICE_TAISAI_GAME_JOIN_CMD)
0xBC68 …_GAME_LEAVE_REQ {}                                                                      @ FUN_0061cf40
    reply 0xBC69; no field 0x2621; busy 0x2622; not in a TaiSai 0x2623
    Out: 0x2620 left (bets returned to the board totals) / 0x2627 reserved (rolling or stand-by) / 0x2624, 0x2625; reserved → obj.vt[0xd4](p,1)
    0x2620/0x2627 → BroadOut 0xBC6A NC_GAMBLE_DICE_TAISAI_GAME_LEAVE_CMD (+ 0xBC81 timer stop when the board empties)
0xBC71 …_BETTING_REQ { DiceTaiSaiBetting, u16 index } (@ FUN_0061d470) → 0xBC72 { err, index }: no field 0x2631, busy 0x2632, not in a TaiSai 0x2633;
        CanBetting FUN_00618db0 / Betting FUN_0061c6c0: null 0x2635, not in game 0x2634, status ∉ {0,1} 0x2636, amount 0 0x2637,
        kind > 51 0x2638, no bet info 0x2639, coins (vt 0xb04) < bet sum + amount 0x263A, bet limit (GBDiceDividind) 0x263B, ok 0x2630
        (no "table inactive" check, unlike §3.3); success → timer 0xBC81, 0xBC73 BETTING_CMD
0xBC74 …_BETTING_CANCEL_REQ (@ FUN_0061d6d0) → 0xBC75: no field 0x2641, busy 0x2642, not in a TaiSai 0x2644;
        CanBettingCancel FUN_00619200 / BettingCancel FUN_0061ca00: null 0x2643, not in game 0x2644, status 0x2647, amount 0 0x2648,
        no bet info 0x2649, amount > own bet 0x264A, kind 0x264B, ok 0x2640 (0x2645/0x2646 never returned); success → 0xBC76 BETTING_CANCEL_CMD
0xBC6B …_ALL_RANK_REQ {} (FUN_0061d170): 0x2691 / 0x2693 → GameDB 0xBC6C; answer 0xBC6D (GameDB @ FUN_0061da70) → 0xBC6E { 0x2690 | 0x26A2, ranks }
0xBC6F …_CURR_RANK_REQ {} (FUN_0061d2f0): 0x26A1 / 0x26A2 / 0x26A3; ranking of the current gamers (FUN_00615540, gamer count/get FUN_00614b70 / FUN_00614b80, FUN_006181c0) → 0xBC70
```

Roll cycle (`go_Routine`): status 1 and timer over → CanAutoDiceRoll (0x2650/0x2655/0x2656), DiceRoll (fixed dice or weighted
random, 0x2652), BroadDiceRoll `0xBC77`, Result_DiceRoll → GameDB `0xBC78 NC_GAMBLE_DICE_TAISAI_DB_DICE_ROLL_RESULT_REQ { ref of
the dealer NPC, dice, u16 count, {u16 0, u16 lock, u32 charNo, i64 net}[] }` with the same net formula as §3.4 (house cut
`+0x2a` ‰) booked as **coin** reservations (`L.vt[0x70]`). Answer `0xBC79` (GameDB @ FUN_0061d930): `0x2680` and the NPC still on a
map and its table of type 1 → MoneyResult (apply/free per gamer), ResultLog (`0xBC7A` to GameDB), BroadResult `0xBC7B`, emotions
`0xBC7C`, stand-by. Stand-by over → BroadLargeAmount `0xBC7F`, clear board/bets, ExcuteLeaveGame (reserved leaves),
`0xBC80 NC_GAMBLE_DICE_TAISAI_BET_START_CMD { u32 0 (auto), dice }`, status 0. Same failure mode as Z06-B10 for a lost `0xBC79`.
`0xBC7D`/`0xBC7E` LARGE_AMOUNT req/ack have no zone handler.

---

## 5. Slot machines (`SlotMachine::*`, dept 47 cmd 200–221)

A slot-machine **cluster** (`SlotMachineCluster`, one per dealer NPC, game type 2) holds up to N **screens**
(`SlotMachineScreen`, one per seated player). Tables (loaders FUN_006239b0 / FUN_00624820 / FUN_00624270, Z01 §2.3):
`GBSMAll`, `GBSMCenter`, `GBSMGroup`, `GBSMLine` (pay tables for all-match, centre, group and line patterns), `GBSMBetCoin`
(coin per bet unit, machine types `GB_SlotMachine_01..03` *(pdb2017 enum GBSMBETTYPE)*), `GBSMCardRate` (symbol weights; symbols
`GBSMCard_HPPotion … KingSlime` *(pdb2017)*), `GBSMNPC` (per NPC: machine type, house cut ‰ …), `GBSMJPRate` (jackpot share).
Screen fields: `+0x18` machine id, `+0x1c` u16 coin per unit, `+0x20` state (0 idle, 1 started, 2 stopped), `+0x2c` start time,
`+0x34` bet (4 bytes = 8 lines × 3-bit unit counts), `+0x38` result screen (3 × 3 symbols + extra), `+0x43..+0x4c` win info.

```pseudo
0xBCC8 NC_GAMBLE_SLOTMACHINE_GAME_JOIN_REQ { u16 npc, u8 seat, u8 direction }                  @ FUN_0061e400
    reply 0xBCC9 NC_GAMBLE_SLOTMACHINE_GAME_JOIN_ACK { …, u16 err at +2 }
    no field 0x28C2; busy 0x28C3; already in a game 0x28C1; no machine / NPC 0x28C4; too far 0x28C5; closed 0x28C6; seat taken 0x28C7
    cluster.vt[0] go_Enter_Player (FUN_0061f0b0 → screen go_Enter_Player FUN_00620d00) fails → game type 0, 0x28C1
    else game type 2; 0xBC1C direction broadcast; cluster.go_SendGameInfo (FUN_00620b80: 0xBCC9 { 0x28C0 | 0x28D9 … })
0xBCCA …_GAME_LEAVE_REQ {} (FUN_0061e660): 0x28C9 / 0x28CA / 0x28CB → 0xBCCB; go_Out_Player FUN_0061f1d0
0xBCCC …_START_REQ { u8 bet[4] } (FUN_0061e870): screen = cluster.vt[0x28] (go_FindSubGambleObject FUN_0061eec0) by charNo;
    none → 0xBCCD { 0x28CE }; else screen.vt[0xdc] SMS_Start (FUN_0061f540): state ≠ 0 0x28D0; coins < unit × Σ line units 0x28D1;
    store bet, start time, state 1 → 0x28CF;  p ← 0xBCCD NC_GAMBLE_SLOTMACHINE_START_ACK { code }
0xBCCE …_STOPBUTTON_REQ {} (FUN_0061e980): screen.vt[0xe4] SMS_StopButton (FUN_00625340), state must be 1:
    result = SlotMachineScreenManager_smsm_Action (FUN_006228f0, global DAT_14d71160: random symbols by GBSMCardRate)
    win = all 8 lines bet and SlotMachineAnalyse_sma_AllMatch → AllMatch prize (and jackpot flag); else Σ per bet line
          (line bits 0..7) units × unit coin × sms_LineRate (FUN_00622800: sma_1LineMatch / sma_CenterMatch / group tables)
    jackpot: smjpr_JackpotAccumulate (FUN_00620250 / FUN_006201c0 on DAT_14d712a8), smjpr_GetJackpotPrice FUN_006200c0,
             winner broadcast 0xBCDD and reward item (see Jackpot below)
    win −= win × house cut ‰ / 1000   (cut from the global config DAT_14d712cc +4, see Jackpot below)
    GameDB 0xBCD3 NC_GAMBLE_SLOTMACHINE_DB_RESULT_REQ { ref, u16 lock, u32 charNo, char screen[9] ('0'–'9','A'… per symbol), u8 0,
           u8 jackpot, u32 jackpot total, u16 unit coin, u8 bet units, u16 machine, i32 prize }   *(field names ours; no 2016 PDB check)*
    coin reservation of (prize − stake); L.index++
    player action animation (go_PlayerAction 0xBC1E, win or lose motion); state 2
    p ← 0xBCCF NC_GAMBLE_SLOTMACHINE_STOPBUTTON_ACK { u16 code, screen (11 bytes) }   (no screen → 0xBCCF { 0x28CE })
0xBCD4 …_DB_RESULT_ACK (GameDB @ FUN_00620330) → p.vt[0xb50] so_ply_SlotMachineDBResult (FUN_00620560) →
    screen.vt[0xe0] (FUN_0061f6e0): state must be 2 (else 0x28D7); result 0x28D8 or 0x2900 = ok → apply; else free and that code
    p ← 0xBCCD { code }      (the START_ACK opcode carries the settlement result)
Jackpot (inside SMS_StopButton FUN_00625340, global slot config DAT_14d712cc):
    accumulation only when config +6 == 1; on a jackpot (flag +0x4c bit 2): prize += smjpr_GetJackpotPrice (FUN_006200c0),
    smjpr_JackPotRankingSet (FUN_00625000), p.vt[0xb54] so_ply_IBurstJackPot (FUN_00620410): map ← 0xBCDD
        NC_GAMBLE_SLOTMACHINE_SOMEONE_GET_JACKPOT_CMD { char name[20] (vt 0x56c), u64 jackpot, u32 … }  (so_AllInMap1),
    and a reward item: table DAT_14d70e38 row (0x1a, 0) (FUN_00620970) → ItemKey_Make(id, kind 0xB, zone, world) → Character DB
        0x344D NC_ITEMDB_CREATEITEMLIST_REQ (answer handled by Z05)
    the house cut (config +4 ‰) is applied **after** the jackpot is added (the jackpot is taxed too)
    prize == stake: no player motion
    if the player has no InventoryLocking (vt 0x7d4 null) the function returns after the reward item was requested; state stays 1
Idle kick (screen routine `go_Routine` FUN_00620de0, per tick while a player sits):
    now − start (+0x2c) > timeout (+0x24): p ← 0xBCD2 NC_GAMBLE_SLOTMACHINE_STAND_UP_CMD {} on **every tick** (so_SendProtocol)
        (original bug) Z06-B19: repeated every tick instead of once
    and once now − start > timeout + 600 (60 s more): p.vt[0x5fc] so_banning(0) — the player is disconnected
    otherwise every 100 ticks of g_Now (10 s): FUN_0061fe80 → p ← 0xBCD8 NC_GAMBLE_SLOTMACHINE_JACKPOTINFO_CMD
0xBCD0 …_WHEELSTOP_REQ (FUN_0061eaf0): screen SMS_WheelStop2/3 (FUN_0061f8c0 / FUN_0061f930: 0x28D4 / 0x28D7) → 0xBCD1
0xBCD9 …_JACKPOTRANKING_REQ (FUN_0061ec60, profiler string copied from WHEELSTOP) → 0xBCDA (SMS_PacketMake_JackpotRank FUN_00620ef0)
0xBCDB …_WINRANKING_REQ (FUN_0061ed90) → 0xBCDC (SMS_PacketMake_WintRank FUN_00624520)
0xBCD6 …_DB_GAMEINFO_ACK (GameDB @ FUN_00625d30) → smjpr_RankingSet FUN_00625130 (jackpot ranking from the DB; code 0x2940; list helpers FUN_00624460 / FUN_00623690)
    (requested by smjpr_RankingReq FUN_00626220 → 0xBCD5)
```

Client: the slot UI (`ITask:MHDiceGameTask` dispatcher, C01) plays `GB_SlotMachine.mp3`; `0xBCD8` and `0xBCD2` come from the
screen routine above.

---

## 6. Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z06-B1 | 0x4C1F trade commit (`tb_FillCen`) | equal money on both boards: `cen.from` of `0x343B` is not written | stale 'A'/'B' byte to the DB; title counters may run with 0 | write `from = 0` |
| Z06-B2 | 0x4C15 / 0x4C1F | board money is checked only when put on the board, not at commit | payer may have spent it meanwhile; `result_money_from` wraps below 0 (the DB must refuse) | re-check money at commit |
| Z06-B3 | booth errors (`sb_RefreshError`) | `0x680B` is 7 bytes but only `err` is written | boothhandle / numofitem are stale `g_buf` bytes | send 2 bytes or fill them |
| Z06-B4 | layer moves (`vt 0xdbc–0xdcc`) | booth closed without `BoothManager_CloseStore` | market search lists a closed booth; buying fails with 0xA42 | close the index entry too |
| Z06-B5 | 0x680D ITEMTRADE | busy inventory → `0x3004 {0x204}`; booth under repair → `0x3004 {0xA5B}` | the client shows an NPC-shop result instead of a booth error | `0x680E` |
| Z06-B6 | 0x680D (sell and buy booths) | `itemnum == 0` is not refused | 0-lot MERGE/SPLITCREATE requests to the DB, price 0 | refuse 0 |
| Z06-B7 | `sbs_SellSplitCreate` / `sbb_BuySplitCreate` | `PROTO_ITEM_CREATE.attr` not written | 2 uninitialised bytes to the DB | write it |
| Z06-B8 | buy booth trade | rest quantity lowered before the DB answer, never restored on failure | booth buys fewer items than announced | lower it on success |
| Z06-B9 | 0x6815 position search | error replies keep handle/xy from the last `g_buf` use | stale data on the wire (client ignores it on error) | zero them |
| Z06-B10 | 0xAC24 / 0xBC79 dice result | a refused/lost DB answer is ignored | every gamer's inventory stays locked until relog; the table stays in status 2 | free the locks and reset the table |
| Z06-B11 | mini-house TaiSai manual mode | no roll path: routine rolls only in auto mode, `0xAC20` not registered, `vt 0x260` uncalled | bets in manual mode never resolve | handle `0xAC20` |
| Z06-B12 | 0xBC13 COIN_SELL | GBHouse missing → error on `0xBC10` (BUY_ACK) | wrong client window | `0xBC14` |
| Z06-B13 | 0xBC0D VIPCARD | two errors sent as `0x300E` (dept 12) | client shows nothing / an unrelated item text | `0xBC0E` |
| Z06-B14 | 0xBC02 HOUSE_EXIT | unknown return map → `{0x2803}` sent with opcode `0xBC02` (the request) | client ignores it; player is moved anyway | `0xBC03` |
| Z06-B15 | 0x4C1F | `0x4C24 TRADECOMPLETE_CMD` is sent before the DB request | "Trade has been completed." then possibly "Trade has been failed." | send after `0x343D` |
| Z06-B16 | 0xAC28 LARGE_AMOUNT_REQ | empty stub, no answer | client request unanswered | implement or drop |
| Z06-B17 | `Result_DiceRoll` (both TaiSai) | first loop runs the bet-limit check and ignores the result | dead check | drop or enforce |
| Z06-B18 | buy booth `sb_Trade` FUN_0058ffe0 | owner-stack search accepts a stack whose lot already exceeds MaxLot | merge into an overfull stack (lot grows further) | require `lot + itemnum ≤ maxLot` |
| Z06-B19 | slot screen routine FUN_00620de0 | `0xBCD2 STAND_UP_CMD` sent on every tick after the timeout, then disconnect 60 s later | packet spam for 60 s | send once |

## 7. Not reconstructed / uncertain

- Slot machine internals: `smsm_Action` (FUN_006228f0) symbol draw, `sms_LineRate` patterns, jackpot accumulation/payout
  (`smjpr_*`), `0xBCD3` field meanings (named by us from the write order), the cluster routine (`go_Routine` FUN_0061f300,
  screen routine FUN_00620de0 with its 10 s timeout) and the `GBSM*` table columns were read only to the level in §5.
- TaiSai win tables: `FUN_00633920` (outcome → winning bet kinds with multiplicity, table DAT_13386e30 / DAT_13295b38),
  `FUN_00634230` (dividend) and `FUN_006342d0` were not read line by line; dividends follow `DiceDividind` groups *(inferred)*.
- `p+0x29310` / `p+0x2a5ac` (booth size summands) and `p+0x2a5aa` (inventory pages): writers not traced (charged items, Z07/Z13).
- Open-menu kinds 3, 4, 5, 6 are not identified.
- `0xBC1D` and `0x402C` WM records: zone side only; WM handling belongs to W04/W01.
- No capture covers these departments; all layouts come from code + PDB.

## 8. Coverage boundary

| Found (function / packet / table / behaviour) | Covered by | Argument |
|---|---|---|
| Character-server side of `0x343B`, `0x3453–0x3455`, `0xAC0C/0xAC10/0xAC17/0xAC23/0xAC25/0xAC2C`, `0xBC0A/0xBC11/0xBC15/0xBC6C/0xBC78/0xBC7A/0xBCD3/0xBCD5` | D03 (plan line 10: "Gamble/slot machine … safe trade … exist only in `w00_Character`") | DB procedures; this item documents the zone requests/answers |
| DB answers `0x343C/0x343D`, `0x3456` | Z05 §9.10 / §9.11 | already documented there; cited here |
| WM side of `0x10DD`, `0xBC01`, `0x402C` | W01 (documents the coin/prev-map blobs, FUN_00428ba0; its plan lists 0x10DC/0x402C) | WM handlers; zone side done in §4.1 |
| WM side of `0xBC1D` | W04 (its scope table lists 0xBC1D) | WM handler |
| WM sender of `0xBC09` (`CGambleSystemServer::SendExchangeCoinInit` FUN_0043c2d0, init FUN_0043c1a0: daily broadcast of the next reset time) | W04 (step added for it) | no WM item listed it; zone side is §4.1 |
| Title engine `FUN_005cb5f0`, `FUN_0062df60`, `FUN_0062e000`, `FUN_0062e0e0`, `FUN_0062e180`, `FUN_005cb0b0`, TaiSai title counters FUN_005cc490/FUN_005cc4c0 | Z07 (scope "titles") / Z12 (title progress) | Z06 only feeds counters 6/7 and the TaiSai win counter |
| `so_TentPoint` FUN_0058d260, `sp_MakeTentBriefInfo` | Z02 §7 | tent/camp rules shared with booths |
| `igc_ChargedDuringUse` FUN_00490630, lot getter FUN_004707e0, item struct helpers | Z04 (§1, §6) | item model |
| `sp_GuildStorageClose` FUN_00474b80 (via NPC range check) | Z08 / W03 | guild storage |
| FieldList lookup FUN_00647c00 / FUN_0063e160 | Z01 (server group / FieldList) | generic table lookup |
| GM commands `&ts_DiceFix`, `&ts_DiceProbability`, `&GB_DiceFix`, `&GB_DiceProbability` | Z11 (plan line 14 names "dice / TaiSai Z06": Z11 references §3.6 / §4.4) | command parsing is Z11; the effect is here |
| Drop-item dice game (`ShineDropItem::so_DiceItemPickInit` FUN_00531020, `sd_DiceGameResult` FUN_00531470, `0x303B/0x303E/0x303F`, `BelongDice.shn`) and party/raid loot `FUN_00644f60` | Z09 (step added for it) | loot distribution of mob drops, not the TaiSai/gamble game; Z09's plan does not name it, so the status file asks Z09 to take it |
| Item actions (`ItemAction*.shn`, `vt 0x5d0`) and costume weapon/shield charges (`sp_CostumWeaponChargeDecrease_*`, FUN_00562160) | Z17 (new item) | Z03 pointed them to Z06, but they are combat/item effects, not trade or gambling; no item lists them |
| `UseItemCoin::uib_AfterCast` (coin item use) | Z04 §6 | item use; its DB answer `0xBC1A` is in §4.2 |
| Guild-tournament dice `FUN_0047af20`, `PineEventScriptNode::ShineDiceGameStart` | Z16 / Z09 | other dice games (GT, map scripts) |
| Mini-house object generally (enter/out, furniture) | Z13 | Z13's plan mentions "the in-house dice game state (vt 0x2a0, player vt 0x170/0x190/0x194)": documented here in §3, Z13 can cite it |
