# Zone server: character stats, progression, pets, mounts, mini-house, collection cards (Z07)

**Status: in progress (session 1 stopped early).** Only §1 (stat points) is written. See `docs/plan/status/Z07.md`.

Source: `Files/Server/2016/w00_Zone00/5ZoneServer2.exe`, export `re-data/exports/zone`. Each block cites the function
(`@ FUN_xxxxxxxx`); names are the original profiler strings (Z01 names file) unless marked *(ours)*.
Core facts (objects, send primitives, player modes, `g_Now` in tenths of a second) are in `Z01-core.md`–`Z04-items.md`.

---

## 1. Stat points (free stats)

### 1.1 Data

| Member | Meaning |
|---|---|
| `p+0x7f94 … p+0x7f98` | u8 × 5 points spent on stat 0…4 (STR, END, DEX, INT, SPR *(inferred: order of the client stat window)*) |
| `p+0x7f99` | u8, decremented by a DEC success (restat-item counter?) *(inferred)* |
| `p+0x5e0c` | u8 "free stat locked" flag: `vt 0xac8` get (FUN_0055a650), `vt 0xacc` set (FUN_0055a660), `vt 0xad0` clear (FUN_0055a670). Set while a DB request is in flight. |
| `p+0xfbc` | class object; `.vt[0x38]()` = column index into the level table |
| `DAT_0da50968[level]` | per-level row; `u16 row[0x33 + 2*classIdx]` = **total stat points available at that level for that class** = `MaxStat` *(ours: `FreeStat_Max`, FUN_00517cc0)* |
| `DAT_0da504a9` | u8 cap per single stat |

`FreeStat_Spent(p)` *(ours)* @ FUN_0044a980 = sum of the five bytes. After any change, `FUN_00517b60(p+0xfc0, class, p)`
recomputes the stat matrix (Z03 §2), then `vt 0x528` sends the parameter refresh.

### 1.2 NC_CHAR_STAT_INCPOINT_REQ `0x105C` (C→Z) @ FUN_0058ad10

Payload `{u8 stat}` *(pdb2017 `PROTO_NC_CHAR_STAT_INCPOINT_REQ`, confirmed)*.

```pseudo
if mode ∉ {1,2,4,6} (mask 0x56): so_SendErrorCode(4, 0x61, 0xAC7); return
max = FreeStat_Max(p)
if FreeStat_Spent(p) >= max:          SendErrorCode(4, 0x61, 0xAC2)   // "above remain point"
elif stat > 4:                        SendErrorCode(4, 0x61, 0xAC3)   // invalid stat
elif free-stat locked (vt 0xac8):     SendErrorCode(4, 0x61, 0xAC7)
else:
    build 0x10D1 NC_CHAR_FREESTAT_SET_DB_REQ:
        ref {u16 p.handle, u32 charNo}, u8 nMaxStat = max, u8 nFreeStat[5] = p+0x7f94.., +0xe lockindex = stale g_buf (not set),
        u8 nItemNum = 0
    if nFreeStat[stat] < max:  nFreeStat[stat] += 1; send 17 bytes to GameDB; lock (vt 0xacc)
    else:                      SendErrorCode(4, 0x67, 0xAC2)   // note: cmd 0x67 (DEC) on an INC request (original bug)
```

The 2016 zone does **not** use the dedicated `0x105D NC_CHAR_STAT_INCPOINT_DB_REQ`; INC and DEC both send the full
target array in `0x10D1`. The per-stat cap `DAT_0da504a9` is not checked here, only in the unused `so_ply_StatIncrease`.
Bytes `+0xe..+0xf` (lockindex) are left from the previous packet in `g_buf` (original bug, harmless: nItemNum = 0).

### 1.3 NC_CHAR_STAT_DECPOINT_REQ `0x1062` (C→Z) @ FUN_0058b3f0

Payload `{u8 stat}`. Lowering a stat needs a restat item (`DAT_14d50494` = item id, searched in inventory 9 with
`ItemBoxIterIdent`, FUN_004879d0).

```pseudo
if mode ∉ mask 0x56: return silently                 // no error packet, unlike INC
if free-stat locked: SendErrorCode(4, 0x67, 0xAC7); return
cell = first unlocked inventory cell holding item DAT_14d50494
if none / cell null / attribute class null: SendErrorCode(4, 0x67, 0xAC6); return
lot = attrClass.GetLot(cell.attr)
0x10D1: ref, nMaxStat = FreeStat_Max(p), nFreeStat[5] = current
if stat > 4:            SendErrorCode(4, 0x67, 0xAC3)
elif nFreeStat[stat]==0:SendErrorCode(4, 0x67, 0xAC5)   // already 0
else:
    nFreeStat[stat] -= 1; nLockIndex = p+0xfaac; nItemNum = 1
    DecItemInfo { u8 isDelete, u64 key, u16 itemId, u8 count = 1 }
    if lot < 2: isDelete = 1, locking.ClearCell(lockIndex, cell)            // vt 0x30
    else:       isDelete = 0, SetLot(lot-1), locking.Replace(lockIndex, cell) // vt 0x40
    send 29 bytes to GameDB; ++p+0xfaac; lock free stat
```

### 1.4 NC_CHAR_FREESTAT_SET_DB_ACK `0x10D2` (DB→Z) @ FUN_0058be50

```pseudo
p = som_GetObject(ref.handle); require charNo match and not closing
isDec = vt 0xac4(…)  // FUN_0055a5d0: sum of (current − new) over the 5 stats > 0  (some stat went down)
isDec ? FreeStat_ApplyDec (vt 0xad8, FUN_0058a9d0) : FreeStat_ApplyInc (vt 0xad4, FUN_0058a7e0)
unlock free stat (vt 0xad0)
```

Answer fields used: `+6 u8 newStat[5]`, `+0xb u16 lockIndex`, `+0xd u16 result` (`0xAC1` = OK).

- **ApplyInc** @ FUN_0058a7e0: result ≠ 0xAC1 → `SendErrorCode(4,0x61,result)`. Sum > max → `0xAC2`; a single value > max →
  `(4,0x67,0xAC3)`. Otherwise copy the 5 values, recompute, send `0x105F NC_CHAR_STAT_INCPOINTSUC_ACK {u8 stat}`
  (stat = first index whose value rose; if none, an uninitialised byte (original bug)), parameter refresh.
- **ApplyDec** @ FUN_0058a9d0: result ≠ 0xAC1 → release the lock index (locking vt 0x28), `SendErrorCode(4,0x67,result)`.
  Commits the item lock (vt 0x1c, logs on failure), same checks (sum check failure answers `(4,0x61,0xAC2)`), copies,
  recomputes, sends `0x1065 NC_CHAR_STAT_DECPOINTSUC_ACK {u8 stat}` (same uninitialised fallback).

### 1.5 Legacy DB answers `0x105E` / `0x1060` / `0x1064` / `0x1066` (DB→Z)

Still registered: @ FUN_0058afd0 INCPOINTSUC → `vt 0x7ec` `so_ply_StatIncrease` (FUN_0058b0c0: +1 to `stat` at `+6` if spent < max
and the stat < `DAT_0da504a9`, then `0x105F`); @ FUN_0058b300 INCPOINTFAIL → `SendErrorCode(4,0x61,u16 @+8)`; @ FUN_0058b850
DECPOINTSUC → `vt 0x7f0` (FUN_0058b940, profiler name says StatIncrease, logs say StatDecrease: −1, `p+0x7f99 −= 1`, `0x1065`);
@ FUN_0058bc20 DECPOINTFAIL → `SendErrorCode(4,0x67,u16 @+10)`. Since the zone only sends `0x10D1`, these are reached only if
the Character server still answers the old requests *(inferred: dead in 2016)*.

### 1.6 NC_CHAR_CLASSCHANGE_ACK `0x1057` (DB→Z) @ FUN_004520d0

charNo match → `so_ply_ClassChange(u8 @+8)` (`vt 0x6c8`, FUN_004521b0, not read yet).

### 1.7 Tutorial DB answers

- `0x1119` NC_CHAR_TUTORIAL_STEP_SAVE_ACK @ FUN_00468a60: player by charNo (`+2`); if alive and a tutorial script object exists
  (FUN_004013d0), fire script event 0x3c with `u8 @+10` (FUN_00463ae0).
- `0x111B` NC_CHAR_TUTORIAL_FREESTAT_INIT_ACK @ FUN_00468b70: player by charNo; result `u16 @+6` = `0x31ED` → disconnect with reason
  0x31ED; else `so_ply_InitFreeStat` (`vt 0x378`); unlock free stat.

### Result codes (dept 4)

`0xAC1` ok, `0xAC2` no points left / too many, `0xAC3` invalid stat, `0xAC5` stat already 0, `0xAC6` no restat item, `0xAC7` wrong mode / locked.
Client texts: not yet resolved against `client-error-codes.json`.

---

## Original-server bugs (so far)

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z07-B1 | 0x105C | per-stat-full error sent with cmd 0x67 (DEC) | client shows it under the wrong request | cmd 0x61 |
| Z07-B2 | 0x105C | `lockindex` bytes of 0x10D1 not written (stale `g_buf`) | harmless, no item | write 0 |
| Z07-B3 | 0x10D2 | success `stat` byte uninitialised when no value changed | random stat index to client | send a fixed value |
| Z07-B4 | 0x1062 | wrong mode → no reply at all | client waits | send 0xAC7 like INC |

## Not reconstructed / uncertain

Everything outside §1: revive, logout ready/cancel, wedding, depolymorph, link save, auto-pick, rebirth, tutorial step,
minimon items, charged buff erase, all of MINIHOUSE / COLLECT / MOVER / PET, the WM blob handlers 0x101D…0x1130, the Z02
open questions (wedding, production). Stat names of index 0–4 and the meaning of `p+0x7f99` are *(inferred)*.
