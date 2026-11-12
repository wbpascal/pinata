# Zone server: character data, stats, progression, wedding, mini-house, collection cards, mounts, pets (Z07)

Source: `Files/Server/2016/w00_Zone00/5ZoneServer2.exe`, export `re-data/exports/zone`. Each block cites the
function it was reconstructed from (`@ FUN_xxxxxxxx`); view one with
`python3 -I tools/protocol-re/clean.py re-data/exports/zone tools/protocol-re/names/zone <addr>`.
Function names are the original profiler strings (Z01 names file) unless marked *(ours)*; Z07's additions are in
`tools/protocol-re/names/zone/Z07.json`. Opcode names: `docs/protocol/opcodes.json`. Packet layouts:
[`../../protocol/annotations/Z07.json`](../../protocol/annotations/Z07.json).
Core facts (objects, send primitives, player modes, `g_Now` in tenths of a second, the `ref` header of server-link
messages, stat matrix, inventory locking) are in [`Z01-core.md`](Z01-core.md)–[`Z04-items.md`](Z04-items.md) and
`docs/knowledge/Z01.md`–`Z04.md`; this file does not repeat them.

Conventions: `p` = the player. `SendErrorCode(dept, cmd, code)` = `vt 0x308`, a 2-byte `{u16 code}` packet with opcode
`dept<<10|cmd`. "→ DB" = a request to the Character server over a GameDB session (`SessionPool_Pick(g_GameDBSessions)`);
"→ WM" = to the World Manager. Server-link messages start with the 6-byte `ref {u16 handle, u32 charNo}`; field offsets
below are **payload** offsets (packet offset − 2).

---

## 1. Character data at login (WM → zone)

### 1.1 The character block inside ShinePlayer

`p+0x7f3d` holds a copy of the `NC_CHAR_ZONE_BASE_CMD` body, laid out as the 2017 `PROTO_NC_CHAR_BASE_CMD` *(pdb2017,
every offset below confirmed by a 2016 accessor)*:

| `p+` | BASE_CMD field | Accessor / user |
|---|---|---|
| 0x7f3d | u32 chrregnum (charNo) | `vt 0x344` |
| 0x7f41 | Name5 charid | logs, `so_charbasedata` |
| 0x7f56 | u8 Level | `vt 0x4d8` GetLevel |
| 0x7f57 | u64 Experience | `vt 0x438` |
| 0x7f67 | u32 CurHP | `vt 0x4e8`, revive sets it |
| 0x7f77 | u64 Cen (money) | `vt 0x434` |
| 0x7f7f | LoginLocation (map, xy) | so_LinkTo |
| 0x7f94 … 0x7f98 | `CHARSTATDISTSTR` Strength, Constitute, Dexterity, Intelligence, MentalPower (spent stat points) | §2 |
| 0x7f99 | `CHARSTATDISTSTR.RedistributePoint` | decremented by the legacy DEC success (§2.5) |
| 0x7f9f | u16 prisonmin | Z01 |
| 0x7fa1 | u8 adminlevel | `vt 0x4d4` |

### 1.2 Blob handlers

Every handler below: `p = som_GetObject(ref.handle)`; require `p`, `p.charNo == ref.charNo` and `!p.IsClosing`;
then call one ShinePlayer method with the body (payload +6). "disc" = on a bad `ref` the handler logs
"… : Invalid player" and, when `p` exists, `so_Disconnect(0x689, 0, 0)`.

| Opcode | Name | Handler | Method called (`vt`) | On bad ref |
|---|---|---|---|---|
| 0x101F | NC_CHAR_ZONE_BASE_CMD | @ FUN_0044ab90 | 0x674 `so_charbasedata` @ FUN_0044d890 (copies to `p+0x7f3d`; logs to `RegistNumberLog` when the charNo differs) | log only |
| 0x1020 | NC_CHAR_ZONE_SHAPE_CMD | @ FUN_0044ad70 | 0x678 `so_charsharpdata` (sic) @ FUN_0044ae80 | disc |
| 0x1021 | NC_CHAR_ZONE_QUEST_DOING_CMD | @ FUN_0044af80 | 0x67c `so_StoreQuestDoing` | disc |
| 0x1022 | NC_CHAR_ZONE_QUEST_DONE_CMD | @ FUN_0044b090 (profiler string `…ZONE__DONE_CMD`) | 0x680 `so_StoreQuestDone` | disc |
| 0x10CD | NC_CHAR_ZONE_QUEST_READ_CMD | @ FUN_0044b1a0 | 0x684 `so_StoreQuestRead` @ FUN_0044b640 | disc |
| 0x10D6 | NC_CHAR_ZONE_QUEST_REPEAT_CMD | @ FUN_0044b2b0 (profiler string says `…QUEST_READ_CMD`) | 0x688 @ FUN_0044b770 (also named `so_StoreQuestRead`) | disc |
| 0x1023 | NC_CHAR_ZONE_ABSTATE_CMD | @ FUN_0044b8b0 | 0x68c `so_CharAbstateData` | disc |
| 0x1024 | NC_CHAR_ZONE_SKILL_CMD | @ FUN_0044be10 | 0x690 `so_charskilldata` | disc |
| 0x1025 | NC_CHAR_ZONE_PASSIVE_CMD | @ FUN_0044bbe0 | 0x698 `so_charpassivedata` | disc |
| 0x1029 | NC_CHAR_ZONE_GUILD_CMD | @ FUN_0044b9c0 | 0x81c (FUN_0055a1f0) with `u32 body[0]` = guild number | disc |
| 0x1098 | NC_CHAR_GUILD_ACADEMY_ZONE_CMD | @ FUN_0044bad0 | 0x860 (FUN_0055a530) with `u32 body[0]` = academy number | disc |
| 0x102E | NC_CHAR_ZONE_ITEM_CMD | @ FUN_0044c350 | 0x69c `so_StoreInventoryFromServer` | disc |
| 0x102F | NC_CHAR_ZONE_CHESTINFO_CMD | @ FUN_0044c740 (profiler string `GameDBSession::wms_…`) | 0x6c4 `so_ply_Getchestinform` | disc |
| 0x1030 | NC_CHAR_ZONE_GAME_CMD | @ FUN_0044c110 | 0x6a0 `so_Storegamedata` | disc |
| 0x1032 | NC_CHAR_ZONE_CHARGEDBUFF_CMD | @ FUN_0044bcf0 | 0x694 `so_CharChargedBuffData`, then `so_allparametercalculate` | disc |
| 0x10D0 | NC_CHAR_ITEMACTIONCOOLTIME_ZONE_CMD | @ FUN_0044e710 | see below | disc |
| 0x10CB | NC_CHAR_GET_CHAT_BLOCK_SPAMER_CMD | @ FUN_0044c9b0 | 0xab4 (FUN_0044a9b0) | log only |
| 0x10E3 | NC_CHAR_ZONE_CARDCOLLECT_CMD | @ FUN_0044cef0 | 0xbfc `so_ply_CardCollect` (album, §6) | log only |
| 0x10E6 | NC_CHAR_ZONE_CARDCOLLECT_BOOKMARK_CMD | @ FUN_0044d090 | 0xc00 `so_ply_CardCollectBookMark` | log only |
| 0x10E9 | NC_CHAR_ZONE_CARDCOLLECT_REWARD_CMD | @ FUN_0044d230 | 0xc04 `so_ply_CardCollectReward` (rewarded ids → `p+0x2aab4`) | log only |
| 0x1115 | NC_CHAR_TUTORIAL_INFO_ZONE_CMD | @ FUN_0044d3d0 | 0xdf8 (FUN_00561500) → tutorial info `p+0x2ab44` | log only |
| 0x111F | NC_CHAR_ZONE_CHAT_COLOR_CMD | @ FUN_0044d4a0 | 0xe30(`u8 body[0]`), 0xe38(`u8 body[1]`) (chat colour, Z04 §12.8) | log only |
| 0x1122 | NC_CHAR_USEITEM_MINIMON_INFO_ZONE_CMD | @ FUN_005a5d80 | 0xe50 (FUN_005617c0): minimon auto-use lists (§4.1) | log only |
| 0x1130 | NC_CHAR_SELL_ITEM_INFO_ZONE_CMD | @ FUN_005a5e80 | 0xe64 (FUN_00537930): repurchase list (Z04 §2.5) | log only |
| 0x10DD | NC_CHAR_ZONE_COININFO_CMD | @ FUN_00617830 (profiler string `wms_NC_GAMBLE_ZONE_PREVMAPNAME_CMD`, copy-paste) | 0xb00 (FUN_00615d10) gamble coins (Z08) | log only |
| 0xCC0C | NC_MOVER_LINKDATA_ZONE_CMD | @ FUN_005a5ac0 | 0xc88 (FUN_0045ddf0) with the whole payload: mount state carried across a map link | log only |
| 0x104C | NC_CHAR_REGISTNUMBER_ACK | @ FUN_0044aa60 | 0x2ec `so_SetRegistNumber` (Z01 §4) | — |

```pseudo
0x10D0 NC_CHAR_ITEMACTIONCOOLTIME_ZONE_CMD { u16 count, {u16 group, i64 endTime(time64)} × count }   @ FUN_0044e710
    cool = p.vt[0x5d0]()                        # item-action cooldown container (Z06)
    now = _time64()
    for each entry: row = ItemActionGroup(DAT_14d6fc84)[group]
        if entry.endTime > now and row: cool.Set((endTime − now) × 1000 ms, row+8, row+0)      # FUN_005d1b60

0x10D3 NC_CHAR_ZONE_SINGLE_OPTION_CMD { ref(u16, u32 charNo), …, +0xa {6 bytes}, +0xe u8, +0xf u8, +0x10 u32, +0x14 u8 }   @ FUN_005a6200
    if charNo == −1: return; p = som_FindPlayer(charNo); alive and a ShinePlayer
    if body+0x14: apply the 6-byte block at +0xa (FUN_0059d510, key-map / shortcut options)                  (inferred)
    FUN_00560340(p, u8 +0xe)        # auto-pick flag (cf. §3.6)        (inferred)
    FUN_00560a10(p, u8 +0xf); p.vt[0xae8](u32 +0x10)

0x10B8 NC_CHAR_ZONE_LINK_FROM_CMD { …, +6 u32 charNo, +0xa 12 bytes map, +0x16 u32 x, +0x1a u32 y }   @ FUN_00476600
    p = som_FindPlayer(charNo); if p: store a 0x68-byte "linked from" record (FUN_00444970) with that map/xy (FUN_00570b30)

0x1120 NC_CHAR_SUPPORT_REWARD_CMD { u32 charNo, u32 userType }   @ FUN_005a5c70
    p = som_FindPlayer(charNo)
    userType 1: nothing; 2: set abstate 0x2D8 StaE_UserNewbie01; 3: set abstate 0x2DD StaE_UserComeback_Main01
    (via p.vt[0x644](p, idx, 1, 1)); other: log "Invalid User Type"
```

### 1.3 NC_CHAR_ZONE_CHARTITLE_CMD `0x1031` (WM → zone) @ FUN_005a39f0

Body: `+7 u8 CurrentTitle, +8 u8 CurrentTitleElement, +9 u16 CurrentTitleMobID, +0xb 0x80 × u64 title progress,
+0x40b u16 NumOfTitle, +0x40d {u8 Type, u8 ElementNo:6, u8 flags:2} × NumOfTitle`.

```pseudo
if NumOfTitle >= 0x200: log "Too many titles"; return
p = som_GetObject(ref.handle) (charNo not compared); must not be closing
t = p.vt[0x420]()                           # CharTitle block (Z01: p+0x29638)
t.Reset (FUN_005ca620); t.current = {Type, Element, MobID}
if body+6 == 0: per title type i < 128: progress[i] = (FUN_0062e120 says "reset" for i) ? 0 : body value     (inferred: daily/limited titles)
else:           copy all 128 progress values
for each title: if (Type, Element) == current: set its 2 flag bits (0xC0) (= "in use")
    t.Add(Type, Element, flags) (FUN_005ca6d0); also append {Type, Element} to t+0x88 (list for the brief info)
t.count = NumOfTitle
p ← 0x1049 NC_CHAR_CLIENT_CHARTITLE_CMD { u8 CurrentTitle, u8 CurrentTitleElement, u16 MobID, u16 NumOfTitle, {u8, u8} × N }
```

### 1.4 NC_CHAR_ZONE_CHARDATA_ACK `0x101D` / CHARDATAFAIL_ACK `0x101E` (WM → zone)

```pseudo
0x101D CHARDATA_ACK:                                     @ FUN_005a3590
    p = som_GetObject(ref.handle) and not closing; else log "Invalid Object"; return
    p.vt[0x4b4](handle, "…")                            # build the character from the blobs (Z01 §4, FUN_0055ab60)
    ti = p.vt[0xdfc]()  (tutorial info, p+0x2ab44); if ti.state == 0 (tutorial not done):
        if p.vt[0xdf4]() == 0 (no free tutorial map instance):
            log "Not Find Empty TutorialMap"; p ← 0x1804 NC_MAP_LOGINFAIL_ACK { u16 0x31EC, u8 0xFF }   (falls through and continues)
    if so_MapMarking(p, 0) fails:
        so_Unmark(0,1,3); if so_MapMarkingAtDefaultCoord(p) fails: p ← 0x1804 { u16 0x0142, u8 0xFF }; ToNormalLoc(2); return
    p.vt[0x4c0]()                                       # position snapshot
    so_allparametercalculate()                          # stat matrix (Z03 §2)
    p ← 0x1802 NC_MAP_LOGIN_ACK = so_fill_PROTO_NC_CHAR_MAPLOGIN_ACK (FUN_005a3140) { u16 handle, CHAR_PARAMETER_DATA, xy }

0x101E CHARDATAFAIL_ACK:                                 @ FUN_005a3440
    p alive: p ← 0x1804 { u16 ref.handle (as the error code field!), u8 0xFF }      (original bug)
    else log "Invalid ClientHandle"
```

The tutorial-map failure sends `0x1804` and then still logs the player in (original bug: the client leaves the login
scene on 0x1804 while the server continues).

### 1.5 CHAR_PARAMETER_DATA (in 0x1802 and the parameter refresh) @ FUN_005a2e00 `so_fill_CHAR_PARAMETER_DATA`

Answers Z01's open question. Struct = `CHAR_PARAMETER_DATA` (0xE8 bytes, *pdb2017*, size confirmed by the 0x1802 length);
`SHINE_CHAR_STATVAR = {u32 base, u32 change}`. Stat matrix rows (Z03 §2): `param[layer*0xcc + stat*4]` at `p+0xfc0`.

```pseudo
p.vt[0x34](0)                                         # smo_NotifyParameterChange
lv = level
PrevExp = g_LevelExp[lv] (u64 table at DAT_0da504a8, 8 bytes per level); NextExp = g_LevelExp[lv + 1]
for (field, stat) in [Strength 0, Constitute 1, Dexterity 2, Intelligence 3,
                      MentalPower 4, WClow 5, WChigh 6, AC 7, TH 8, TB 9, MAlow 10, MAhigh 11, MR 12, MH 13, MB 14]:
    field.base   = matrix[layer 0][stat]              # p+0xfc0 + stat*4
    field.change = matrix[layer 15][stat]             # p+0x1bb4 + stat*4 (total)
Wizdom (+0x30): not written (stale bytes of the caller's buffer) (original bug, the stat is unused)
MaxHp = FUN_0054a670(p); MaxSp = FUN_0055a8b0(p); MaxLp = p.vt[0xd94](); MaxAp = 0
row = class data (p.vt[0x49c]() + 0x10858)[min(lv, 0x96) or 0]
MaxHPStone = p+0x2a5a2 × row+0x20 / 1000; MaxSPStone = p+0x2a5a4 × row+0x2c / 1000
PwrStone, GrdStone, PainRes, RestraintRes, CurseRes, ShockRes = 0
```

So matrix stats 0–14 are STR, END, DEX, INT, SPR, WC min, WC max, AC, TH, TB, MA min, MA max, MR, MH (magic hit), MB
(magic block), and layer 15 is the displayed total (confirms Z03 §2).

---

## 2. Stat points (free stats)

### 2.1 Data

| Member | Meaning |
|---|---|
| `p+0x7f94 … p+0x7f98` | points spent on Strength, Constitute, Dexterity, Intelligence, MentalPower (stat 0…4) |
| `p+0x7f99` | RedistributePoint |
| `p+0x5e0c` | "free stat locked" while a DB request is in flight: `vt 0xac8` get (FUN_0055a650), `vt 0xacc` set, `vt 0xad0` clear |
| `p+0xfbc` | class object; `.vt[0x38]()` = column index into the level table |
| `DAT_0da50968[level]` | per-level row; `u16 row[0x33 + 2*classIdx]` = total stat points at that level = `FreeStat_Max` *(ours)* @ FUN_00517cc0 |
| `DAT_0da504a9` | u8 cap per single stat (only used by the legacy path). It is byte 1 of `g_LevelExp` (DAT_0da504a8), i.e. inside the level-0 entry of the exp table *(inferred: the loader keeps a header there)* |

`FreeStat_Spent(p)` *(ours)* @ FUN_0044a980 = sum of the five bytes. After a change, `FUN_00517b60(p+0xfc0, class, p)`
recomputes the base layer and `vt 0x528` sends the parameter refresh.

### 2.2 NC_CHAR_STAT_INCPOINT_REQ `0x105C` (C→Z) `{u8 stat}` @ FUN_0058ad10

```pseudo
if mode ∉ {1,2,4,6} (mask 0x56): SendErrorCode(4, 0x61, 0xAC7); return
max = FreeStat_Max(p)
if FreeStat_Spent(p) >= max:          SendErrorCode(4, 0x61, 0xAC2)   # "Try to increase above remain point"
elif stat > 4:                        SendErrorCode(4, 0x61, 0xAC3)
elif free stat locked:                SendErrorCode(4, 0x61, 0xAC7)
else:
    0x10D1 NC_CHAR_FREESTAT_SET_DB_REQ { ref, u8 nMaxStat = max, u8 nFreeStat[5] = current,
                                         u16 nLockIndex (not written: stale g_buf), u8 nItemNum = 0 }
    if nFreeStat[stat] < max: nFreeStat[stat] += 1; → DB (17 bytes); lock free stat
    else: SendErrorCode(4, 0x67, 0xAC2)            # DEC opcode on an INC request (original bug)
```

The 2016 zone never sends the dedicated `0x105D NC_CHAR_STAT_INCPOINT_DB_REQ`; INC and DEC both send the full target
array in `0x10D1`.

### 2.3 NC_CHAR_STAT_DECPOINT_REQ `0x1062` (C→Z) `{u8 stat}` @ FUN_0058b3f0

Lowering a stat consumes one restat item (`DAT_14d50494`, found with `ItemBoxIterIdent` over inventory 9, FUN_004879d0).

```pseudo
if mode ∉ mask 0x56: return                           # no reply (original bug)
if free stat locked: SendErrorCode(4, 0x67, 0xAC7); return
cell = first unlocked inventory cell with item DAT_14d50494; none / null cell / null attribute: SendErrorCode(4, 0x67, 0xAC6)
0x10D1 { ref, nMaxStat = max, nFreeStat[5] = current }
if stat > 4: 0xAC3; elif nFreeStat[stat] == 0: 0xAC5            (SendErrorCode(4, 0x67, …))
else:
    nFreeStat[stat] −= 1; nLockIndex = p+0xfaac; nItemNum = 1
    DecItemInfo { u8 isDelete, u64 key, u16 itemId, u8 count = 1 }
    lot = GetLot(cell): lot < 2 → isDelete = 1, locking.ClearCell (vt 0x30); else isDelete = 0, SetLot(lot − 1), locking.Replace (vt 0x40)
    → DB (29 bytes); ++p+0xfaac; lock free stat
```

### 2.4 NC_CHAR_FREESTAT_SET_DB_ACK `0x10D2` (DB→Z) @ FUN_0058be50

Body *(pdb2017, confirmed)*: `+6 u8 nFreeStat[5], +0xb u16 nLockIndex, +0xd u16 nErrorType (0xAC1 = ok)`.

```pseudo
p by ref; charNo match; not closing
isDec = FUN_0055a5d0(p, new[0..4]) != 0            # sum of (current − new) where positive
isDec ? FreeStat_ApplyDec (vt 0xad8, FUN_0058a9d0) : FreeStat_ApplyInc (vt 0xad4, FUN_0058a7e0)
unlock free stat

ApplyInc: err ≠ 0xAC1 → SendErrorCode(4,0x61,err)
          sum(new) > max → (4,0x61,0xAC2); any new[i] > max → (4,0x67,0xAC3)
          stat = first i with current[i] < new[i] (else an uninitialised byte (original bug))
          copy new values, recompute, p ← 0x105F NC_CHAR_STAT_INCPOINTSUC_ACK { u8 stat }, refresh
ApplyDec: err ≠ 0xAC1 → locking.Release(lockIndex) (vt 0x28), SendErrorCode(4,0x67,err)
          commit the item lock (vt 0x1c; failure only logged), same checks (sum check answers (4,0x61,0xAC2)),
          copy, recompute, p ← 0x1065 NC_CHAR_STAT_DECPOINTSUC_ACK { u8 stat }, refresh
```

Result codes (dept 4; the 2016 client's `StatPointReqTask` shows no text for them): `0xAC1` ok, `0xAC2` no points /
too many, `0xAC3` invalid stat, `0xAC5` already 0, `0xAC6` no restat item, `0xAC7` wrong mode / locked.

### 2.5 Legacy answers `0x105E` / `0x1060` / `0x1064` / `0x1066` (DB→Z)

Still registered: INCPOINTSUC @ FUN_0058afd0 → `so_ply_StatIncrease` (vt 0x7ec, FUN_0058b0c0: +1 to the stat at `+6` if
spent < max and the stat < `DAT_0da504a9`, then 0x105F); INCPOINTFAIL @ FUN_0058b300 → `SendErrorCode(4,0x61,u16 +6)`;
DECPOINTSUC @ FUN_0058b850 → vt 0x7f0 (FUN_0058b940, profiler string also "StatIncrease": −1 on the stat,
`RedistributePoint −= 1`, 0x1065); DECPOINTFAIL @ FUN_0058bc20 → `SendErrorCode(4,0x67,u16 +8)`. The zone never sends
the matching requests, so these are dead in 2016 *(inferred)*.

### 2.6 Related DB answers

```pseudo
0x1057 NC_CHAR_CLASSCHANGE_ACK { ref, u8 newclass }:            @ FUN_004520d0
    charNo match → so_ply_ClassChange(newclass) (vt 0x6c8, FUN_004521b0; class-change item flow in Z04 §12.10)
0x1119 NC_CHAR_TUTORIAL_STEP_SAVE_ACK { u32 charNo, TUTORIAL_INFO { u32 state, u8 step } }:   @ FUN_00468a60
    p = som_FindPlayer(charNo), alive; field script object (FUN_004013d0) with a handler → script event 0x3c (step) (FUN_00463ae0)
0x111B NC_CHAR_TUTORIAL_FREESTAT_INIT_ACK { u32 charNo, u16 nError }:   @ FUN_00468b70
    nError == 0x31ED → so_Disconnect(0x31ED); else so_ply_InitFreeStat (vt 0x378); unlock free stat
```

---

## 3. Revive, logout, polymorph and other CHAR requests

### 3.1 NC_CHAR_REVIVE_REQ `0x104E` (C→Z, no payload) @ FUN_00452980 → FUN_00451bd0 `sp_ReviveReqProcess`

The death-menu "revive" choice. (Item/skill revives are `sp_ReviveNow`, Z03/Z04.)

```pseudo
if mode ≠ 3 (dead) or no field: return
p.battle.timers (+0x2aa4c auto-revive, +0x2aac4, +0x2aac8) = 0
clear p's g_ShelterItem entry (abstates kept for an item revive)
kq = KingdomQuest of this field (field+0x3c); reviveCount = kq ? kqe_ReviveNumber(kq, &reviveHere) : 0
knockDowns = this player's KQ knock-down count
if (reviveCount == 0 or reviveCount <= knockDowns) and the field is not a "revive in place" map (FUN_00475770 false):
    "Revive City": target = this map's own regen point: MapInfo row RegenXA/YA…, index FUN_00427c30(RegenSpot)
        (< 4 → point [i], else point 0); in a guild-tournament field, the team's point (FUN_00478df0) instead
    link target map = current map
else:
    "Revive Here": target map = g_ServerGroup regen city of this map (FUN_0063e160)
        reviveHere (KQ) → current position
        else MapInfo regen spot of that city (RegenSpot < 2 → MapInfo xy +0x32/+0x36; else FieldList Regen point [i]);
             guild tournament / KQ team points override (kq+0x16d + team*8 for team < 2)
    reset battle stats (vt 0x428)[0]; guild tournament: FUN_0047a260
smo_SetCaptivate(0) (vt 0xf1c); p+0x5cb8 |= 1; mode = 1
restore saved shape (p+0x292ac → brief +0x25) if p+0x292d7
HP = MaxHP × 0x133 / 1024 (≈ 30 %); p+0x1d7c = 0; so_CloseTradeMenu
restore the abstates kept in g_ShelterDie, then clear the entry
so_LinkTo(target, 4, 0x4F, 0x50)                     # opcodes 0x104F REVIVESAME_CMD / 0x1050 REVIVEOTHER_CMD
```

### 3.2 NC_CHAR_REBIRTH_CMD `0x1102` / NC_CHAR_REBIRTH_REJECT_CMD `0x1103` (C→Z, no payload)

```pseudo
0x1102 @ FUN_004174c0:  if p+0x2aac8 > 0 or p+0x2aac4: sp_ReviveNow(p, u16 p+0x2aac8); clear both
                        # accept a pending resurrection offered by another player's skill (Z03)
0x1103 @ FUN_00418c60:  in g_ShelterItem[charNo] and g_ShelterDie[charNo]: delete every entry whose abstate is 0x30
                        StaRebirth; clear p+0x2aac4 / p+0x2aac8
```

No mode check in either (any mode accepted).

### 3.3 NC_CHAR_LOGOUTREADY_CMD `0x1071` / NC_CHAR_LOGOUTCANCEL_CMD `0x1072` (C→Z, no payload)

```pseudo
0x1071 @ FUN_00558450 (profiler string "…LOGOUTCANCEL_CMD", log text "…LOGOUTREADY_CMD"):
    if mode ∈ {1,2,3,4,5,6} (mask 0x7e):
        p+0x2a784 action timer: end = g_Now + 130 (13 s), callback sp_Schedule_Logout, state 4
            (if the timer is already in state 4: log "ts_Set - " and keep it)
        p+0x2a798 = g_Now + 80                   # logout allowed after 8 s (Z01 0x0C18)
0x1072 @ FUN_00551470:
    if mode ∈ mask 0x7e: reset the action timer (end 0, callbacks FUN_00570b00 / FUN_004a9c90, state 0); p+0x2a798 = −1
```

The logout cancel also cancels any other action that uses the shared timer (normal attack swing, gathering) *(inferred)*.

### 3.4 NC_CHAR_DEPOLYMORPH_CMD `0x10B0` (C→Z, no payload) @ FUN_004a59d0

```pseudo
if p+0x2a9c8 (polymorph abstate) == 0x318 (none):
    brief.polymorph (+0x52) = 0xFFFF
    broadcast in range 0x10AF NC_CHAR_POLYMORPH_CMD { u16 player, u16 polymorph 0xFFFF, u32 abstate 0x318 }
    reset abstate 0x61 (StaPolymorph) and 0x123 (StaImmortal); the 0x123 reset is issued twice
else if p has that abstate: ShinePlayer_EraseAbstate(p, idx, 0x1C72)
```

### 3.5 NC_CHAR_SAVE_LINK_REQ `0x10B9` (C→Z, no payload) @ FUN_005622d0

`if field and FieldMap_fm_GetSaveLinktoData(field): so_LinkTo(copy of that 0x61-byte link record, 6, 9, 10)`. Leaves an
instance map through its configured "save link" exit (no checks).

### 3.6 NC_CHAR_CLIENT_AUTO_PICK_REQ `0x10BC` (C→Z) `{u8 bEnable}` @ FUN_00566090 → FUN_005654d0 `sp_SetAutoPick`

```pseudo
if mode ∉ {1,2,6} (mask 0x46): return
if bEnable == current (p+0x5cb9 bit 3): FUN_00560250(p, bEnable); return
if bEnable == 1:
    allowed if the minimon in equip slot 25 has auto-pick (FUN_004a25e0(g_MinimonInfo, id) == 1) or the player holds
    an auto-pick item (FUN_00560380(p, 0x1C)); else FUN_005653a0(p, 0x1E01, …) (error) and return
p+0x5cb9 bit 3 = bEnable; brief +0xc4 = bEnable; FUN_00560250(p, bEnable)
→ DB 0x401C NC_CHARSAVE_AUTO_PICK_SAVE_REQ { u16 bEnable, u32 charNo }
```

### 3.7 NC_CHAR_TUTORIAL_STEP_ACK `0x1117` (C→Z) `{u8 nTutorialStep}` @ FUN_00576480

If tutorial info `p+0x2ab44 == 0` and the field has a script (`field+0x128`): script event 0x3c with the step.

---

## 4. Minimon auto-buff and charged buffs

### 4.1 NC_CHAR_USEITEM_MINIMON_*_ITEM_ON/OFF_REQ `0x1124` / `0x1126` / `0x1128` / `0x112A` (C→Z)

The minimon (pup) in equip slot 25 or 28 can use potions automatically. Lists: normal items `p+0x2abee` (12 × u16),
charged items `p+0x2ac06` (12 × u16); flags `p+0x2abec` (normal on), `p+0x2abed` (charged on).
`g_MinimonInfo` DAT_13388838 (`MinimonInfo.shn`): `FUN_004a25e0(id)` = minimon kind (1 auto-pick, 2 auto-use);
`g_MinimonAutoUse` DAT_1328bc40 (`MinimonAutoUseItem.shn`): `FUN_004a2620(kind, itemId)` = item allowed in list kind
(1 normal, 2 charged).

```pseudo
0x1124 NORMAL_ITEM_ON_REQ { u16 NormalItemList[12] }:        @ FUN_005642e0 → FUN_00561d90
    if neither minimon slot 25 nor 28 holds a kind-2 minimon: → 0x3629
    for each id ≠ −1: duplicate in the list → SendErrorCode(4, 0x362D, 0x362C) (code as cmd: (original bug))
        not in the charged list kind 2 … : if allowed as kind 2 → ok;
        else if allowed as kind 1 → 0x362C, else → 0x362A                                  (inferred: wrong-list / invalid)
    copy the list to p+0x2abee
    empty list → 0x362B; else p+0x2abec = 1, FUN_00561aa0(p, 1) (broadcast), → 0x3628
    answers: SendErrorCode(4, 0x125, code) = 0x1125 NC_CHAR_USEITEM_MINIMON_NORMAL_ITEM_ON_ACK
0x1128 CHARGED_ITEM_ON_REQ { u16 ChargedItemList[12] }:      @ FUN_00564460 → FUN_00561f40
    same with the kinds swapped, list p+0x2ac06, flag p+0x2abed, codes 0x3638–0x363D;
    success/empty/no-minimon answer on 0x1129, but the duplicate/invalid errors go out as 0x1125 (original bug)
0x1126 NORMAL_ITEM_OFF_REQ:   @ FUN_00564390   if p+0x2abec: clear; p ← 0x1127 (empty); if charged also off: FUN_00561aa0(p, 0)
0x112A CHARGED_ITEM_OFF_REQ:  @ FUN_00564510   if p+0x2abed: clear; p ← 0x112B (empty); if normal also off: FUN_00561aa0(p, 0)

FUN_00561aa0(p, on):   if brief+0xea ≠ on: brief+0xea = on; broadcast 0x112C NC_CHAR_USEITEM_MINIMON_USE_BROAD_CMD { u16 handle, u8 on }
```

The client (`FUN_004b4600` / `FUN_004b4650`) shows "There are no items registered in the window." for the empty-list code;
the OFF ACKs toggle the auto-buff buttons.

### 4.2 NC_CHAR_CHARGEDBUFF_ERASE_REQ `0x112E` (C→Z) @ FUN_005645e0

The 2016 handler reads `u16 index` at payload 0 (the 2017 struct has `u32 nChargedBuffKey`; the low half is the index).

```pseudo
answers SendErrorCode(4, 0x12F, code) = 0x112F NC_CHAR_CHARGEDBUFF_ERASE_ACK
if mode ∉ mask 0x7e:                           0x3659 "For current status, you cannot remove charged effect."
if index >= p+0x2a334 (count) or list[index] (p+0x2a338, 12-byte entries) null: 0x365B
item = the buff's item (FUN_0045ff80); none:   0x365B
id = g_ItemData by name; none:                 0x365A "Related data cannot be found."
not erasable (FUN_0044f9a0(DAT_00aa43b0, id) false): 0x365C "Related charged effect cannot be removed."
ciee_Free(entry); → 0x3658 (ok)
rebuild the charged-effect bonuses (p+0x2a5a0 ← defaults DAT_132728f8, then FUN_00487c50 over the list)
p+0xe94 = 1; if p+0x2a5ce: so_RecalcEquipParam, so_RecalcLastParam; smo_NotifyParameterChange(1)
```

---

## 5. Wedding (zone side; client requests are in Z02 §10)

### 5.1 Data and status maintenance

`p+0x5cc8` = copy of `NC_CHAR_WEDDINGDATA_ACK` from header on (`vt 0x958`). Fields *(pdb2017, 2016 offsets match)*:
`+6 Error, +8 Status {Main:4, Sub:4}, +9 When, +0xd ApplicationLimit (= SubWhen / DelayLimit / DivorceLimit / NewlyLimit,
a union), +0x11 Partner {Name[20], u32 RegisterNumber at +0x25}, +0x29 WeddingCount, +0x2a RefusalCount`.

**Partner.RegisterNumber is written only from the Character DB** (`so_ply_WeddingData` @ FUN_005a20d0 and
`so_ply_WeddingInfoUpdate` @ FUN_0059f390 are the only writers of `p+0x5cc8`); no zone handler sets it from a packet.
So the proposal target is chosen on the DB side before 0x204F (Z02 open question; the DB procedure is D-items' scope).

```pseudo
0x1081 NC_CHAR_WEDDINGDATA_ACK (DB→Z):          @ FUN_005a0f00 → so_ply_WeddingData (vt 0x954)
    if Error ≠ 0: ignore
    copy to p+0x5cc8; normalise ApplicationLimit (FUN_00635a80)
    Main 1 (engaged):  if ApplicationLimit has passed (FUN_00517990 vs now DAT_00aa43b8 false):
                           → DB 0x1085 NC_CHAR_WEDDING_PROPOSE_CANCEL_REQ { ref, u32 partner }   # engagement expired
    Main 2 (married):  set abstate 0x125 StaWeddingBuff (permanent, strength 1) + brief bit + broadcast
                       FUN_005a1c90 (divorce timers, below); if Sub == 4 (partner forces divorce): p ← 0x205D {0x1384}
    Main 3:            FUN_0059f2d0: if Sub ≠ 0 → vt 0x960; elif the limit passed → DB 0x1087 NC_CHAR_WEDDING_ESCAPE_DIVORCE_REQ { ref, partner }
    p ← 0x1081 (same 0x2B-byte body, ref = {handle, charNo})          # the client gets the full record

FUN_005a1c90 (married, by Sub):
    Sub 0: vt 0x40c, vt 0x418                                         (not traced)
    else, once the limit passed:
      Sub 1: if !vt 0x410: DB 0x108F DIVORCE_CANCEL_REQ { charNo, partner, u8 0 }       # own agreement request expired
      Sub 2: if !vt 0x410: DB 0x108F { partner, charNo, u8 0 }                          # partner's request expired
      Sub 3, 4: DB 0x108D DIVORCE_DO_REQ { partner, charNo, … }                         # forced divorce executes
```

Status values (from these checks; *(inferred)* names): Main 0 single, 1 engaged (proposal accepted, hall not yet held),
2 married, 3 divorced-in-delay; Sub (married) 0 none, 1 I applied for divorce by agreement, 2 partner applied,
3 I forced, 4 partner forced.

### 5.2 DB answers

Bodies *(pdb2017, confirmed by the reads)*: `{ref, i32 Success, u32 Partner}` (DIVORCE_CANCEL: `{ref, i32 Success,
u8 MySubStatus, u32 Partner, u8 PartnerSubStatus}`). "Reload X" = → DB `0x1080 NC_CHAR_WEDDINGDATA_REQ { u16 handle,
u32 charNo }` for a local player X; "Ring-refresh X" = `ZoneRingPacketRefreshWeddingInfo.zrpb_Request(X)` (the other zones
reload X if X is online there).

| Opcode | Handler | Behaviour |
|---|---|---|
| 0x1084 PROPOSE_ACK | @ FUN_005a0ff0 | Success 0 → `ProposeResult(p, p, 0x12E1)` (0x2052); else reload p and the partner if on this zone |
| 0x1086 PROPOSE_CANCEL_ACK | @ FUN_005a1190 | Success → reload p, ring-refresh partner |
| 0x1088 ESCAPE_DIVORCE_ACK | @ FUN_005a1a40 | Success → reload p |
| 0x108A DIVORCE_BY_AGREE_ACK | @ FUN_005a12c0 | Success → p ← 0x205D `{0x1380}` (applied), reload p, ring-refresh partner |
| 0x108C DIVORCE_BY_FORCE_ACK | @ FUN_005a1420 | same as 0x108A |
| 0x108E DIVORCE_DO_ACK | @ FUN_005a1580 | Success → reload p, ring-refresh partner |
| 0x1090 DIVORCE_CANCEL_ACK | @ FUN_005a16b0 | Success → ring-refresh both `ref.charNo` (+4) and Partner (+0xb) (no local reload) |
| 0x1092 WEDDING_DO_ACK | @ FUN_005a1830 | reload both (always); on Success each gets item `DAT_14d504be` (`so_scene_CreateItem`, vt 0x8b4) and two skills: → DB `0x4801` (skill learn) `{ref, u32 charNo, u16 skill, u8 0/1, u16 0xFFFF}` with skill `DAT_13286d06` (active) and `DAT_13287260` (passive) |

None of these failures is reported to the client except PROPOSE (0x12E1). The money taken by 0x205B/0x205C (Z02) is not
refunded when the DB answers Success 0 (original bug).

### 5.3 Partner info

```pseudo
0x1093 NC_CHAR_WEDDING_PARTNER_INFO_REQ (C→Z, no payload):   @ FUN_005a0570
    if p.Main ≠ 2: return
    q = som_FindPlayer(Partner.RegisterNumber)
    q on this zone with a field:
        p ← 0x1094 { +6 u8 Level = q.level, +7 u8 Connected = 1, +0xc u16 CurrentMap = MapInfo index of q's map }
             # ref (+0..+5) and LastConnect (+8) are left from older g_buf contents (original bug)
    else:
        ring → 0x1095 NC_CHAR_WEDDING_PARTNER_INFO_RNG { ZONERINGLINKAGESTART { u8 zoneNo, u16 handle, u32 charNo },
                     PartnerInfo { u8 Level, u8 Connected = 0, u16 CurrentMap, u32 RegisterNumber = partner } }
        if there is no next zone (DAT_13388e94 == 0): → DB 0x1093 { ref, u32 Partner } directly

0x1095 on the ring (ZoneListenSession @ FUN_005a0a40, not in this item's table but completes the flow):
    not the origin zone: if Connected == 0 and the partner is online here: fill Level, Connected = 1, CurrentMap; forward to the next zone
    origin zone (start.zoneNo == mine): player by handle;
        Connected → p ← 0x1094 { Level, Connected, CurrentMap }; else → DB 0x1093 (offline partner: last login from the DB)

0x1094 NC_CHAR_WEDDING_PARTNER_INFO_ACK (DB→Z):              @ FUN_005a1b60
    p ← 0x1094 { ref = {handle, charNo}, Level = +6, Connected = 0, LastConnect = +8, CurrentMap = 0xFFFF }
```

The 2016 client has **no handler for 0x1094** (C01), so the whole partner-info exchange has no visible effect in 2016
*(inferred: UI added later)*.

### 5.4 NC_CHAR_WEDDING_CANCEL_WEDDING `0x10B2` (WM→Z) `{u32 RegisterNumber}` @ FUN_005a07d0

If the number is the groom or the bride of the current hall reservation (`g_WeddingHall` +0x2c / +0x14) and the hall is
reserved (`g_WeddingHall` byte 0 ≠ 0) but not started (+1 == 0): clear the reservation (bytes 0 and 1). Hall timetable /
`wh_Reserv` internals: not reconstructed (§12).

### 5.5 `FUN_005b92a0` after an accepted proposal (Z02 question)

Called as `FUN_005b92a0(DAT_13388678, q.name, p.name)`; not traced further in this session (§12).

---

## 6. Mini-house (estate)

### 6.1 Data

- Object type 3 `ShineMiniHouse` (Z01 §2), handles 9500–10499. Player link: `p+0x5cf6` u16 house handle (−1 = outside;
  `vt 0x130` IsInMiniHouse FUN_005709f0, `vt 0x134` set, `vt 0x138` get). `p+0x5cf4` index of the pending build record in
  `g_MiniHouseBuild` (DAT_00869298 ring of 0x88-byte {u16 player handle, 0x85-byte BUILDING_REQ body}); `p+0x5cf8` build cast flag.
- `p+0x292ac` MiniHouseStr (saved shape, `mhs_Init`), `p+0x292d7` "saved" flag, `p+0x29314` mini-house item active.
- House methods (ShineMiniHouse vtable): 0x7c `so_mh_Enter`, 0x80 owner charNo (+0x348), 0x84 owner handle, 0x88 `so_mh_Out`,
  0x90 can-visit check, 0x98 password check, 0x9c fill VISITREADY, 0xa0 fill LOGINCOMPLETE, 0xb8 `so_mh_ReArrangeFurniture`,
  0xbc `so_mh_CreateFurniture`, 0xc0 `so_mh_DeleteFurniture`, 0xd8 `smh_SendFurnitureInfo`, 0xdc `so_mh_KickOut`,
  0xe4 `so_mh_reSetMaxPlayer`, 0xe8 `so_mh_reSetPassword`, 0xec `so_mh_reSetTitle`, 0xf0 `so_mh_SendOutSideTitleCmd`,
  0xf4 `so_mh_reSetItemInfoOpen`, 0xf8 `so_mh_reSetNotify`, 0x10c `so_mh_PortalOpen`, 0x110 `so_mh_PortalClose`,
  0x114 `so_mh_isActivePortal`, 0x120 `so_mh_GetActivePortalID`, 0x124 active portal effect row, 0x150 exit link record,
  0x154 entry link record, 0x158 furniture usable, 0x2a0 mini-game state (2/3 = dice game running), 0x2d8 furniture emotion.
- Tables: `MiniHouse.shn`, `MiniHouseFurniture.shn`, `MiniHouseEndure.shn`, `MiniHouseObjAni.shn` (DAT_0d76ac90),
  `MiniHouseFurnitureObjEffect.shn` (DAT_13295a28, row count at DAT_13295a5c+0x28); columns *(pdb2017)*: ObjEffect
  `Handle, ItemID[32], EffectEnum, EffectIndex, ApplyRange[5], UseRange[5] (+0x5a), NeedItem[32] (+0x6e), NeedMoney (+0x8e)`.
  `UseRange` as read: [0] = 1 everyone, [1] = 1 party of the host allowed, [2] = 1 guild of the host allowed,
  [3] min level, [4] max level.
- Result codes (dept 35, client texts): 0x1181 ok, 0x1182 "You may not enter the Estate with your current status.",
  0x1184 "Only available within the Estate.", 0x1185 "You have already created a Estate.", 0x1187 "Invalid Estate",
  0x1188 "Only available to room host.", 0x118D "Host cannot be kicked by host", 0x1191 "Unable to find a selected user",
  0x1193 "Unable to open a Estate", 0x1194 "Estate data error", 0x1195 "Estate cannot be created outside of the house zone.",
  0x1196 "Please try later", 0x1199 "Unable to create near the NPC", 0x119A "Estate decoration skill has not been learned.",
  0x119B "Incorrect password used.", 0x11A0 "You are too far from target Estate.", 0x11D6/0x11D7 room public/private,
  0x11CF "Furniture data cannot be retrieved", 0x1DC3/0x1DC4 dice game running.

Common prefix `InHouseOwner` *(ours)* used by the owner-only edit requests below:

```pseudo
InHouseOwner(p, cmd):
    if no field: SendErrorCode(35, cmd, 0x1193); stop
    if !p.IsInMiniHouse: 0x1184; stop
    h = GetObject(p+0x5cf6); none: 0x1187; stop
    if h.owner (vt 0x80) ≠ p.charNo: 0x1188; stop
    return h
```

### 6.2 NC_MINIHOUSE_ACTIV_REQ `0x8C01` (C→Z) `{u8 slot}` @ FUN_00536310

Activates (equips) a mini-house item: moves the item from inventory slot `slot` of box `p+0xe778` into the
mini-house slot (type 12, slot 0).

```pseudo
answers SendErrorCode(35, 2, code)
mode ∉ {1,2}: 0x1002;  slot <= 10: 0x1004                      (inferred: slots 0..10 are reserved)
slot >= box size: 0x1005; either cell locked: 0x1003; null cell: 0x1006
r = MiniHouseStr.mhs_Init(p+0x292ac, p, cell); r ≠ 0x1001 → r
source empty: 0x1005; destination empty → irm_Move else irm_Exchange; → 0x1001; vt 0x3e0 (booth size), p+0x29314 = 1
```

### 6.3 NC_MINIHOUSE_BUILDING_REQ `0x8C03` (C→Z) @ FUN_005769d0

Body *(pdb2017, confirmed)*: `u8 maxvisiter, char password[9], char title[21], u8 bItemInfoClose, char sNotify[101]`.

```pseudo
answers SendErrorCode(35, 4, code)
mode ∉ {1,2}, Fear, captivated, or p+0x4e (u64) ≠ 0:  0x1182
no field: 0x1193; skill "MiniRoomSkill" unknown or not learned: 0x119A
an NPC/tent point within 400 (so_TentPoint): 0x1199
10 tries to find a free spot (FUN_00427e80) fail: 0x1195;  already in a house (vt 0x130): 0x1185
CancelOnAction; stop moving
p ← 0x2047 NC_ACT_CREATECASTBAR { u16 5000 }; p+0x5cf8 = 1
timer p+0x2a784: 5000 ms → FUN_00576570 (build)
record the request in g_MiniHouseBuild (FUN_00570d60); p+0x5cf4 = its index

build (FUN_00576570):
    p+0x5cf8 = 0; vt 0x2b0
    h = som_AllocObject(type 3); none → (35, 4, 0x1196)
    h.vt[0x78](p, map name DAT_0cfd154c, title, password, maxvisiter, bItemInfoClose, sNotify); failure → free h
    broadcast in map 0x8C05 NC_MINIHOUSE_BUILDING_CMD { u16 player, u16 house, tent brief (sp_MakeTentBriefInfo),
          shape 0x14 bytes (vt 0x6d0), u32 x, u32 y, u8 dir, char title[20] }
    FUN_004d2990 (unsummon the pet)
    so_LinkTo(h.vt[0x154](6, 9, 10)); failure → log "cannot enter minihouse", free h; else p+0x5cf6 = h.handle
```

### 6.4 NC_MINIHOUSE_LOGINCOMPLETE_REQ `0x8C0A` (C→Z, no payload) @ FUN_00571f20

Sent by the client after arriving in the house map.

```pseudo
ack 0x8C0B NC_MINIHOUSE_LOGINCOMPLETE_ACK { i32 error, u8 maxvisiter, u8 bItemInfoClose, char sNotify[101], char TargetKey[32],
                                            u8 playernum, { u8 level?, u16 handle } × playernum }  (0x8C bytes + 3 × n)
mode ∉ {0,1,2} (mask 7), Fear, captivated: error 0x1182 (0x8E bytes, rest stale)
no field: 0x1193; not in a house: 0x1184; house gone: 0x1187
h.vt[0xa0](ack, charNo) fills it; error = 0x1181; p ← ack
broadcast in map 0x8C0C NC_MINIHOUSE_LOGINCOMPLETE_CMD { u8 level, u16 handle }
h.smh_SendFurnitureInfo(p)                                     # 0x8C08 / 0x8C09 furniture lists
if h has an active portal: p ← 0x8C24 { u8 1, u16 60000, u16 portalID, 16 constant bytes }      (portal object as a furniture)
if p is the owner:
    → DB 0x1076 NC_CHAR_GET_ITEMLIST_BY_TYPE_REQ { ref, u8 type, u32 charNo } for types 3, 13, 14, 16 (house boxes, §10.1)
    → DB 0x8C59 NC_MINIHOUSE_DB_PORTAL_LIST_REQ { u32 charNo, u16 handle }
else:
    → DB 0x8C5B NC_MINIHOUSE_DB_VISITER_COUNT_REQ { u32 charNo, u16 handle, u32 owner }
vt 0x178(0), vt 0x188(0), vt 0x190(0); h.vt[0x2e4](p)
GameLog ← owner ? 0x04C9 NC_LOG_GAME_MINIHOUSE_BUILDING { u32 charNo, map, x, y, … } : 0x04CA NC_LOG_GAME_MINIHOUSE_VISIT { u32 owner, u32 charNo, … }
```

### 6.5 Visiting

```pseudo
0x8C0E NC_MINIHOUSE_VISITREADY_REQ { u16 mh_hnd }:            @ FUN_005719f0
    ack 0x8C0F { i32 error, u8 isPublic, u8 visitercnt, u8 maxvisiter }
    mode ∉ {1,2}, Fear, captivated: 0x1182; no field: 0x1193; already inside a house: 0x1185
    h = GetObject(mh_hnd): none 0x1187; h.vt[0x90](p) false → 0x1185 (full / refused)
    else error 0x1181, h.vt[0x9c] fills the rest

0x8C10 NC_MINIHOUSE_VISIT_REQ { u16 mh_hnd, char password[9] }:   @ FUN_00571c50
    answers SendErrorCode(35, 0x11, code)
    same mode/field/inside checks (0x1182 / 0x1193 / 0x1185); CancelOnAction; stop moving
    h none: 0x1187; dist²(p, h) >= 10001: 0x11A0
    p lacks StaGMHideMode (0x120) and the password check (h.vt[0x98]) fails: 0x119B
    h.vt[0x90](p) false: 0x1185
    r = h.so_mh_Enter(p); SendErrorCode(35, 0x11, r)
    if r == 0x1181: link into the house map (h.vt[0x154](6,9,10)); ok → p+0x5cf6 = h; vt 0x2b0
                    else log "cannot enter minihouse", h.so_mh_Out(p)
```

### 6.6 Leaving and kicking

```pseudo
0x8C18 NC_MINIHOUSE_EXIT_REQ (no payload):                   @ FUN_005728a0
    answers (35, 0x19, code); mode/Fear/captivated 0x1182; no field 0x1193; not inside 0x1184
    CancelOnAction; stop; h none 0x1187; exit link (vt 0x150) null 0x1194
    if a dice game runs (h.vt[0x2a0] ∈ {2,3}):
        owner: h.vt[0x200]() (end the game); schedule the exit (vt 0x194 with the exit map/xy); → 0x1DC3
        guest: if vt 0x170(1): vt 0x190(1), schedule exit, → 0x1DC3; else fall through
    → 0x1181; so_LinkTo(exit link, 6, 9, 10); failure → log "cannot out minihouse", so_Disconnect(0x685)

0x8C12 NC_MINIHOUSE_KICKOUT_REQ { u16 hnd }:                 @ FUN_00575500 (profiler string "…KICKOUT")
    answers (35, 0x13, code)  (opcode 0x8C13, which has no 2017 name)
    no field 0x1193; not inside 0x1184; house none 0x1187; not owner 0x1188
    target none 0x1191; target is p 0x118D
    r = h.so_mh_KickOut(target.charNo); → r
    r == 0x1181: exit link null → 0x1194
        dice game running and target vt 0x170(1): schedule the target's exit, → 0x1DC4 (to the owner)
        else target ← 0x8C14 NC_MINIHOUSE_KICKOUT_CMD { u8 1 }; target.so_LinkTo(exit, 6, 9, 10) (failure → disconnect 0x685)
    # 0x1DC4 and the "schedule" path go to the owner, but the target state is the target's (original bug: p.vt[0x190]
    # and p.vt[0x194] are called on the owner, not on the kicked player)
```

### 6.7 NC_MINIHOUSE_FUNITUREINFOCOMPLETE_REQ `0x8C1D` (C→Z) `{u8 funitureinfocomplete}` @ FUN_00572670

```pseudo
answers (35, 0x1E, code); no field 0x1193; not inside 0x1184; house none 0x1187
if funitureinfocomplete ≠ 0:
    → 0x11C1; if !h.vt[0xb0]() (furniture ready?): reset abstate 0x122 StaQuestEntangle (kept while loading), refresh parameters
else:
    → 0x11CF "Furniture data cannot be retrieved"; exit link null → 0x1194; else so_LinkTo(exit) (failure → disconnect 0x685)
```

### 6.8 Furniture and settings (owner only, `InHouseOwner` prefix)

| Opcode | Handler | cmd | Call | Success broadcast (to everybody in the house map, incl. p) |
|---|---|---|---|---|
| 0x8C1F REARRANGE_REQ `{u8 count, {…} × n}` | @ FUN_00572d50 | 0x20 | `so_mh_ReArrangeFurniture(p, body)`; result 0x11C1 = ok (no ACK sent then) | inside the house method (0x8C21) |
| 0x8C22 CREATE_FURNITURE_REQ `{u8 count, {…} × n}` | @ FUN_00572bf0 | 0x23 | `so_mh_CreateFurniture`; 0x11C1 = ok, silent | 0x8C24 (InvenCellReleaser) |
| 0x8C25 DELETE_FURNITURE_REQ `{u8 count, u16 handle × n}` | @ FUN_00572eb0 | 0x26 | `so_mh_DeleteFurniture`; 0x11C1 = ok, silent | 0x8C27 |
| 0x8C2B MODIFY_PASSWORD_REQ `{char password[9]}` | @ FUN_00573200 | 0x2C | `so_mh_reSetPassword`; the result is always sent | 0x8C2D `{u8 isPublic}` = 1 on 0x11D6 (public), 0 on 0x11D7 (private) |
| 0x8C2E MODIFY_TITLE_REQ `{char title[21]}` | @ FUN_00573010 | 0x2F | `so_mh_reSetTitle`; result sent | 0x1181 → 0x8C30 `{char title[20], 0}` + `so_mh_SendOutSideTitleCmd` (outside view) |
| 0x8C32 MODIFY_MAXENTERNUM_REQ `{u8 maxvisiter}` | @ FUN_005733c0 (profiler string `sp_NC_ACT_INNERMH_RESET_MAX_PLAYER`) | 0x33 | `so_mh_reSetMaxPlayer`; result sent | 0x1181 → 0x8C34 `{u8 maxvisiter}` |
| 0x8C43 MODIFY_ITEM_INFO_OPEN_REQ `{u8 bItemInfoClose}` | @ FUN_00573590 | 0x44 | `so_mh_reSetItemInfoOpen`; result sent | 0x1181 → 0x8C45 `{u8 bItemInfoClose}` |
| 0x8C48 MODIFY_NOTIFY_REQ `{u8 len, char sNotify[len]}` | @ FUN_00573750 | 0x49 | `so_mh_reSetNotify`; result sent | 0x1181 → 0x8C4A `{u8 len, text, 0}` (len taken from the request: (original bug) if len > 100 the copy reads past the packet; the house method may reject it first, not checked) |
| 0x8C50 PORTAL_OPEN_REQ `{u16 nPortalItemID}` | @ FUN_00573930 | 0x51 | `so_mh_PortalOpen`; result sent | 0x1181 → 0x8C24 `{u8 1, u16 60000, u16 portalID, 12 constant bytes, u32 0, u8 1}` |
| 0x8C53 PORTAL_CLOSE_REQ | @ FUN_00573b20 | 0x54 | `so_mh_PortalClose`; result sent | 0x1181 → 0x8C27 `{u8 1, u16 60000}` |

The furniture REQs answer only on failure (the successful path ends in DB requests whose releasers send the CMDs).

### 6.9 NC_MINIHOUSE_CHAR_ACTION_REQ `0x8C3D` (C→Z) `{u16 Handle, u16 nFurnitureHnd}` @ FUN_00574750

Plays a furniture animation (`MiniHouseObjAni.shn` row `Handle`).

```pseudo
ack 0x8C3E NC_MINIHOUSE_CHAR_ACTION_ACK { u16 err } (default 0x14C0 = ok)
no field 0x1193; not inside 0x1184; house none 0x1187
cell = h.so_mh_GetItemCellByFurnitureHandle(nFurnitureHnd); none 0x16C5
cell+0x25 >= 3: 0x11E2 "…the furniture's durability is lack."            (inferred: durability state byte)
!h.vt[0x158](nFurnitureHnd): 0x14C1
row = ObjAni(Handle); none: 0x14C3
p ← ack { 0x14C0 }
broadcast in house 0x8C3F NC_MINIHOUSE_CHAR_ACTION_CMD { u16 PreHandle = row.Handle, u16 NextHandle = row.ItemID (+2),
          u16 nFurnitureHnd, u16 ActorHnd = p, u8 ActorIdx = row+4, u8 ActeeIdx = row+6 }
```

Field mapping of `PreHandle/NextHandle/ActorIdx/ActeeIdx` follows the code (`row[0], row[1], (u8)row[2], (u8)row[3]` as
u16 words); against the PDB `MiniHouseObjAni` columns this sends Handle, ItemID, the low byte of AniGroupIDMaxNum/AniGroupID
and of AniGroupID/EventCode (original bug or a 2016 layout difference; not resolved).

### 6.10 NC_MINIHOUSE_FURNITURE_EFFECT_REQ `0x8C40` / PORTAL_EFFECT_REQ `0x8C56` (C→Z)

0x8C40 `{u16 nFurnitureHnd, u16 nEffectHandle}` @ FUN_00574a30 (profiler string "…CHAR_ACTION_REQ", copy-paste).
0x8C56 (no payload) @ FUN_00573cf0 uses the house's active portal effect row (h.vt[0x124]) instead.

```pseudo
ack 0x8C41 { u16 nEffectHandle, u16 err } (0x8C57 { u16 err } for portals), default ok 0x16C0 / 0x19D0
no field 0x16C2/0x19D2; not inside 0x16C4/0x19D4; house none 0x16C3/0x19D3
FURNITURE: nEffectHandle >= row count 0x16CA; cell of nFurnitureHnd none or empty 0x16C5; cell+0x25 >= 3 0x11E2
           row = ObjEffect[nEffectHandle]; none 0x16CA; row.ItemID unknown 0x16C6; ≠ the furniture's item 0x16CA
PORTAL:    row = active portal effect; none 0x19DA
level ∉ [UseRange[3], UseRange[4]]: 0x16CF / 0x19DF
if UseRange[0] ≠ 1 and p is not the host:
    host not found 0x16C1 / 0x19D1
    UseRange[1] == 0 and UseRange[2] == 0: 0x16CE / 0x19DE "You do not have permission to use."
    same guild (vt 0x828) and UseRange[2] == 1 → ok; same party (vt 0x550) and UseRange[1] == 1 → ok
    else UseRange[2] == 1 → 0x16CD "not in room host's guild"; UseRange[1] == 1 → 0x16CC "not in party with the room host"
need = NeedItem id; NeedMoney
if no NeedItem and NeedMoney == 0: apply now: so_MH_EffectApply(row) (vt 0x15c) / so_MH_PortalEffectApply (vt 0x128); return
if NeedMoney > money: 0x16C7 / 0x19D7
if NeedItem: cell = sp_FindItemFromInventory(id); none 0x16C8/0x19D8; no attribute or lot invalid 0x16C9/0x19D9
             stackable with lot > 1 → lot − 1, locking.Replace; else locking.ClearCell
if NeedMoney: locking.ReserveMoney (vt 0x48)
→ DB 0x347D NC_ITEMDB_MINIHOUSE_EFFECT_DEMANDGOOD_REQ (0x3489 …PORTAL_EFFECT… for portals)
     { ref, u16 lockindex, u64 itemKey, u16 itemId (0xFFFF none), u32 lot, u64 money, u16 nEffectHandle = row.Handle }
++lock index                                     # the effect is applied by the DB answer (Z05)
```

### 6.11 Furniture emotions

```pseudo
0x8C62 NC_MINIHOUSE_FURNITURE_EMOTION_REQ { u16 nFurnitureHnd, u8 nPosition, u8 nEmotionNo }:   @ FUN_00575850
    ack 0x8C63 { u16 nFurnitureHnd, u8 nPosition, u8 nEmotionNo, u16 nError } (ok 0x1708)
    no field 0x170A; not inside / house none 0x170B
    nError = h.vt[0x2d8](p, req)  (always sent)
    ok and p.vt[0x2cc](furniture), vt[0x2d0](position), vt[0x2d4](emotion) all succeed:
        broadcast 0x8C64 NC_MINIHOUSE_FURNITURE_EMOTION_CMD { u16 nEmotionCnt = 1, FURNITURE_EMOTION_INFO { u16 player,
              u16 nFurnitureHnd, u8 nPosition, u8 nEmotionNo } }
0x8C65 …_CANCEL_REQ (no payload):                             @ FUN_00575ae0
    ack 0x8C66 { u16 nError } (ok 0x1718); no field 0x171A; not inside / house none 0x171B
    p.vt[0x2c0]() == −1 (not sitting on furniture): 0x171C; vt[0x2b0]() false: 0x1719
    ok → ack, broadcast 0x8C67 { u16 nCancelEmotionCnt = 1, u16 player }
```

### 6.12 Mini-house DB answers

```pseudo
0x8C5A NC_MINIHOUSE_DB_PORTAL_LIST_ACK { ref, u16 err, u16 count, {u16 id, u32 …} × count }:   @ FUN_0056ed60 → p.vt[0xfc] (FUN_0056f660)
    p must be inside its own house; err == 0x1A08 and count < 51: h.vt[0x104](list);
        p ← 0x8C4B { u16 count, {u16, u32} × count }; h.smh_SendFurnitureInfo(p)
    else log ("not found mh" / "not owner" / "DB error" / "portal count error")
0x8C5E NC_MINIHOUSE_DB_PORTAL_ADD_ACK:   @ FUN_0056eef0 → p.vt[0x100] (FUN_0056fa10)
    err (+0xd) ≠ 0x1A10: release lock (+0xb), log; else commit the lock and add the portal (not traced further)
0x8C5C NC_MINIHOUSE_DB_VISITER_COUNT_ACK:  @ FUN_0056f1f0   only logs when the player is gone; nothing else (dead)
0x8C60 NC_MINIHOUSE_DB_PORTAL_DEL_ACK:     @ FUN_0056f080   same: no effect
```

---

## 7. Card collection (COLLECT, dept 49)

Data: album `p+0x2aa94` (vector of 11-byte entries, card id at +8; loaded by `so_ply_CardCollect` from WM 0x10E3),
bookmarks (0x10E6), rewarded ids `p+0x2aab4` (vector of u16, 0x10E9). Tables: `CollectCard.shn` (card by item InxName,
DAT_14d7131c, FUN_00627e30; card grade at row+0x22), `CollectCardMobGroup.shn`, `CollectCardDropRate.shn`, reward table
`CardCollection::CardCollectionReward` (DAT_14d71370, `ccr_Load` @ FUN_00629160, lookup by (RewardID, item name) FUN_00628060).
Card items are class 31 (opened card); their cell holds `+0xa u32 Serial, +0xe u8 Star`.

```pseudo
0xC401 NC_COLLECT_PEEPING_REQ { Name5 charname }:            @ FUN_006272c0 (no checks)
    → DB 0xC402 NC_COLLECT_PEEPING_DB_REQ { u32 charNo, u16 own handle, Name5 targetcharname }

0xC403 PEEPING_DB_COLLECT_ACK { u32 regnum, u16 handle, Name5 name, u16 err, CARDCOLLECT { u16 n, 11 bytes × n } }:   @ FUN_006273e0
    p by handle and charNo → p ← 0xC405 NC_COLLECT_PEEPING_COLLECT_ACK { name, err, u16 n, entries }   (0x1e + 11n bytes)
0xC404 …_BOOKMARK_ACK:                                         @ FUN_00627550
    same → 0xC406 { name, err, u16 n, 4 bytes × n }

0xC408 NC_COLLECT_CARDREGIST_REQ { u8 invenslot }:           @ FUN_00628560 (no mode check)
    errors → 0xC40B NC_COLLECT_CARDREGIST_ACK { u8 invenslot, u16 CardID, u8 Star, u32 Serial, u16 err } (only err set; the
             other fields are stale (original bug))
    empty / no data: 0x2B91 "Empty or Wrong Item"; class ≠ 31: 0x2B92; cell locked: 0x2B93; item unknown: 0x2B94
    card = CollectCard(item InxName); none: 0x2B95
    → DB 0xC409 NC_COLLECT_REGIST_REQ { u32 charNo, u16 handle, u16 lockindex, u64 CardKey,
                                        CardInfo { u8 invenslot, u16 CardID, u8 Star, u32 Serial } }
    lock the cell with a CardRegist releaser (vt 0x7d4 …); FUN_0043c130
0xC40A NC_COLLECT_REGIST_ACK { regnum, handle, lockindex, CardInfo, u16 err }:   @ FUN_00627b60
    err == 0x2B90: commit the lock (the releaser `InvenCellReleaser_CardRegist` adds the card and sends 0xC40B)
    else: release the lock; p ← 0xC40B { CardInfo, err }

0xC40C NC_COLLECT_BOOKMARK_REGIST_REQ { u16 BookMarkSlot, u16 CardID }:   @ FUN_00628b80
    CardID == −1 (clear) or present in the album → DB 0xC40D { u32 charNo, u16 handle, u16 slot, u16 CardID }
    else p ← 0xC40F { slot, CardID (both stale (original bug)), u16 err 0x2BA1 "Unregistered Card" }
0xC40E BOOKMARK_REGIST_DB_ACK { regnum, handle, slot, CardID, err }:   @ FUN_006278f0
    p ← 0xC40F { slot, CardID, err }; err == 0x2BA0 → p.vt[0xc10](slot, CardID) (update the bookmark)

0xC410 NC_COLLECT_REWARD_REQ { u16 RewardID, u16 RewardItem }:   @ FUN_00628ef0
    errors → 0xC413 NC_COLLECT_REWARD_ACK { u16 RewardID, u16 err }
    RewardID already in p+0x2aab4: 0x2BA9 "Already Rewarded"; RewardItem unknown: 0x2BAA
    reward row (RewardID, item) none: 0x2BAB; !cca_IsRewardCondition(album, row): 0x2BAC "…more cards needed"
    → DB 0xC411 { u32 charNo, u16 handle, u16 RewardID, new item: ItemKey_Make(RewardItem, kind 0xb, zone, world),
                  attribute init (ItemAttrCls vt 0x14) }   (0x77 bytes; the 2017 struct is 8 bytes)
0xC412 NC_COLLECT_REWARD_DB_ACK { regnum, handle, RewardID, err }:   @ FUN_00627a40 (profiler string "…REWARD_DB_REQ")
    p ← 0xC413 { RewardID, err }      # p+0x2aab4 is not updated here (the item goes to the reward inventory)

cca_IsRewardCondition(album, row):                         @ FUN_00628d60
    count album cards by grade (CollectCard row +0x22, 0..3)
    row+2 type: 0 → total of all grades, 1..4 → count of grade type−1; satisfied when count >= row+6 (u16)
    (return values not visible in the decompile; the comparison is clear) (inferred: unknown type = satisfied)
```

The rewarded list is not updated after 0xC412, so the same reward can be requested again in the same session; whether the
DB refuses it is D-items' scope (possible original bug).

---

## 8. Mounts (MOVER, dept 51)

A `ShineMover` (type 11, handles 22138–23137) is a vehicle with seats. Player state (Z02 §2): mode 6 riding,
`p+0x2a77c` ride kind (2 = on a ShineMover, 3 = got off), `p+0x2a760/62` ride item slot, `p+0x2a768…0x2a778` hunger state,
`p+0x2962c/30/32/34` mover recovery timer {last g_Now, u16 interval ms, u16 ‰ per tick, fn = FUN_0056b5f0}.

```pseudo
0xCC01 NC_MOVER_RIDE_ON_REQ { u16 nMoverHandle, u8 nSlot }:   @ FUN_00563270 (profiler string "ShineObjecrClass::ShinePlayer::sp…")
    errors → SendErrorCode(51, 3, code) = 0xCC03 NC_MOVER_RIDE_ON_FAIL_CMD
    mode ∉ {1,2} or no layer or layer kind (+4) == 3: 0x306A "You cannot ride the mover."
    mover none: 0x306B; p already rides (vt 0xc74) or not the same layer: 0x306A
    dist² >= 90001 (300 units): 0x3070 "too far away"
    remove the abstates of every active toggle skill (FUN_00448fa0)
    so_MoverSystem_GetOn (FUN_0045d7a0):
        p has 0x4B StaHide: 0x306A, CancelOnAction
        mover.so_smv_GetOn(p, nSlot) (vt 0xcb8, FUN_0055f380):
            no mover data (+0x1f44): 0x306C; nSlot >= seat count (+0x1f64): 0x306D
            seat taken, or reserved for someone else (+0x1ee0 charNo): 0x306F
            seat p; passengers++; p stops; p.vt[0xc98](mover xy, dir); p.vt[0xc78](mover); p.vt[0xc80](nSlot)
            p ← 0xCC02 NC_MOVER_RIDE_ON_CMD { u16 mover, u8 slot, u8 grade (vt 0xcfc) }
            broadcast in range 0xCC04 NC_MOVER_SOMEONE_RIDE_ON_CMD { u16 player, u16 mover, u8 slot, u8 grade }
            mover script hook (+0x1f4c vt 0x40) → FUN_0055f0a0(p, …)
        save shape (p+0x292ac) if not saved; mode = 6; hunger 1000 / 0; ride kind = 2
        row = g_MoverUpgrade[grade] (MoverUpgrade): recovery timer {interval row+2, ‰ row+4, FUN_0056b5f0}
        p is a passenger (mover owner vt 0xca8 ≠ p.charNo): ride item slot = −1

FUN_0056b5f0 (tick while riding): every interval: HP += MaxHP × ‰ / 1000, SP += MaxSP × ‰ / 1000; if changed, send to p and to
    whoever targets p

0xCC05 NC_MOVER_RIDE_OFF_REQ (no payload):                   @ FUN_00563420
    mode == 6 and ride kind == 2: r = FUN_0045d910(p, 0) else r = 0 → (51, 7, 0x3081)
    FUN_0045d910: mode ≠ 6 → (51,7,0x3081) "You cannot get off the mover."; no mover → (51,7,0x3082) "It is not the mover you can get off."
        passenger: p.vt[0xc6c] = so_MoverSystem_GetOff (FUN_0045f020)
        owner: mover.so_smv_GetOffAll (every passenger's GetOff), mover.so_Unmark, som_FreeObject(mover, reason 0x7B) → true
    r true → SendErrorCode(51, 7, 0x3080) = 0xCC07 NC_MOVER_RIDE_OFF_FAIL_CMD { 0x3080 }     # the success code goes out on the FAIL opcode
    # (for a passenger, GetOff returns its own result; if true the same 0x3080 is sent)

so_MoverSystem_GetOff (FUN_0045f020):
    mode ≠ 6: 0x3081; no mover: 0x3082; mover.vt[0xcbc](p, seat) false: return
    restore shape; mode = 1; ride kind = 3
    ride item (p+0x2a762 ≠ −1): item hunger (attr vt 0xc0) → FUN_00561630; reset attr vt 0x64; release lock (when called with 0);
        sp_HorseItemSave
    p+0x29634 = FUN_00417480 (normal recovery); vt 0x91c(0x700, 9)
```

`0xCC0C NC_MOVER_LINKDATA_ZONE_CMD` (WM→Z, §1.2) restores the mover state after a map change (FUN_0045ddf0, not traced).

---

## 9. Pets (PET, dept 53)

Player pet state (`p+0x2ab60…`, Z02 §2): `+0x2ab60` system state (1 casting, 2 loading, 3 creating, 4 created, 5/6 out, 8),
`+0x2ab64` naming state (2 asked, 3 naming, 4 named), `+0x2ab74` pet item inventory slot, `+0x2ab7c` pet id, `+0x2ab80` pet
object handle, `+0x2ab84` pet RegNum (DB key, −1 = none), `+0x2ab88` name[16], `+0x2ab98` mind × 1000, `+0x2ab9c` stress × 1000,
`+0x2aba8…+0x2abc0` resummon-after-link record. The pet item is class 36 (`ItemAttrCls` with the pet name at cell +0x12 and
RegNum at cell +0xa). Pet object = type 12 `ShinePet` (`p.vt[0xe44]()`).

```pseudo
0xD406 NC_PET_ASK_NEW_NAME_ACK { u16 nError, u16 nPetHandle }:   @ FUN_004d0d20
    if nError == 0x34C0 and nPetHandle == p+0x2ab80 and naming == 2 and state ∈ {5,6} and slot/id/RegNum set: naming = 3

0xD407 NC_PET_SET_NAME_REQ { u16 nPetHandle, Name4 sPetName (16) }:   @ FUN_004d1c80
    require nPetHandle == p+0x2ab80 ≠ −1; 4 <= strlen(name) <= 16; naming == 3; state ∈ {5,6}; slot, id, RegNum set;
            name passes the bad-word filter (FUN_0042aa10(DAT_133887f8) ≠ 1)
    cell (p+0x2ab74) must exist with class 36; else log and stop (no reply)
    → DB 0xD403 NC_PET_SET_NAME_DB_REQ { u16 handle, u32 RegNum, Name4 name }
    write the name into the item cell (+0x12) and p+0x2ab88 at once (before the DB answer)
    # any failed check is silent: the client waits (original bug)

0xD409 NC_PET_SET_NAME_CANCEL_REQ { u16 nPetHandle }:   @ FUN_004d0e10
    same handle / naming == 3 / state / item checks
    naming = 4; p ← 0xD40A NC_PET_SET_NAME_CANCEL_ACK { u16 0x34D0, u32 petID }

0xD404 NC_PET_SET_NAME_DB_ACK { u16 nError, u16 nMasterHandle, u32 RegNum }:   @ FUN_004d1250
    p by nMasterHandle (type 2), its pet (type 12)
    nError ≠ 0x3418: log ERR_PET_SET_NAME_DB_ERR; so_PetSystem_Unsummon (FUN_004d2990); return       # the name already written stays
    RegNum set, state ∈ {5,6}, item class 36 ok:
        naming = 4; p ← 0xD408 NC_PET_SET_NAME_ACK { u16 0x34D0, u32 petID }
        broadcast 0xD413 NC_PET_SET_NAME_CMD { u16 pet handle, name }      (FUN_004d0bd0)
        p.vt[0x604] cell refresh of the pet item (0x3001 to the client)

0xD40C NC_PET_LOAD_INFO_DB_ACK { u16 nError, u16 nMasterHandle, u32 RegNum, Name4 name, u8 mind, u8 stress }:   @ FUN_004d06f0
    p and its pet as above; nError ≠ 0x3420: log, unsummon
    RegNum set and state ∈ {2,4,8}, item class 36:
        RegNum ≠ cell RegNum: log, return; item name ≠ DB name (FUN_00456710): log "Item class invalid", return
        mind/stress × 1000 into p+0x2ab98/9c; +0x2aba0/a4 = 0
        state = (state == 4) ? 5 : 6                                  (inferred: 5 first summon, 6 resummon)

0xD40E NC_PET_CREATE_DB_ACK { u16 nError, u16 nMasterHandle, u32 RegNum }:   @ FUN_004d18b0
    nError ≠ 0x3408: log ERR_PET_CREATE_DB_ERR; return            # no unsummon, state stays 3 (original bug: stuck)
    p, its pet, RegNum must be −1
    RegNum = body; → DB 0xD40B NC_PET_LOAD_INFO_DB_REQ (FUN_004d11e0)
    state == 3 and item class 36: pet.RegNum = …; cell RegNum (+0xa) = RegNum; sp_PetItemSave; state = 4

0xD412 NC_PET_LINK_RESUMMON_CMD (WM→Z) { u32 nCharNo, u8 bDoResummon, u64 xResummonCode, u16 nSummonSlot, u32 nId, u32 nRegNum }:   @ FUN_004d1b40
    p = som_FindPlayer(nCharNo) (type 2): copy the fields to p+0x2aba8 … p+0x2abc0 (resummon the pet after the map change; used by the summon code, Z09)
```

---

## 10. Other DB answers

### 10.1 NC_CHAR_GET_ITEMLIST_BY_TYPE_ACK `0x1077` / _NUM_ACK `0x109A` (DB→Z)

```pseudo
0x1077 { ref, u8 type (+6), u32 charNo (+7), u16 err (+0xb), list… (+0xd) }:   @ FUN_00518e20
    err ≠ 0x1200: ignore
    type ∈ {3, 13, 14, 16} (mini-house boxes, requested at house login §6.4): p = som_FindPlayer(charNo); p.vt[0xcc](list, type)
        (FUN_00570260 fills the box); player missing → log "player hnd[…]cannot find"
    other types: ignore
0x109A { ref, …, u16 err (+0xb) }:   @ FUN_004fc220
    charNo match: err == 0x1200 → so_ply_FillRewardInven (vt 0x9bc, the reward inventory page, Z04 §8.3)
                  else SendErrorCode(12, 0x2E, err) (0x302E)
```

### 10.2 NC_CHAR_REGNUM_VARIFICATION_ACK `0x10B4` (DB→Z) @ FUN_00551a80

`p = som_GetObject(ref.handle)`; if `so_RegistNumberVarifyCheck(body)` (vt 0x9f0) fails → `so_Disconnect(0x689)`.

---

## 11. Production (answers Z02 §8)

The **0x2035 path is live** in 2016. The client's `ProductTask` (@ client FUN_004872f0) sends `0x2035
NC_ACT_PRODUCE_CAST_REQ {u16 skill}` when the player starts producing (UI event 0x22) and `0x2039
NC_ACT_PRODUCE_CASTABORT_CMD` on cancel (event 0x23), and runs its own cast bar from the skill's cast time (`+0xcb`).

```pseudo
cast handling in ShineMobileObject_so_Routine (FUN_0056a080), cast block p+0x1d84:
    if cast end (p+0x1d84) passed and a skill row (p+0x1d98) is set:
        vt 0xef8(skill id)
        if a recipe is set (p+0x1d9c): smo_ply_ItemProduce(skill) (vt 0xecc, FUN_0046c2d0); vt 0xeac(skill, castTime); script hook vt 0xa38(2, skill)
smo_ply_ItemProduce(skill):                              @ FUN_0046c2d0
    recipe = bsearch(RecipeBook DAT_0d026fc0, 0x4C-byte rows, skill); none → p ← 0x203B NC_ACT_PRODUCE_MAKE_CMD { u16 0xFFFF, u16 0x0B09 }
    ItemProducer(p, inventory, recipe); global lock open (locking vt 0x10) → 0x203B with the error
    r = FUN_0046bf20 (materials and space check); r == 0x0B01:
        → DB 0x3457 (ITEMDB produce) { ref, ip_ProductExecute fills the consumed / produced items }   # the result arrives as Z05 item changes
    else 0x203B { 0xFFFF, r }
```

The client ignores 0x2036, 0x2038, 0x203A and 0x203B (no handler); it learns the outcome from the item cell changes and
`0x481D NC_SKILL_SKILLEXP_CLIENT_CMD` (mastery exp, `csl_AddMastery`), which `ProductTask` handles. So Z02-B5 ("legacy
path") should read: the result/broadcast packets are unused by the 2016 client, the request path is live.

---

## Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z07-B1 | 0x105C STAT_INCPOINT_REQ | per-stat-full error sent with cmd 0x67 (DEC) | answer on the wrong opcode | cmd 0x61 |
| Z07-B2 | 0x105C | `nLockIndex` of 0x10D1 not written (stale `g_buf`) | harmless (no item) | write 0 |
| Z07-B3 | 0x10D2 FREESTAT_SET_DB_ACK | success `stat` byte uninitialised when no value changed | random stat index to the client | fixed value |
| Z07-B4 | 0x1062 STAT_DECPOINT_REQ | wrong mode → no reply | client waits | send 0xAC7 like INC |
| Z07-B5 | 0x101E CHARDATAFAIL_ACK | 0x1804 carries the client handle in the error field | client shows a random code | real error code |
| Z07-B6 | 0x101D CHARDATA_ACK | no tutorial map: sends 0x1804 but continues the login | client leaves the login scene, server keeps the player | return after the failure |
| Z07-B7 | so_fill_CHAR_PARAMETER_DATA | `Wizdom` (+0x30, 8 bytes) not written | stale bytes in 0x1802 / refresh | write 0 |
| Z07-B8 | 0x1124 MINIMON_NORMAL_ON | duplicate-item error: `SendErrorCode(4, 0x362D, 0x362C)` (code as cmd) | opcode 0x362D, unknown to the client | (4, 0x125, 0x362D) |
| Z07-B9 | 0x1128 MINIMON_CHARGED_ON | errors 0x363A/0x363C/0x363D go out on 0x1125 (NORMAL ack) | wrong window | cmd 0x129 |
| Z07-B10 | 0x1093 PARTNER_INFO_REQ | in-zone 0x1094 leaves ref and LastConnect stale | (no 2016 client handler) | fill all fields |
| Z07-B11 | wedding DB answers | Success 0 of DIVORCE_* is not reported and the fee (250 000 / 750 000) is not refunded | money lost silently | refund + error |
| Z07-B12 | 0x8C12 KICKOUT | dice-game path calls vt 0x190/0x194 on the owner, not the kicked player | wrong player scheduled to leave | target.vt |
| Z07-B13 | 0x8C48 MODIFY_NOTIFY | broadcast copies `len` bytes from the request unchecked | over-read if the house method accepts len > 100 | clamp |
| Z07-B14 | 0x8C40 FURNITURE_EFFECT_REQ | profiler string says CHAR_ACTION_REQ; 0x8C32 says INNERMH_RESET_MAX_PLAYER | misleading logs | names |
| Z07-B15 | 0xC408 / 0xC40C | error replies leave CardInfo / BookMarkSlot+CardID stale | client shows wrong card | fill from the request |
| Z07-B16 | 0xCC05 RIDE_OFF_REQ | success code 0x3080 sent on 0xCC07 RIDE_OFF_FAIL_CMD | client treats success as failure packet | no packet / RIDE_OFF_CMD |
| Z07-B17 | 0xD407 SET_NAME_REQ | all failures silent; name written before the DB answer and kept on DB error | client waits; item shows an unsaved name | error ACK; write on success |
| Z07-B18 | 0xD40E CREATE_DB_ACK | DB error leaves pet state 3 | pet system stuck until relog | reset state |
| Z07-B19 | 0x1071 LOGOUTREADY | profiler string says LOGOUTCANCEL | misleading logs | name |
| Z07-B20 | 0x10B0 DEPOLYMORPH | resets StaImmortal (0x123) twice and removes protection unconditionally | immortality lost on depolymorph | reset polymorph only |

---

## 12. Not reconstructed / uncertain

Follow-up work items: **Z12** (stat calculation, level/exp, login blob parsing) and **Z13** (mini-house object, wedding
hall, pets, mounts); the DB-side questions went to D02 / D03 and the ITEMDB answers to Z05 (see `docs/knowledge/Z07.md` §4).
Corrections this item makes to Z01/Z02/Z03 are listed in `docs/knowledge/Z07.md` §0.

- `so_allparametercalculate` (vt 0x57c) itself: the layer formula is Z03 §2; only layer 0 (base) and 15 (total) were confirmed
  here via 0x1802. Level-up side effects (stat points FUN_0058bd10, reward table DAT_14d42940) not read.
- Blob bodies (`so_charskilldata`, `so_StoreInventoryFromServer`, quests, abstates, charged buffs, chest info, game data):
  only the dispatch is documented; their layouts are the WM's (W01 §6.3) and the PDB `PROTO_NC_CHAR_*_CMD` structs.
- `NC_CHAR_ZONE_SINGLE_OPTION_CMD` field meanings *(inferred)*; LINK_FROM record use.
- Wedding: `FUN_005b92a0` (after an accepted proposal), `WeddingHall.wh_Reserv` and the timetable, vt 0x40c/0x410/0x418/0x960,
  how the DB chooses `Partner.RegisterNumber` (D-items).
- Mini-house internals: the ShineMiniHouse methods (enter/out rules, furniture packets 0x8C08/0x8C09/0x8C21/0x8C24/0x8C27,
  password/maxvisitor rules), portal add, `so_MH_EffectApply`, the furniture `+0x25` byte (durability state, inferred).
  The 0x8C0B player-list element layout is the house's (`vt 0xa0`), not read.
- 0x8C3F field mapping against `MiniHouseObjAni` (§6.9).
- Minimon list kinds (normal vs charged) and the exact meaning of 0x362A/0x362C (inferred).
- `cca_IsRewardCondition` return values (decompiler dropped them).
- Mover: `so_smv_GetOff` (vt 0xcbc), LINKDATA restore, mover script hook.
- Pet: summon/unsummon flow (`so_PetSystem_*`, Z09), states 1/2/8.
- Client cross-check: client handlers are named per packet in the tables above from C01; codes without a text in
  `client-error-codes.json` are handled by their task UI (no text found).
