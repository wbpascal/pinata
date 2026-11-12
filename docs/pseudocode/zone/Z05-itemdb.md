# Zone server: ITEMDB protocol, item persistence (Z05)

Source: `Files/Server/2016/w00_Zone00/5ZoneServer2.exe` (export `re-data/exports/zone`). View any function with
`python3 -I tools/protocol-re/clean.py re-data/exports/zone tools/protocol-re/names/zone <addr>`.
Scope: the 108 dept-13 (`NC_ITEMDB_*`) answers the Character server ("GameDB", `SessionPool_Pick(g_GameDBSessions)`) sends to the
zone, registered on `GameDBSession`. The zone-side requests are documented in Z04 (`docs/pseudocode/zone/Z04-items.md`, cited as
Z04 §n) and Z07/Z08; this file pairs each answer with its request and the client-facing result.
Markers: *(pdb2017)* = 2017 PDB only, *(inferred)*, *(ours)* = name chosen here. Verified layouts:
`docs/protocol/annotations/Z05.json`. Names: `tools/protocol-re/names/zone/Z05.json`.

**Payload offsets** in this file are relative to the payload (packet + 2, after the opcode). Every ITEMDB answer starts with the
6-byte `ref` = `{u16 objHandle, u32 charNo}` (the PDB's `NETPACKETZONEHEADER`, or the 2017 struct lacks it entirely), except where
a layout is given explicitly (`MOVER_*`, `RANDOMOPTION_*`, `CLASS_CHANGE`, `ITEMINFO` … put the lock/charNo/handle in other orders).

## 1. Transaction model

### 1.1 Two commit styles

1. **Reserve → DB → apply** (almost everything). The request handler (Z04 §1.4) records the intended change as *locked cells*
   under one *lock index* in the player's `InventoryCellLockList` (`p+0xfaa8`, obtained with `p.vt[0x7d4]` FUN_0055a1d0
   *(ours: GetInventoryLocking)*), sends `NC_ITEMDB_*_REQ { ref, lockindex, … }` and increments the index (`p+0xfaac`). **Nothing
   changes in memory.** The answer carries the lock index back:
   - success → `L.vt[0x1c](p, lock, 0)` = `icl_Apply_N_Free` (§1.3): every reservation of that index is applied, the client gets
     the resulting `NC_ITEM_CELLCHANGE_CMD` / `EQUIPCHANGE_CMD` / `CENCHANGE` packets, the locks are freed;
   - failure → `L.vt[0x28](lock)` = `icl_Free`: the reservations are dropped; memory was never touched, so nothing needs undoing.
   The answer handler then sends the feature's `NC_ITEM_*_ACK` with the DB's code or a fixed success code.
2. **Apply → DB, disconnect on failure** (drop, pick-up, pick money, `INC_DEC_MONEY`). The request handler changes the inventory at
   once (`sp_ChangeCell` → client), sends the DB request and sets the list's *DB-pending flag* `L+0x7828 = 1`
   (`L.vt[0x14](1)`, FUN_00488760 *(ours: SetDBPending)*). The flag makes `L.vt[0x10]` / `L.vt[0x18]` report "locked", so every
   other item request is refused until the answer. Success clears the flag (`vt[0x14](0)`); failure **disconnects** the player
   (`so_Disconnect(0x684)`), so the zone's state is discarded and the next login reloads the DB truth. There is no in-memory rollback.

Consistency checks after stack operations (§4): `so_ply_ItemLotCheck` compares the zone's lot with the DB's result lot
(`MergeResultLot`, `RemainLot`, `ResultLotFrom/To`); a mismatch logs `" Merge Error "` / `" Split Error "` / `" SplitMerge Error"`
and disconnects with `0x68c`. `ItemLotInspector` (`p+0x1ea8`, FUN_00491f90 *(ours: ItemLotInspector_CheckAndReset)*) is reset after
every move/split answer; with argument 1 it first runs `ItemLotInspector_ili_Check` (FUN_00491c30).

### 1.2 `InventoryLocking::InventoryCellLockList` vtable (`p+0xfaa8`)

Recovered from RTTI (32 slots). Request-side slots are Z04 §1.4.

| Slot | Function | Meaning |
|---|---|---|
| 0x00–0x0c | `icl_IsLocked` ×4 | cell locked (by inven / type+slot variants) |
| 0x10 | FUN_0048b530 *(ours: IsBusy)* | DB-pending flag set, or any locked cell whose releaser reports busy (releaser vt 8) |
| 0x14 | FUN_00488760 *(ours: SetDBPending)* | `L+0x7828 = arg` (style 2 flag) |
| 0x18 | FUN_0048b5a0 *(ours: HasLocks)* | DB-pending flag or list not empty |
| 0x1c | FUN_0048be90 `icl_Apply_N_Free` | apply + free all reservations of a lock index |
| 0x20 | FUN_0048c100 `icl_Apply_N_Free` | same, with a list-corruption check (used by `USE_ACK`) |
| 0x24 | FUN_0048b3f0 `icl_Free(type, slot)` | free the first reservation of one cell, without undo |
| 0x28 | FUN_0048b2c0 `icl_Free(lock)` | free all reservations of a lock index (releaser vt 0xc = undo hook, a no-op except FurnitureReloc) |
| 0x2c … 0x7c | `icl_OnlyLock`, `icl_ClearItem`, `icl_StoreItem`, `icl_StoreMoney`, … | reservation constructors (Z04 §1.4) |

### 1.3 Apply and free @ FUN_0048be90, FUN_0048c100, FUN_0048b2c0

```pseudo
icl_Apply_N_Free(L, p, lock, ctx):                         @ FUN_0048be90 (vt 0x1c)
    clear the global LotChanger list (DAT_0d55b600, ItemLotAnalyser)
    for each locked cell e (0xA0-byte entry) with e.lock == lock:
        copy e; remove it from the list; e.releaser.icr_Apply(p, &e, ctx)       # releaser vt 0 (table §1.4)
        applied += 1
    if applied == 0: log "icl_Apply_N_Free : No Releaser apply - LockIndex maybe wrong"
    for each (cell, delta) the releasers recorded in the LotChanger list:
        p.so_ply_ItemLotChange(cell, delta)        # vt 0x7f8 FUN_00578270 → CQuestZone (p+0x173e8) item-count hooks vt 0xc (+) / 0x10 (−)
    # return value = applied > 0 (inferred: the callers log "<handler> : <lock>" when it is false)

FUN_0048c100 (vt 0x20): identical, but if a list node is null/inactive it logs the list state, resets the list
    and disconnects the player: p.so_Disconnect(0x690)

icl_Free(L, lock):                                          @ FUN_0048b2c0 (vt 0x28)
    for each e with e.lock == lock: e.releaser.vt[0xc](L+8); remove e     # no message to the client
```

### 1.4 Releasers (what "apply" does), `InventoryLocking::InvenCellReleaser_*::icr_Apply`

| Releaser | icr_Apply | Effect on apply |
|---|---|---|
| `CellChange` | FUN_0048a420 | write the reserved item into the cell (`FUN_00642f60`), `sp_ChangeCell` → client 0x3001/0x3002; lot bookkeeping; if an equip cell lost an item whose `g_ItemUsage` class is 2 → minimon auto-buff off (vt 0xe58 FUN_00563ef0); vt 0xe5c FUN_00564c90 drops the item from the minimon auto-use lists when none is left |
| `CellClear` | FUN_0048a2e0 | empty the cell (key −1, id 0xFFFF), `sp_ChangeCell`; same minimon hooks |
| `CellChangeSmall` | FUN_00487f60 | `so_ply_StoreItem` (small-item box) |
| `CenChange` | FUN_00487d50 | money ± amount (`p+0x7f77` u64; a negative result logs "Minus money" and clamps to 0), `so_ply_ChangeCen` → `0x1033 NC_CHAR_CENCHANGE_CMD {u64 cen}` |
| `FameChange` | FUN_00487e60 | fame ±, `so_ply_ChangeFame`, `so_ply_SaveFame` |
| `CoinChange` | FUN_00489be0 | gamble coin ±, `so_Gamble_ChangeCoin` / `so_Gamble_ChangeExchangedCoin` |
| `PointStone` | FUN_004880f0 | `so_ply_InvenCellReleaser_PointStone` (soul-stone counters) |
| `QuestReward` | FUN_004881a0 | `so_ply_InvenCellReleaser_QuestReward` |
| `ItemUse` | FUN_00488020 | the stored `UseEffect` actor's `uib_Effect(p, cell, g_ItemUseTable[id])` (actor vt 0x10; Z04 §6.3) |
| `ItemSell` | FUN_00487a70 | FUN_00537a20 *(ours: RepurchaseList_Insert)*: add the sold item to the repurchase list → `0x305C NC_ITEM_SELL_ITEM_INSERT_CMD {u16 nHandle, SHINE_ITEM_STRUCT}`; a full list first drops the oldest → `0x305D NC_ITEM_SELL_ITEM_DELETE_CMD {u16 nHandle}` |
| `ItemRepurchase` | FUN_00487aa0 | FUN_00537ba0 *(ours: RepurchaseList_Delete)* → `0x305D {nHandle}` |
| `EquipLocation` | FUN_0048ca20 | brief-info update (`so_ply_ChangeBriefInfo` for the slot and a second, view slot), `so_allparametercalculate`, re-broadcast of the look (vt FUN_0055ab60); item-action ids of the item, its 3 gems (weapons, class 5) and its set (`ItemInfo+0x156`) are added (FUN_0048c8c0, FUN_00560840) |
| `UnEquipInfo` | FUN_0048cc60 | the reverse: item-action / gem / set ids removed (FUN_0048c970, FUN_00560880) |
| `CardOpen` / `CardRegist` | FUN_0048b850 / FUN_0048b700 | `0xC407 NC_COLLECT_CARDOPEN_CMD` / `so_ply_CardRegist` + `0xC40B NC_COLLECT_CARDREGIST_ACK` |
| `FurnitureReloc` / `FurnitureCellClear` | FUN_0048a560 / FUN_0048aa60 | mini-house furniture placed/removed: `0x8C21` REARRANGE / `0x8C24` CREATE_FURNITURE / `0x8C27` DELETE_FURNITURE (Z07 §6.8); undo hook (vt 0xc, run by `icl_Free`) FUN_00487910 sends `so_SendErrorCode(0x23, 0x20, 0x11ce)` = `0x8C20 {0x11ce}` |
| `GuildStorageChange` / `GuildStorageClear` | FUN_0048aca0 / FUN_0048ab80 | update the shared guild storage and tell the other zones: `0x7493 NC_GUILD_STORAGEWITHDRAW_RNG` |
| `GuildAcademyRewardStorage*` | FUN_0048af20, FUN_0048af10, FUN_00488250 | academy reward storage; `…InfoZoneRng` sends `0x9884 NC_GUILD_ACADEMY_REWARDSTORAGE_ITEM_INFO_ZONE_RNG` |
| `LinkInfo` | FUN_0048b9a0 | map-link scroll destination (Z04 §12.11) |
| base `InvenCellReleaser` | FUN_00487d00 | nothing (plain cell lock, e.g. the drop/break confirmation) |

### 1.5 Client packets produced by an apply

```pseudo
sp_ChangeCell(p, &inven, cell, &exchange):                  @ FUN_00518260 (vt 0x604)
    if inven.type == 8 (equipment):
        0x3002 NC_ITEM_EQUIPCHANGE_CMD { u16 exchange, u8 location = slot, SHINE_ITEM_VAR item }
    else:
        0x3001 NC_ITEM_CELLCHANGE_CMD  { u16 exchange, u16 location = inven, SHINE_ITEM_VAR item }
    item = u16 itemID; when ≠ 0xFFFF followed by the class-specific attribute bytes (FUN_006406f0, the attribute class' writer)
```

Layouts agree with `PROTO_NC_ITEM_CELLCHANGE_CMD` / `PROTO_NC_ITEM_EQUIPCHANGE_CMD`. Client: `FUN_004aaa40` / `FUN_004ab400` write the
item into the cell. `exchange` = the other cell of a move (equal to `location` for a plain change).

### 1.6 Handler skeleton and the error helpers

```pseudo
gds_NC_ITEMDB_<X>_ACK(pkt):
    p = som_GetObject(g_Objects, pkt.ref.objHandle)          # a few handlers: som_FindPlayer(charNo) instead
    if p == null or p.IsClosing() (vt 0x300) or p.GetCharNo() (vt 0x344) ≠ pkt.ref.charNo: return   # silently; the
        # reservations of a closed/replaced player die with its object
    …
so_SendErrorCode(p, dept, cmd, code):  send (dept<<10|cmd) { u16 code } to p          @ FUN_0054f050 (vt 0x308)
so_NC_ITEMDB_fail(p, dept, cmd, code): = so_SendErrorCode                              @ FUN_00517eb0 (vt 0x350)
```

Which checks each handler skips is noted per handler. Handlers that use `vt 0xbbc` (FUN_00450350, returns `this`) instead of the
IsClosing test do **not** check IsClosing (`MOVER_*`, `ITEMMONEY_BUY`, `RANDOMOPTION_*`, `CLASS_CHANGE`, `MIX_ITEM`, `MAPLINK`).

### 1.7 Requests and answers

| Request (zone → DB) | Sent by (Z04/Z07/Z08 §) | Answer(s) (§ here) |
|---|---|---|
| `0x3401` ADMINCREATE_REQ | `&` make-item (FUN_00527270) | `0x3402`/`0x3403` (§9.1) |
| `0x340A` BUYALL / `0x340D` BUYLOT | NC_ITEM_BUY (Z04 §2.1) | `0x340B`/`0x340E`, `0x340C`/`0x340F` (§2.1) |
| `0x3410` EQUIP / `0x3413` UNEQUIP | Z04 §5 | `0x3411`/`0x3412`, `0x3414`/`0x3415` (§5.1) |
| `0x3416` DROPALL / `0x3419` DROPLOT | Z04 §3.1 | `0x3417`/`0x3418`, `0x341A`/`0x341B` (§3.1) |
| `0x341C` PICKALL / `0x341F` PICKMERGE / `0x3438` PICKMONEY | Z04 §3.3 | `0x341D`/`0x341E`, `0x3420`/`0x3421`, `0x3439`/`0x343A` (§3.2) |
| `0x3422` SELLALL / `0x3425` SELLLOT | Z04 §2.4 | `0x3423`/`0x3426`, `0x3424`/`0x3427` (§2.2) |
| `0x3428` RELOC / `0x342B` EXCHANGE / `0x342E` MERGE / `0x3431` SPLIT_N_MERGE / `0x3434` SPLIT | Z04 §4 | `0x3429`…`0x3436` (§4) |
| `0x343B` ITEMTRADE | trade (Z06) FUN_00594870 | `0x343C`/`0x343D` (§9.10) |
| `0x343E`/`0x343F` USE | Z04 §6.1 | `0x3440` (§6.1) |
| `0x3441` SOULSTONEBUY | Z04 §13.1 | `0x3442`/`0x3443` (§2.4) |
| `0x3444` OPENSTORAGE | Z04 §7, store NPC | `0x3446`/`0x3445` (§7.1) |
| `0x3447` UPGRADE / `0x34D1` NEW_UPGRADE / `0x34D3` BRACELET_UPGRADE | Z04 §9 | `0x3448`, `0x34D2`, `0x34D4` (§8.1) |
| `0x3449` ITEMCHANGE | 12 senders (item attribute/time changes: FUN_0045e350, FUN_00534c60, FUN_005979b0 …) | `0x344A` (§5.4) |
| `0x344D` CREATEITEMLIST | scripts/quests (FUN_005e17e0, FUN_005e1b30, FUN_00625340) | `0x344E`/`0x344F` (§9.2); `0x344C` ITEMTOTALINFORM (§9.3) |
| `0x346D` CHESTITEM / `0x3450` GETFROMCHEST | chest use (FUN_00598c90) | `0x346E` → `0x3450` → `0x3451`/`0x3452` (§6.2) |
| `0x3453`/`0x3454`/`0x3455` BOOTHTRADE_* | booths (Z06) | `0x3456` (§9.11) |
| `0x3457` PRODUCE | `smo_ply_ItemProduce` (Z07 §11) | `0x3458` (§9.4) |
| `0x3459` DESTROY | ItemBreaker, `&` clear, quests… (7 senders) | `0x345A` (§6.4) |
| `0x345B` QUESTREWARD | quest reward (Z08) | `0x345C` (§6.5) |
| `0x345F` DEPOSIT / `0x3461` WITHDRAW | Z04 §7.1 | `0x3460`, `0x3462` (§7.1) |
| `0x3463` CHARGED_LIST / `0x3465` CHARGED_WITHDRAW | Z04 §8 | `0x3464`, `0x3466` (§7.4) |
| `0x3467` CREATEMUSHROOM | mini-house item (FUN_0043eab0) | `0x3468`/`0x3469` (§9.5) |
| `0x346A` ITEMBREAK | ItemBreaker (Z04 §3.2) | `0x346B`/`0x346C` (§6.4) |
| `0x3471` OPEN_GUILD_STORAGE | guild storage NPC (FUN_004762d0, FUN_004c2990) | `0x3473`/`0x3472` (§7.2) |
| `0x3474` GUILD_STORAGE_WITHDRAW | Z04 §7.4 | `0x3475` (§7.2) |
| `0x3476` DISMANTLE | Z04 §12.1 | `0x3477` (§8.6) |
| `0x347A` INC_DEC_MONEY | FUN_0052ffc0 | `0x347B`/`0x347C` (§3.3) |
| `0x347D` MINIHOUSE_EFFECT_DEMANDGOOD / `0x3489` PORTAL_… | Z07 §6.10 | `0x347E` (§9.6); **no** `0x348A` handler |
| `0x347F` REINFORCEUNEQUIP | FUN_004a4da0 | `0x3480`/`0x3481` (§5.2) |
| `0x3482` / `0x3485` / `0x3487` academy reward storage | Z04 §7.5, Z08 | `0x3484`/`0x3483`, `0x3486`, `0x3488` (§7.3) |
| `0x348B` FURNITURE_ENDURE | Z04 §8.4 | `0x348C` (§9.7) |
| `0x348D` / `0x34C6` WEAPON / SHIELD ENDURE_CHARGE | Z04 §12.2 | `0x348E` / `0x34C7` (§8.7) |
| `0x3490` / `0x3493` GUILD_TOKEN_BUY | Z04 §2.3 | `0x3491`/`0x3494`, `0x3492`/`0x3495` (§2.3) |
| `0x3496` / `0x3498` / `0x349A` ENCHANT | Z04 §10 | `0x3497`, `0x3499`, `0x349B`; `0x349D` (§8.2) |
| `0x349E` MYSTERY_VAULT_MAKEITEM | FUN_005658f0 | `0x349F` (§9.8) |
| `0x34A0` BUYCAPSULE / `0x34A2` CAPSULEITEM / `0x34A4` GETFROMCAPSULE | shop / capsule use | `0x34A1`, `0x34A3` → `0x34A4` → `0x34A5` (§2.5, §6.3) |
| `0x34A6` EQUIP_BELONGED_CANCEL_USE | Z04 §12.6 | `0x34A7` (§5.3) |
| `0x34A8` ITEMINFO / `0x34AA` ITEMREBUILD | card open (FUN_00627740, FUN_006281b0) | `0x34A9` → `0x34AA` → `0x34AB` (§6.6) |
| `0x34AC` / `0x34AE` MOVER_UPGRADE / RAREMOVER | Z04 §9.5 | `0x34AD`, `0x34AF` (§8.3) |
| `0x34B0`/`0x34B1` ITEMMONEY_BUY | Z04 §2.2 | `0x34B2` (§2.6) |
| `0x34B3` / `0x34C1` / `0x34CD` RANDOMOPTION_* | Z04 §11 | `0x34B4`, `0x34C2`, `0x34CE` (§8.4) |
| `0x34B5` CHAT_COLOR_CHANGE | Z04 §12.8 | `0x34B6` (§8.5) |
| `0x34B7` TERMEXTEND | Z04 §12.9 | `0x34B8` (§8.5) |
| `0x34B9` / `0x34BB` REPURCHASE | Z04 §2.5 | `0x34BA`, `0x34BC` (§2.2) |
| `0x34BD` CLASS_CHANGE | Z04 §12.10 | `0x34BE` (§8.5) |
| `0x34BF` UES_FRIEND_POINT | Z08 (friend points) | `0x34C0` (§9.9) |
| `0x34C9` MAPLINK_ITEM_CONSUME | Z04 §12.11 | `0x34CA` (§8.5) |
| `0x34CB` MIX_ITEM | Z04 §12.12 | `0x34CC` (§8.5) |

New item keys are never minted by the DB: the zone builds them (`ItemKey_Make` FUN_00640710, Z04 §1.4) and the request carries them,
so an answer only confirms (or the merge/split answers return the keys and lots for the consistency check).

## 2. Shop

### 2.1 Buy: `0x340B`/`0x340E` BUYALLSUC/BUYLOTSUC, `0x340C`/`0x340F` BUY*FAIL

```pseudo
0x340B NC_ITEMDB_BUYALLSUC_ACK { ref, u16 lockindex }      @ FUN_00525180
0x340E NC_ITEMDB_BUYLOTSUC_ACK { ref, u16 lockindex }      @ FUN_005252c0 (identical)
    skeleton (IsClosing + charNo)
    L.Apply_N_Free(lockindex)            # new cell / merged stack, money (or fame/coin) reservation → 0x3001 + 0x1033
    p ← 0x3004 NC_ITEM_BUY_ACK { 0x201 }                      # "Item has been purchased."
    FUN_00523b10 (vt 0xb44, ours: NPCActionAfterBuy)(p, 1)   # see below

0x340C / 0x340F / 0x3492 / 0x3495 NC_ITEMDB_*BUY*FAIL_ACK { ref, u16 error, u16 lockindex }   @ FUN_00525740 (one handler)
    p ← 0x3004 { error }  (so_NC_ITEMDB_fail 12/4);  L.Free(lockindex)

FUN_00523b10(p, type):                                      # scripted NPC reaction to a purchase
    npc = som_GetObject(p+0x2aa80 = the NPC whose menu is open); need its role name (npc.vt[0x3c] → +2, 32 chars)
    for each row r of ReactionType.shn (g_ReactionType DAT_1328bd78, loaded @ 0x5b6d7f: RAType u32, MobInx char[32], Ecode u32):
        if r.RAType == type and npc's MobInx == r.MobInx:
            p ← 0x2072 NC_ACT_NPC_ACTION_CMD { u8 nType = type, u16 nNPCHandle, u32 nECode = r.Ecode }; p+0x2aa80 = 0xFFFF; break
```

2016 `ReactionType.shn` has one row: `{1, "LC_Machine", 800000}`: buying from the `LC_Machine` NPC (a vending machine, inferred from
the name) makes it play an animation. Client `On_NC_ACT_NPC_ACTION_CMD` FUN_004a5a10: `Char::ActAction(npc, Ecode / 10000 × 10000,
(Ecode / 100 mod 100) × 100)`.

### 2.2 Sell and repurchase

```pseudo
0x3423 SELLALLSUC_ACK / 0x3426 SELLLOTSUC_ACK { ref, u16 lockindex }    @ FUN_005393e0 / FUN_00539510
    skeleton; L.Apply_N_Free → cell cleared/reduced, money +, ItemSell releaser → 0x305C (repurchase list)
    p ← 0x3005 NC_ITEM_SELL_ACK { 0x381 }

0x3424 / 0x3427 SELL*FAIL_ACK { ref, u16 error, u16 lockindex }        @ FUN_00539640
    p ← 0x3005 { pkt.ref.objHandle }   # sends the player's object handle as the error code, the DB error is ignored (original bug) Z05-B1
    L.Free(lockindex)

0x34BA NC_ITEMDB_REPURCHASE_ALL_ACK / 0x34BC …_LOT_ACK { u16 nHandleNum, u32 nCharRegNum, u16 nError, u16 nLockIndex }
                                                            @ FUN_005382e0 / FUN_00538430 (no IsClosing check)
    if nError == 0x3668: L.Apply_N_Free(nLockIndex)        # item back, money −, ItemRepurchase releaser → 0x305D
    else:                L.Free(nLockIndex)
    p ← 0x305A NC_ITEM_REPURCHASE_ACK { nError }  (so_SendErrorCode 12/0x5a)
    FUN_00523b10(p, 1)                                      # even on failure
```

### 2.3 Guild-token buy: `0x3491`/`0x3494` and fails

```pseudo
0x3491 GUILD_TOKEN_BUYALLSUC_ACK / 0x3494 …BUYLOTSUC_ACK { ref, u16 lockindex, u32 nGuildNo, u32 nPriceGuildToken }
                                                            @ FUN_00525400 / FUN_005255a0
    first, unconditionally (even when the player is gone):
        → WM 0x74C0 NC_GUILD_ZONE_USE_GUILD_TOKEN_CMD { u32 nGuildNo, u32 nPriceGuildToken, u32 0 }   # the WM deducts the tokens (W03)
    then as §2.1 (Apply, 0x3004 {0x201}, FUN_00523b10(p, 1))
fails 0x3492 / 0x3495: FUN_00525740 (§2.1)
```

### 2.4 Soul stones: `0x3442` / `0x3443`

```pseudo
0x3442 SOULSTONEBUYSUC_ACK { ref, u16 lockindex }           @ FUN_00588800
    Apply: the PointStone releaser (so_ply_InvenCellReleaser_PointStone FUN_0052d820) adds the stones and sends
           0x5003 NC_SOULSTONE_HP_BUY_ACK / 0x5004 SP_BUY_ACK { u16 new total } (client: User::SetHPStone/SetSPStone); money −
    p ← 0x3004 NC_ITEM_BUY_ACK { 0x201 } ("Item has been purchased."); FUN_00523b10(p, 1)
0x3443 SOULSTONEBUYFAIL_ACK { ref, u16 lockindex, u16 err } @ FUN_00588940
    p ← 0x3004 { err };  Free(lockindex)
```

The failure goes out as `0x3004 { err }`, not as `0x5005 NC_SOULSTONE_BUYFAIL_ACK` like the request-side errors (Z04 §13.1); the
client's BUY handler shows texts only for its own 0x20x codes, so a DB error here is silent.

### 2.5 Capsule buy: `0x34A1`

```pseudo
0x34A1 NC_ITEMDB_BUYCAPSULE_ACK { ref, u16 nBuyNpcHandle, u16 nLockIndex, u16 nError }    @ FUN_00525840
    if nError == 0x201: Apply(nLockIndex); FUN_00523b10(p, 1)  else Free(nLockIndex)
    p ← 0x3004 { nError }
```

(2016 handler string says `gds_NC_ITEMDB_BUYCAPSULE_REQ`; the PDB name `…_ACK` fits the direction, C02 §conflicts.)

### 2.6 Item-money buy: `0x34B2`

```pseudo
0x34B2 NC_ITEMDB_ITEMMONEY_BUY_ACK { u16 nLockIndex, u32 nCharRegNum, u16 nHandleNum, u16 nError }   @ FUN_00469000
    p = som_GetObject(nHandleNum); charNo check (no IsClosing)
    if nError == 0x3240: Apply; p ← 0x3004 { 0x201 }
    else:                p ← 0x3004 { 0x3241 }; Free         # the DB code is replaced by 0x3241
    FUN_00523b10(p, 1); p+0x5cba bit 1 = 0 (FUN_00561770; the "item-money buy in flight" flag, inferred)
```

## 3. Drop, pick-up, money (style 2: applied before the DB answer)

### 3.1 Drop: `0x3417`, `0x3418`, `0x341A`, `0x341B`

The request (`ItemInventory_ii_DropAll` FUN_00529a70, Z04 §3.1) already emptied the cell (`sp_ChangeCell` → `0x3001`), ran
`so_ply_ItemAction_UnEquip` for an equip cell, and set DB-pending.

```pseudo
0x3417 NC_ITEMDB_DROPALLSUC_ACK { ref, SHINE_ITEM_STRUCT item = { u64 key, u16 itemID, SHINE_ITEM_ATTRIBUTE attr[101] } }
        (117-byte payload; character sender FUN_0040b140; the PDB's 1-byte struct is a stub)   @ FUN_0052ab80
    p = som_GetObject; IsClosing check only (no charNo check)
    unknown itemID: return                                  # pending flag stays set (original bug) Z05-B4
    o = som_AllocObject(type 1 = drop item); none: log "ii_DropAll : itemlist buffer full"; p ← 0x3008 { 0x304 }; return
    r = o.so_ItemDrop(handle, p, &item, 0, dropper-info, 0)    @ ShineDropItem FUN_0052a7a0 (vt 0x544)
        # copies the 111-byte item, places it at p's position; owner-only time = now + ItemInfoServer.looting (+0xae) / 100 s,
        # vanish time = now + ItemInfoServer.Vanish (+0xaa) / 100 s (g_Now is in seconds);
        # marks the map, broadcasts the drop; 0x305 "dropper has no map"
    if r == 0x301:
        p ← 0x3008 NC_ITEM_DROP_ACK { 0x301 }; L.SetDBPending(0)
        recalc passive/equip/last parameters, vt 0x528, weapon speed
    else: som_FreeObject(o); p ← 0x3008 { r }               # pending flag stays set (Z05-B4)

0x341A NC_ITEMDB_DROPLOTSUC_ACK { ref }  (6-byte payload; 2016 string "DROPALLLOT")   @ FUN_0052ad70
    p ← 0x3008 { 0x301 }; L.SetDBPending(0)                # no drop object is created for a partial drop (unreachable, Z04-B4)

0x3418 DROPALLFAIL_ACK / 0x341B DROPLOTFAIL_ACK { ref, u16 err }                  @ FUN_0052ae60 / FUN_0052af60
    p ← 0x3008 { pkt.ref.objHandle }   (Z05-B1);  p.so_Disconnect(0x684)
```

### 3.2 Pick-up: `0x341D`…`0x3421`, `0x3439`, `0x343A`

The request (Z04 §3.3, FUN_0052f1b0 …) already put the item into the inventory (`sp_ChangeCell`), removed the drop object and set
DB-pending; it remembered the picked item in `p+0x29278` (u16 itemID) / `p+0x2927c` (u32 lot).

```pseudo
0x341D PICKALLSUC / 0x3420 PICKMERGESUC / 0x3439 PICKMONEYSUC  { ref, … }    @ FUN_00530110 / FUN_00530310 / FUN_00530510
    so_ply_itempickresult(0x341, 0xFFFF)                   @ FUN_005308d0 (vt 0x6c0)
        → p ← 0x300A NC_ITEM_PICK_ACK { u16 itemid = p+0x29278, u32 lot = p+0x2927c, u16 error = 0x341, u16 itemhandle = 0xFFFF }
          and the map's script interrupt "PickUpItem" (ScriptInterruptManager_sim_PickUpItem) with (p handle, itemID)
    L.SetDBPending(0)
0x341E / 0x3421 / 0x343A  *FAIL_ACK { ref, u16 err }                        @ FUN_00530210 / FUN_00530410 / FUN_00530610
    so_ply_itempickresult(pkt.ref.objHandle, 0xFFFF)  → 0x300A { 0xFFFF, 0, error = objHandle (Z05-B1), 0xFFFF }
    p.so_Disconnect(0x684)
```

Client `0x300A` (FUN_004aba00): `0x341` "[%s] has been obtained." / "[%s (%d)] has been obtained." (Z04 §3.3 lists the other codes).
The success ACK always carries `itemhandle 0xFFFF`.

### 3.3 Money: `0x347B` / `0x347C`

```pseudo
0x347B NC_ITEMDB_INC_DEC_MONEYSUC_ACK { ref, … }   @ FUN_00530710:  L.SetDBPending(0)
0x347C NC_ITEMDB_INC_DEC_MONEYFAIL_ACK { ref, … }  @ FUN_005307f0:  p.so_Disconnect(0x684)
```

The request `0x347A` (FUN_0052ffc0) has already changed the money; no client packet is sent here.

## 4. Moving and stacking

All five success handlers share one shape; all five failures share another.

```pseudo
0x3429 RELOCSUC / 0x342C EXCHANGESUC { ref, u16 lockindex }           @ FUN_00533070 / FUN_00533350
0x342F MERGESUC { ref, u16 lockindex, u64 lotmain, u16 MergeResultLot }                    @ FUN_00533630
0x3432 SPLIT_N_MERGESUC { ref, u16 lockindex, u64 FromItemKey, u64 ToItemKey, u16 MoveLot,
                          u16 ResultLotFrom, u16 ResultLotTo }                              @ FUN_00533a40
0x3435 SPLITSUC { ref, u16 lockindex, u64 lotmain, u16 RemainLot }                          @ FUN_00539740
    skeleton
    if not L.Apply_N_Free(lockindex): log; InvenArrange_SetRunning(p, 0) (FUN_00560dc0, p+0x2ab18 = 0)   # abort auto-arrange
    p ← 0x300C NC_ITEM_RELOC_ACK { 0x241 }        (SPLIT: 0x300E NC_ITEM_SPLIT_ACK { 0x441 })
    MERGE:  if so_ply_ItemLotCheck(lotmain) ≠ MergeResultLot: log " Merge Error "; so_Disconnect(0x68c)
    SPLIT:  if ItemLotCheck(lotmain) ≠ RemainLot: log " Split Error "; so_Disconnect(0x68c)
    SPLIT_N_MERGE: if ItemLotCheck(From) ≠ ResultLotFrom or ItemLotCheck(To) ≠ ResultLotTo: log " SplitMerge Error"; so_Disconnect(0x68c)
    InvenArrange_Run (vt 0xd1c, FUN_00563500; not for SPLIT)        # next step of a running auto-arrange (Z04 §12.5): it runs
        # while p+0x2ab18 ≠ 0 (vt 0xd14 FUN_00560db0); NC_ITEM_AUTO_ARRANGE_INVEN_REQ (FUN_0051c360) and an & command (FUN_004197e0)
        # start it with InvenArrange_SetRunning(1) (value 0xc0)
    if not ItemLotInspector_CheckAndReset(1): so_Disconnect(0x68c)     # dead: the function always returns true (original bug) Z05-B3

0x342A RELOCFAIL / 0x342D EXCHANGEFAIL / 0x3430 MERGEFAIL / 0x3433 SPLIT_N_MERGEFAIL / 0x3436 SPLITFAIL { ref, u16 error, u16 lockindex }
                                          @ FUN_00533220 / FUN_00533500 / FUN_00533910 / FUN_00533ca0 / FUN_00539930
    p ← 0x300C { error }   (SPLITFAIL: 0x300E { error })
    L.Free(lockindex); InvenArrange_SetRunning(0) (not SPLITFAIL: a failed move aborts the auto-arrange); ItemLotInspector_CheckAndReset(0)
```

`so_ply_ItemLotCheck` (FUN_0053a5c0, vt 0x974) finds the cell holding the key and returns its current lot. Client: `0x300C`
FUN_004ab910 (`0x241` = success, no text), `0x300E` FUN_004a8360.

## 5. Equipment

### 5.1 Equip / unequip: `0x3411`, `0x3412`, `0x3414`, `0x3415`

```pseudo
0x3411 NC_ITEMDB_EQUIPSUC_ACK { ref, u16 lockindex }          @ FUN_0052cba0
    skeleton; Apply (CellChange ×2 + EquipLocation → 0x3002/0x3001, brief info, item actions)
    p ← 0x3011 NC_ITEM_EQUIP_ACK { 0x281 }
    so_briefequipset; recalc passive / equip / last parameters; vt 0x528; weapon speed; weapon range;
    FUN_0052b0e0 (p+0x173cc "equip in flight" = 0, then sp_DecorationActivCheck); so_ply_AbstateMatchEquip;
    FUN_0052b5e0 (ours: EquipViewSlot_Flush: re-sends the view slots marked dirty, vt FUN_0052ce60, then clears the marks)
0x3412 NC_ITEMDB_EQUIPFAIL_ACK { ref, u16 error, u16 lockindex }   @ FUN_0052cd50
    p ← 0x3011 { pkt.ref.objHandle } (Z05-B1); Free(lockindex); FUN_0052b0e0; FUN_0052b690 (clear the dirty view-slot marks)
    # the item was bound at request time (Z04 §5.1) and stays bound

0x3414 NC_ITEMDB_UNEQUIPSUC_ACK { ref, u16 lockindex }        @ FUN_0053b0a0
    Apply (UnEquipInfo + CellChange)
    so_SendErrorCode(12, 0x11, 0x281) → p ← 0x3011 NC_ITEM_EQUIP_ACK { 0x281 }      # EQUIP_ACK, not 0x3013 UNEQUIP_ACK (original bug) Z05-B2
        # invisible to the player: the client's EQUIP handler treats 0x281 as success and shows nothing
    if neither equip slot 0x19 nor 0x1c holds an item of usage class 1 and auto-pick is on (p+0x5cb9 bit 3): sp_SetAutoPick(p, 0)
        # inferred: the auto-pick accessory (minimon) was taken off
    same recalculation chain as EQUIPSUC (without FUN_0052b0e0)
0x3415 NC_ITEMDB_UNEQUIPFAIL_ACK { ref, u16 error, u16 lockindex }   @ FUN_0053af90
    L.Free(<payload+6> = error)   # frees the lock index named by the error field; the real reservation stays (original bug) Z05-B5
    p ← 0x3013 { pkt.ref.objHandle } (Z05-B1); FUN_0052b690
```

The Character server sends `0x3415` as `{ref, u16 err = 0x28a, u16 lockindex}` (character FUN_0040afc0), so the zone frees lock
`0x28a`.

### 5.2 Reinforce unequip: `0x3480` / `0x3481`

```pseudo
0x3480 REINFORCEUNEQUIPSUC_ACK { ref, u16 lockindex }        @ FUN_004a5100
    Apply; briefequipset + recalculation; so_ply_AbstateMatchEquip    # no client ACK (the item cell changes are the answer)
0x3481 REINFORCEUNEQUIPFAIL_ACK { ref, u16 error, u16 lockindex }   @ FUN_004a5270
    L.Free(<payload+6> = error)   # same field slip as 0x3415 (original bug) Z05-B5
```

The request `0x347F` is sent by FUN_004a4da0 (a forced unequip when an equipped item's requirements are no longer met, inferred).

### 5.3 Bound-item cancel: `0x34A7`

```pseudo
0x34A7 NC_ITEMDB_EQUIP_BELONGED_CANCEL_USE_ACK { ref, u16 nLockIndex, u16 nError, u64 nBelongedItem_ItemKey, u16 nBelongedItem_ItemID,
                                                 u64 nCancelItem_ItemKey, u16 nCancelItem_ItemID, u32 … }   @ FUN_0051bfa0
    p = som_GetObject(ref.objHandle)   # no IsClosing, no charNo check
    p ← 0x3049 NC_ITEM_EQUIP_BELONGED_CANCEL_USE_ACK { nError }        # client FUN_004b3940: success "Succesfully Unbound %s"
    if nError == 0x2880: Apply (log "… Not Free" if nothing applied, else game log FUN_006147f0(2000, charNo, map, x, y, keys/ids…))
    else: Free
```

### 5.4 Item attribute change: `0x344A`

```pseudo
0x344A NC_ITEMDB_ITEMCHANGE_ACK { ref, u16 lockindex, u16 err }    @ FUN_00597ec0
    err == 0x901: Apply  else Free
    FUN_0052b6b0 (ours: EquipViewSlot_Rebuild): for each changed equip slot recompute conflicts with EquipEnumChanger
        (eec_EquipLocation / ConflictWithNew/OldEquip / …ViewSlot), mark the view slots, then EquipViewSlot_Flush
```

`0x3449 ITEMCHANGE_REQ` has 12 senders (time-limited items expiring, attribute changes, Z04 §12, mini-house, …). No client ACK.

## 6. Using, opening and destroying items

### 6.1 Item use: `0x3440`

```pseudo
0x3440 NC_ITEMDB_USE_ACK { ref, u16 lockindex, u16 error }    @ FUN_0053fa40
    skeleton
    if error == 0x700:
        so_NC_ITEMDB_USE_ACK(p, lockindex)                      @ FUN_0053fb50 (vt 0x354)
            p ← 0x3016 NC_ITEM_USE_ACK { u16 error = 0x700, u16 useditem = p+0x2a7c6, u8 invenType = 9 }; p+0x2a7c6 = 0xFFFF
            L.vt[0x20](p, lockindex, 0)    # Apply_N_Free with the corruption check; the ItemUse releaser runs uib_Effect (Z04 §6.3)
    else:
        so_ply_ItemUseResultPacket(p, lockindex, 9)   # 0x3016 with error = the LOCK INDEX, not the DB code (original bug) Z05-B6
            # client: ErrMsgTable(lockindex) → usually "An unidentified error code has occurred." (+ the number);
            # a lock index that happens to equal a handled code (0x700 = success, 0x714 "inventory full" …) shows that instead
        L.Free(lockindex)
```

`so_ply_ItemUseResultPacket` FUN_0045e610 (vt 0x91c) always sends `{error, useditem = p+0x2a7c6, 9}` and resets `p+0x2a7c6`.
The effect (heal, buff, teleport, megaphone…) happens only after this answer, inside the releaser.

### 6.2 Chests (present boxes): `0x346E` → `0x3450` → `0x3451` / `0x3452`

```pseudo
0x346E NC_ITEMDB_CHESTITEM_ACK { ref, u64 chest, u16 location, u16 error, PROTO_ITEM_CMD item (u8 count, items…) }
                                                            @ FUN_00598db0 → so_ply_ChestBoxOpenAck FUN_00598e90 (vt 0x920)
    (2016 handler string: gds_NC_ITEMDB_CHESTITEM_REQ; no IsClosing check)
    error 0x9b6 / 0x9b7:  p ← 0x3016 { 0x716 }
    chest flag invalid:   log "sp_uie_ItemChest_Direct : Invalid Chest flag"
    (the chest use sent 0x346D NC_ITEMDB_CHESTITEM_REQ { ref, u64 chest, u16 location } from FUN_00598c90)
    else: build 0x3450 NC_ITEMDB_GETFROMCHEST_REQ { ref, u32 owner, u16 lockindex, u64 chest, u8 relocnum,
                                                    PROTO_ITEM_RELOC reloc[relocnum] = { u64 item key, u16 new inventory cell } }:
        for each item: find room (StoreItem reservation, L.vt[0x40]); no room → client text "PresentBoxInvenFull",
            p ← 0x3016 { 0x714 }, L.Free(current lock), stop
        reserve the chest cell's removal (L.vt[0x30]); send to GameDB; lock += 1
    p ← 0x3016 { result }
0x3451 GETFROMCHESTSUC_ACK { ref, u16 lockindex }           @ FUN_00596c00
    L.Apply_N_Free(lockindex, ctx 1); p ← 0x3016 { 0x700 }
0x3452 GETFROMCHESTFAIL_ACK { ref, u16 lockindex, u16 err } @ FUN_00596d30
    L.Free(lockindex); p ← 0x3016 { 0x700 }       # reports success although nothing was given (original bug) Z05-B7
```

### 6.3 Capsules: `0x34A3` → `0x34A4` → `0x34A5`

```pseudo
0x34A3 NC_ITEMDB_CAPSULEITEM_ACK { ref, u16 nError, u64 nItemReg, u16 nLocation, … }
                                                            @ FUN_0059acc0 → so_ply_ChestBoxOpenAck FUN_0059ada0 (vt 0xb48)
    nError 0x2845 / 0x2846: p ← 0x3016 { 0x702 }
    the cell at nLocation must still hold key nItemReg, else 0x3016 { 0x702 }
    (the capsule use sent 0x34A2 NC_ITEMDB_CAPSULEITEM_REQ { ref, u64 nItemReg, u16 nLocation } from FUN_0059aba0)
    as §6.2: reservations, 0x34A4 NC_ITEMDB_GETFROMCAPSULE_REQ { ref, u32 nOwner, u16 nLockIndex, u64 capsule key,
        PROTO_ITEM_RELOC nReloc } (30 bytes, one item), "PresentBoxInvenFull"/0x714, "Invalid cell"/0x716
0x34A5 NC_ITEMDB_GETFROMCAPSULE_ACK { ref, u16 nLockIndex, u16 nError }    @ FUN_0059b150
    nError == 0x2840: Apply(ctx 1); p ← 0x3016 { 0x700 }      else: Free; p ← 0x3016 { 0x702 } ("You cannot use this")
```

### 6.4 Breaking and destroying: `0x346B`, `0x346C`, `0x345A`

```pseudo
0x346B ITEMBREAKSUC_ACK { ref, u16 lockindex }              @ FUN_0048d720 → so_ply_ItemBreakSuccess FUN_0048d480 (vt 0x908)
    Apply (cell cleared); p ← 0x3024 NC_ITEM_BREAKSUCCESS_CMD {}            (client: no handler in 2016)
0x346C ITEMBREAKFAIL_ACK { ref, u16 lockindex, u16 ErrorCode }   @ FUN_0048d800 → so_ply_ItemBreakFail FUN_0048d640 (vt 0x90c)
    Free; p ← 0x3025 NC_ITEM_BREAKFAIL_CMD { 0x1829 }; p ← 0x3025 { ErrorCode }      # two packets
0x345A NC_ITEMDB_DESTROY_ACK { ref, u16 lockindex, u16 err }      @ FUN_005287b0
    err == 0xb81: Apply  else Free
    then the auto-pick check of §5.1 (UNEQUIPSUC)              # destroying the auto-pick item turns auto-pick off
```

`0x3459 DESTROY_REQ` has 7 senders (ItemBreaker, `&ClearInventory` FUN_0041bbd0, expiry, quest item removal …). No client ACK;
the client sees the `0x3001` cell changes.

### 6.5 Quest reward: `0x345C`

```pseudo
0x345C NC_ITEMDB_QUESTREWARD_ACK { ref, u16 lockindex, u16 nQuestID, u16 err }    @ FUN_00527ff0
    (2016 profiler string "gds_NC_ITEMDB_DESTROY_ACK", copy-paste)
    q = p.vt[0xd38]() (CQuestZone); CQuestZone_Recv_NC_ITEMDB_QUESTREWARD_ACK(q, pkt)        @ FUN_005bf7f0
        err == 0xbc1:
            L.Apply_N_Free(lockindex)                     # QuestReward releaser: items, money, exp, fame
            d = QuestDiary_Find(q, nQuestID); if d: FUN_0062f610(q, copy of d) (quest state update, inferred);
                q+0x900 = 1; CQuestZone_Send_NC_QUEST_DB_SET_INFO_REQ(q, d, q+0x8fc); CQuestZone_QuestNext(q)     (Z08)
        else:
            L.Free(lockindex); CQuestZone_Send_QUEST_ERROR_TO_CLIENT(q, 0xc0e); player.vt[0xae4](0)
```

### 6.6 Card opening (collection cards): `0x34A9` → `0x34AA` → `0x34AB`

`UseEffect::UseItemCardOpen::uib_DirectUse` (FUN_00627740) asks the DB for the card item's details: `0x34A8 NC_ITEMDB_ITEMINFO_REQ
{ u32 clientregnum, u16 clientzonehandle, u64 ItemKey, u16 FailProtocol = 0xC407 }`.

```pseudo
0x34A9 NC_ITEMDB_ITEMINFO_ACK { u32 clientregnum, u16 clientzonehandle, u16 err, u16 FailProtocol, … }    @ FUN_00528500
    p = som_GetObject(clientzonehandle); charNo check only
    if err == 0x2b00:
        if FailProtocol == 0xC407: so_ply_CollectCardOpen(p, pkt)          @ FUN_006281b0 (vt 0xc08)
            item key must still match the used card cell, card row (table DAT_14d713a8[cardID]) must exist
            mismatch: p ← 0xC407 NC_COLLECT_CARDOPEN_CMD { err 0x2b82 }; p ← 0x3016 { 0x706 }
            ok: reserve the rebuilt card, → DB 0x34AA NC_ITEMDB_ITEMREBUILD_REQ { u32 clientregnum, u16 clientzonehandle, u16 lockindex,
                u64 EraseItemKey (the sealed card), PROTO_ITEM_CREATE CreateItem { u32 owner, MAPPOS map, u16 location, u64 key, u16 id,
                u16 attr }, attribute bytes };
                p ← 0x3016 { 0x700 }
        (other FailProtocol with 0x2b00: nothing)
    elif FailProtocol == 0xC407:
        p ← 0xC407 { u16 err } with packet length 0x6C   # 104 payload bytes of stale g_buf after err (original bug) Z05-B8
    else:
        so_SendErrorCode(p, FailProtocol >> 10, FailProtocol & 0x3ff, err)   # the request names the opcode to answer with
0x34AB NC_ITEMDB_ITEMREBUILD_ACK { u32 clientregnum, u16 clientzonehandle, u16 lockindex, u16 err }    @ FUN_00528400
    err == 0x2b40: Apply (CardOpen releaser → 0xC407 card data to the client)  else Free     # no IsClosing check
```

## 7. Storage

### 7.1 Account storage: `0x3446`, `0x3445`, `0x3460`, `0x3462`

```pseudo
0x3446 NC_ITEMDB_OPENSTORAGE_ACK { ref, u8 curpage, u8 nOpenType, u64 cen, u8 itemcounter, PROTO_ITEMPACKET_TOTAL items[] }
                                                            @ FUN_0044c460 → so_accountstoragefill FUN_0044c530 (vt 0x6a4)
    (IsClosing check only)
    store the items into the storage box p+0x18258 (FUN_00643a00, 6 pages); storage money p+0x18250 = cen
    p ← 0x3C08 NC_MENU_OPENSTORAGE_CMD { u64 cen, u8 0x10, u8 curpage, u8 nOpenType, u8 count, items of page curpage
                                         (slots curpage*36 … +35, FUN_00643b10) }
    count ≠ itemcounter: log "so_StoreInventoryFromServer : ItemNumber not match"
    if storage flag 0x20 (p+0x5cb8) not set: nOpenType 0 → set 0x10 ("storage open"); 1 → set 0x20 and log "AccountStorage Flag Error"
0x3445 NC_ITEMDB_OPENSTORAGE_FAIL_ACK { ref, u16 err }      @ FUN_00468980
    p ← 0x3C07 NC_MENU_OPENSTORAGE_FAIL_CMD { err } ("An error has occurred while using the Storage."); p+0x5cb8 &= ~0x20

0x3460 NC_ITEMDB_DEPOSIT_ACK  { ref, u16 lockindex, u64 cen, u16 err }    @ FUN_00534010 → so_ply_DepositAck FUN_005340f0 (vt 0x454)
0x3462 NC_ITEMDB_WITHDRAW_ACK { ref, u16 lockindex, u64 cen, u16 err }    @ FUN_00534500 → so_ply_WithdrawAck FUN_005345e0 (vt 0x458)
    (0x3462's 2016 profiler string is "…DEPOSIT_ACK", copy-paste)
    err == 0xf80: Apply (player money); storage money p+0x18250 = cen (the DB's new storage balance)   else Free
    p ← 0x301D NC_ITEM_DEPOSIT_ACK / 0x301F NC_ITEM_WITHDRAW_ACK { u64 storage cen = p+0x18250, u16 err }
```

The 12-byte `0x301D`/`0x301F` success ACKs answer Z04-B8 (Z04's 2-byte error replies are the request-side ones).

### 7.2 Guild storage: `0x3473`, `0x3472`, `0x3475`

```pseudo
0x3473 NC_ITEMDB_OPEN_GUILD_STORAGE_ACK { ref, u64 cen, u64 nToken, u8 itemcounter, items[] }     @ FUN_00475b20
    → so_ply_GuildStoreFill FUN_00477570 (vt 0x5e8):
        s = g_GuildStorage.find(guildNo); none: take a free storage object (DAT_0d426084), bind it to the guild (s+0x1068)
        none available: sp_GuildStorageError(p, 0x1241)
        FUN_00474a80(s, pkt, p): fill the shared storage and show it (Z04 §7.4; Z14 owns the zone-ring side)
0x3472 OPEN_GUILD_STORAGE_FAIL_ACK: EmptyHandler FUN_00509900 — no reply to the client (original bug) Z05-B9

0x3475 NC_ITEMDB_GUILD_STORAGE_WITHDRAW_ACK { ref, u16 lockindex, u64 cen, u16 err }
                                                            @ FUN_005347a0 → so_ply_GuildStorageWithdrawAck FUN_00537640 (vt 0x45c)
    s = guild storage of p
    err == 0x1480 and s:
        Apply; new = s.money − cen; s.money = cen (FUN_004749c0)          # the DB's value wins
        p ← 0x3027 NC_ITEM_GUILD_STORAGE_WITHDRAW_ACK { u64 cen, u16 err }
        → other zones 0x7493 NC_GUILD_STORAGEWITHDRAW_RNG { u8 zone, u16 handle, u32 charNo, u32 guildNo, u8 2, u8 0, char name[20],
                                                          u16 0xFFFF, u64 delta } (ZoneConnectSession_zcs_Send, 0x2e bytes)
        GuildStorageManager_gsm_SendWithdraw2Member: tell the guild members on this zone
    else:
        Free; packet byte 0x10 of the *received* packet = 0x1485, then p ← 0x3027 with g_buf bytes 2..11 never written
        # cen and the error code are stale buffer content (original bug) Z05-B10
```

### 7.3 Guild-academy reward storage: `0x3484`, `0x3483`, `0x3486`, `0x3488`

```pseudo
0x3484 GUILD_ACADEMY_REWARD_STORAGE_OPEN_ACK { ref, u64 cen, u8 nOpenType, u8 itemcounter, items[] }   @ FUN_0046ded0
    → so_ply_GuildAcademyRewardStoreFill FUN_0046ff90 (vt 0x86c): storage owner = guild (member) or academy guild (vt 0x55a540/0x55a520);
      find or allocate the shared storage (DAT_0d026fe4), else FUN_00470d50(p, 0x17d9); fill (FUN_004708b0);
      nOpenType < 3: p+0x17d06[nOpenType] = 1  else log "nOpenType Error"
0x3483 …OPEN_FAIL_ACK: EmptyHandler FUN_00509900 (Z05-B9)
0x3486 …WITHDRAW_ACK / 0x3488 …DEPOSIT_ACK { ref, u16 lockindex, u64 cen, u16 Error }
                         @ FUN_0046f1c0 → FUN_0046f970 (vt 0x848) / FUN_0046f2a0 → FUN_0046fc80 (vt 0x84c)
    success 0x17e0 (withdraw) / 0x19a0 (deposit) and storage found:
        Apply; storage money −/+ cen; p ← 0x3030 / 0x3032 { u64 new storage money, u16 Error }
        → zones 0x9872 / 0x9874 NC_GUILD_ACADEMY_REWARD_STORAGE_WITHDRAW_RNG / DEPOSIT_RNG (0x37 bytes) and the members
    else: Free; the received packet's error is overwritten with 0x17e8 and 0x3030/0x3032 goes out with stale g_buf bytes (Z05-B10)
```

Here `cen` is the amount moved, while in §7.2 it is the new balance. `0x3032` has no client handler in 2016.

### 7.4 Premium ("charged") inventory: `0x3464`, `0x3466`

```pseudo
0x3464 NC_ITEMDB_CHARGED_LIST_ACK { ref, u16 ErrorCode, u8 nPartMark, u16 NumOfChargedItem, PROTO_CHARGED_ITEM_INFO[16 B] }
                                                            @ FUN_00492570 → so_ply_FillChargedInven FUN_00492f30 (vt 0x7a4)
    p ← 0x3021 NC_ITEM_CHARGEDINVENOPEN_ACK { u16 ErrorCode, u8 nPartMark, u16 count, items[count] }
    if ErrorCode == 0x1041:
        nPartMark bit 0: clear the zone's copy (p+0x2a5d4) first        # first part of a multi-packet list
        copy each item into the copy (FUN_006323b0); full → set nPartMark bit 1 and stop
        p+0x2a5d0 = 1 (list loaded)
    else count = 0
0x3466 NC_ITEMDB_CHARGED_WITHDRAW_ACK { ref, u16 lockindex, PROTO_CHARGED_ITEM_INFO, u16 ErrorCode }
                                                            @ FUN_00492ca0 → so_ply_ChargedWithdraw FUN_00492d90 (vt 0x7a8)
    p ← 0x3023 NC_ITEM_CHARGED_WITHDRAW_ACK { u32 ItemOrderNo = p+0x2a758, u16 ErrorCode }; p+0x2a758 = −1
    ErrorCode == 0x1041: Apply  else Free
```

## 8. Upgrades, enchanting and item services

### 8.1 Upgrade: `0x3448`, `0x34D2`, `0x34D4`

```pseudo
0x3448 NC_ITEMDB_UPGRADE_ACK { ref, u16 lockindex, u16 err }          @ FUN_0053b900
0x34D2 NC_ITEMDB_NEW_UPGRADE_ACK { ref, u16 lockindex, u16 err }      @ FUN_0053bd20
0x34D4 NC_ITEMDB_BRACELET_UPGRADE_ACK { ref, u16 lockindex, u16 err } @ FUN_0053c0f0
    skeleton (+ vt 0xbbc)
    codes (UPGRADE / NEW / BRACELET):
        refused, Free:    0x8c2, 0x8c8–0x8cc  /  0x3802, 0x3806–0x3809  /  0x3c01, 0x3c02, 0x3c04–0x3c06
        done, Apply:      0x8c3–0x8c7          /  0x3803–0x3805          /  0x3c07–0x3c0b
            first → GameLog 0x0452 NC_LOG_GAME_ITEM_UPGRADE { u32 charNo, char map[12], u32 x, u32 y, u64 key, u8 old level,
                    u8 new level, u16 itemID, u16 …, u16 …, u16 …, u8 … } (the outcome stored by the request at p+0x2928d, FUN_0053b290)
    outcome hooks (u = p+0x2928d: key, id, new level; t = p.vt[0x420]() = the character-title block p+0x29638, Z07 §1.3):
        +1 / +2 (0x8c3/0x8c4, 0x3803, 0x3c07/0x3c08):
            PetReaction(p, 2) (FUN_004d2470: only while a pet is out, p+0x2ab60 ∈ {5,6}: table DAT_1328bce8 by pet mind level
                (p+0x2ab98 / 1000) and event → adds to the pending pet mind p+0x2aba0 or stress p+0x2aba4 (Z07 §9))
            FUN_005cc050(t, key, level): title counters (FUN_005cb5f0 = title-condition update): level > 1 → successes (+0x648,
                condition 0x1b); same item as the previous upgrade and that one also succeeded → consecutive successes (+0x668, 0x1d);
                level above the best so far → best level (+0x688, 0x1f); remember key + outcome (+0xcc0/+0xcc8)
            announce FUN_005b8e50(g_Announce, name, id, level): AnnounceData row 1; if level ≥ row threshold (+0x104) and the item
                exists → CAnnounceSystem 0x6401 NC_ANNOUNCE_Z2W_CMD type 1 (world-wide message with the name and item)
            quest scenario 5
        fail  (0x8c5/0x8c6, 0x3804/0x3805, 0x3c09/0x3c0a): PetReaction(p, 3); FUN_005cc130: failures (+0x658, 0x1c), consecutive
            failures on the same item (+0x678, 0x1e); quest scenario 5
        destroyed (0x8c7, 0x3c0b; NEW_UPGRADE has no destroy code): PetReaction(p, 4); FUN_005cc1c0: destroyed (+0x698, 0x20) and
            failures (+0x658, 0x1c); quest scenario 5
    p ← 0x3018 NC_ITEM_UPGRADE_ACK / 0x306E NEW_UPGRADE_ACK / 0x3070 BRACELET_UPGRADE_ACK { err }
    MenuOpenClear(6)                                     # releases the "upgrade running" mark set by the request (Z04 §9.1)
```

`CQuestZone_QuestPlayer_ScenarioDone_Server(q, 5)` is called for every completed upgrade. Client: `ItemUpgradeWin::UpGradeResult`
FUN_0049a5d0 (0x3018), FUN_0049de10, FUN_0049de30; the code → text mapping is in §10.

### 8.2 Enchanting: `0x3497`, `0x3499`, `0x349B`, `0x349D`

```pseudo
0x3497 NC_ITEMDB_ENCHANT_ADD_GEM_ACK { ref, u16 err, u16 itemLockIndex, {u16 equipment slot, u8 socket, u16 gemID}, {u16 gem slot, …} }
                                                            @ FUN_00522fc0
    p/charNo/IsClosing fail: log "… Null Char Handle"
    err == 0x2080:
        remember the gem cell's key/id (only if the gem slot is an inventory cell, type 9)
        Apply (log "… Not Free" when nothing was applied)
        equipment item must exist and be a weapon (ItemInfo.Class == 5), socket < socket count (cell+0x43), else log only
        if equipped (type 8): add the gem's item-action id (FUN_0048c8c0)
        p ← 0x3041 NC_ITEM_ENCHANT_ADD_GEM_ACK { 0x2080, u16 equipment, u16 GemID, u8 gemSocketIndex }
        GameLog FUN_006146a0(0x7e4, charNo, map, x, y, item key/id, socket, gem key/id)
    else: Free; EnchantAddGem_Fail(p, err, "…") (Z04 §10: { err, rest of the request })
0x3499 NC_ITEMDB_ENCHANT_REMOVE_GEM_ACK { ref, u16 err, u16 itemLockIndex, u16 equipment, u16 remover slot, …, u8 remove[3] (+0x16..), u8 useRemover }
                                                            @ FUN_005233d0
    err == 0x2090: collect the gem ids of the sockets flagged in remove[0..2] (read **before** Apply), Apply,
        for each removed socket: (equipped: remove the gem's item action FUN_0048c970)
            p ← 0x3043 NC_ITEM_ENCHANT_REMOVE_GEM_ACK { 0x2090, u16 equipment, u8 socket }; GameLog 0x7e5
        # socket 1 reads the gem id at cell+0x3d (= 0x3a + 3) but socket 2 at cell+0x40 (= 0x3a + 6): consistent 3-byte stride
    else: Free; EnchantRemoveGem_Fail
0x349B NC_ITEMDB_ENCHANT_ADD_NEW_SOCKET_ACK { ref, u16 err, u16 itemLockIndex, u16 equipment, u8 socketCount, u16 drill slot, … }
                                                            @ FUN_00523820
    err == 0x20a0: Apply; p ← 0x3045 NC_ITEM_ENCHANT_ADD_NEW_SOCKET_ACK { 0x20a0, u16 equipment, u8 socketCount }; GameLog 0x7e6
    else: Free; EnchantAddSocket_Fail
0x349D NC_ITEMDB_ENCHANT_SET_GEM_LOT_ACK                    @ LAB_00519fa0
    profiler enter/exit only: the answer is ignored (the request 0x349C is sent by FUN_0059e8a0)
```

Client: `0x3041` FUN_004b2d40 "Enchant Successed", `0x3043` FUN_004b2ed0 "Enchant Stone removed", `0x3045` FUN_004b3030.

### 8.3 Mounts: `0x34AD`, `0x34AF`

```pseudo
0x34AD NC_ITEMDB_MOVER_UPGRADE_ACK { u16 nLockIndex, u32 nCharRegNum, u16 nHandleNum, u16 nError, u8 bUpgrade, u8 nSlot,
                                     u16 nItemID, SHINE_ITEM_ATTRIBUTE ItemAttr (101 B) }      @ FUN_00468c60
0x34AF NC_ITEMDB_MOVER_RAREMOVER_ACK { u16 nLockIndex, u32 nCharRegNum, u16 nHandleNum, u16 nError, u8 nSlot,
                                       u16 nItemID, SHINE_ITEM_ATTRIBUTE ItemAttr }           @ FUN_00468e30
    p = som_GetObject(nHandleNum), vt 0xbbc, charNo check
    success (nError 0x3230 / 0x3238): Apply; code 0x3228  else Free; code 0x322c
    p ← 0x3052 NC_ITEM_MOVER_UPGRADE_ACK { u16 code, u8 bRare (0 / 1), u8 bUpgrade (RAREMOVER: 0), u8 nSlot, u16 nItemID, ItemAttr }
    p+0x5cba bit 0 = 0 (FUN_00561610; mover upgrade in flight, inferred)
```

The `0x3052` layout matches `PROTO_NC_ITEM_MOVER_UPGRADE_ACK` (0x6C bytes). Client FUN_0049d720.

### 8.4 Random options: `0x34B4`, `0x34C2`, `0x34CE`

```pseudo
0x34B4 NC_ITEMDB_RANDOMOPTION_CHANGE_ACK { u16 nLockIndex, u32 nCharRegNum, u16 nHandleNum, u16 nError }    @ FUN_00469190
    nError == 0x3248: Apply  else Free
    p ← 0x3062 NC_ITEM_RANDOMOPTION_CHANGE_ACCEPT_ACK { nError }     (this answers the ACCEPT request 0x34B3, Z04 §11.2)
0x34C2 RANDOMOPTION_CHANGE_CONSUME_AND_COUNTING_ACK { u16 nLockIndex, u32 nCharRegNum, u16 nHandleNum, u16 nError,
                                                      u64 nItemKey, u16 nItemID, u8 nItemSlotNo }           @ FUN_00469320
    → so_ply_RandOptChangeProcessConsumeAndCountingAckPacket FUN_0051d700:
        nError ≠ 0x3248: Free; p ← 0x3054 NC_ITEM_RANDOMOPTION_CHANGE_ACK { nError }
        else Apply; p ← 0x3054 { 0x324a, … }: the target cell must still hold nItemKey/nItemID ("Try to use invalid item" otherwise);
             roll new options into p+0x2a961 (attribute vt 0x70) and send them for the client to accept or refuse
0x34CE RANDOMOPTION_RECOVER_COUNT_LIMIT_ACK { u16 nLockIndex, u32 nCharRegNum, u16 nHandleNum, u16 nError }  @ FUN_00469400
    nError == 0x3251: Apply  else Free;  p ← 0x306C { nError }
```

The new options are rolled on the zone *after* the consume answer; they are written to the DB only by the later ACCEPT (0x34B3).

### 8.5 Other item services

```pseudo
0x34B6 NC_ITEMDB_CHAT_COLOR_CHANGE_ACK { u16 nError, u16 nLockIndex, u32 nCharRegNum, u64 nItemKey, u16 nItemID,
                                         u32 eChatColorItemType, u8 nChangeColor }        @ FUN_00469710
    (its own layout: no ref; p = som_FindPlayer(nCharRegNum))
    nError == 0x3600: Apply; so_ply_ChatColorInfoApply(p, pkt) (FUN_00563ac0, vt 0xe3c: charged buff of the item (usage class 0x24),
                      booth size resend, colour by item type (0 / 1 / other: log "invalid chatcoloritemtype"))
    else Free
    p ← 0x3056 NC_ITEM_CHAT_COLOR_CHANGE_ACK { nError, u8 nChangeColor }
0x34B8 NC_ITEMDB_TERMEXTEND_ACK { u16 nLockIndex, u32 nCharRegNum, u16 nHandleNum, u16 nError }    @ FUN_0051f440 (no IsClosing)
    nError == 0x3618: Apply  else Free;  p ← 0x3058 NC_ITEM_TERMEXTEND_ACK { nError }
0x34BE NC_ITEMDB_CLASS_CHANGE_ACK { u32 nCharRegNum, u16 nHandleNum, u16 lockindex, u16 nError }   @ FUN_00469590
    nError == 0x3680: Apply; p+0x2a800 = 1; p+0x2a798 = g_Now; schedule logout in 30 s (FUN_00562100: ts_Set(sp_Schedule_Logout),
                      "ts_Set" fails if the scheduler slot is busy)      # the class change takes effect at the next login
    else Free
    p ← 0x305F NC_ITEM_CLASS_CHANGE_ACK { nError }
0x34CA NC_ITEMDB_MAPLINK_ITEM_CONSUME_ACK { u16 nLockIndex, u32 nCharRegNum, u16 nHandleNum, Name3 mapName, u16 skillID,
                                            u32 skillCoolTime, u16 nError }       @ FUN_004698a0 (p = som_FindPlayer(charNo))
    nError == 0x3748:
        start the scroll's cooldown: vt FUN_0055b6a0(skillID, coolTime), so_ply_NewSkillCoolTime(skillID, coolTime / 1000)
        p ← 0x3068 NC_ITEM_MAPLINK_SCROLL_ACK { nError, 0, 0 }; Apply
        target = mapName → map row (g_MapData); link to it at the row's default position (+0x32/+0x36): so_LinkTo(…, 6, 9, 10)
    else: Free; p ← 0x3068 { nError, 0, 0 }
0x34CC NC_ITEMDB_MIX_ITEM_ACK { u32 nCharRegNum, u16 nHandleNum, u16 nLockIndex, u16 nError }   @ FUN_00469b70 (som_FindPlayer)
    nError == 0x37c0: Apply  else Free + log;  p ← 0x306A NC_ITEM_MIX_ITEM_ACK { nError }
```

### 8.6 Dismantle: `0x3477`

```pseudo
0x3477 NC_ITEMDB_DISMANTLE_ACK { ref, u16 lockindex, u16 err }   @ FUN_005298f0
    err == 0x1680: Apply (item removed, Karis/material created)  else Free
    p ← 0x302B NC_ITEM_DISMANTLE_ACK { err }            # client 0x1680-family: "Item has been dismantled. Karis has been created."
```

### 8.7 Endurance charges: `0x348E`, `0x34C7`

```pseudo
0x348E NC_ITEMDB_WEAPONENDURE_CHARGE_ACK { ref, u16 lockindex, u64 WeaponKey, u16 WeaponSlot, u32 ChargedNumber, u16 Error }
        @ FUN_0051a120 → so_ply_WeaponEndureChangeAck FUN_0051a260 (vt 0x9f4)
0x34C7 NC_ITEMDB_SHIELDENDURE_CHARGE_ACK (same layout)  @ FUN_0051a730 → so_ply_ShieldEndureChangeAck FUN_0051a870 (vt 0x9f8)
    (charNo + IsClosing checks)
    Error == 0x1a80:
        Apply(lockindex)                                    # charge item consumed
        cell = WeaponSlot (type 8 equipment or 9 inventory; other: log "Invalid location", no reply)
        cell key ≠ WeaponKey: log "weaponkey wrong", no reply
        cell.attr.vt[0xa0](cell, ChargedNumber)             # set the charge counter
        p ← 0x3036 NC_ITEM_WEAPONENDURE_CHARGE_ACK (0x3065 for shields) { u32 ChargedNumber, u16 WeaponSlot, u16 0x1a80 }
            sent with packet length 0x1A: 16 bytes of stale g_buf after the 8-byte struct (original bug) Z05-B11
    else:
        Free; p ← 0x3036 { Error } at payload +6 with length 10: ChargedNumber and slot are stale bytes
```

The base-class methods `ShineObject_so_ply_Weapon/ShieldEndureChangeAck` (FUN_0051a210 / FUN_0051a820) are empty; the player
overrides above do the work. Client: ItemRepairTask FUN_0066cb20 / FUN_0066cc80.

## 9. Miscellaneous answers

### 9.1 GM item creation: `0x3402` / `0x3403`

```pseudo
0x3402 ADMINCREATESUC_ACK { ref, u16 lockindex }             @ FUN_00527660:  Apply (log on failure)
0x3403 ADMINCREATEFAIL_ACK { ref, u16 lockindex, u32 owner } @ FUN_00527770:  so_NC_ITEMDB_ADMINCREATEFAIL_ACK (vt 0x34c,
                                                                               FUN_005275b0: only calls GetCharNo); Free
```

### 9.2 Item list creation: `0x344E` / `0x344F`

```pseudo
0x344E CREATEITEMLISTSUC_ACK { ref, u16 lockindex }    @ FUN_0052e360:  Apply; FUN_00523b10(p, 1)
0x344F CREATEITEMLISTFAIL_ACK { ref, u16 lockindex, … }  @ FUN_0052e480:  Free
```

`0x344D CREATEITEMLIST_REQ` is sent by script/event item grants (FUN_005e17e0, FUN_005e1b30, FUN_00625340). No client ACK.

### 9.3 `0x344C` NC_ITEMDB_ITEMTOTALINFORM_ACK @ FUN_00494eb0

`{ u64 itemregnum }`: if the key is −1 log; else `ItemsInChest_iic_SearchItem` (FUN_00494e20) — a stub returning 0xFFFF — so it
always logs. Nothing else happens.

### 9.4 Production: `0x3458` (answers Z07 §11)

```pseudo
0x3458 NC_ITEMDB_PRODUCE_ACK { ref, u16 lockindex, u16 product, u16 err }     @ FUN_0046c610
    skeleton
    err == 0x0B01:
        Apply                                           # materials removed, product added → 0x3001 to the producer
        broadcast to all players in range: 0x203C NC_ACT_SOMEONEPRODUCE_MAKE_CMD { u16 producer handle, u16 product }
    else Free
    p ← 0x203B NC_ACT_PRODUCE_MAKE_CMD { u16 product, u16 err }
```

The 2016 client has no handler for `0x203B` or `0x203C`: it learns the result from the `0x3001` cell changes and from
`0x481D NC_SKILL_SKILLEXP_CLIENT_CMD` (mastery), which the zone sends when the cast ends (Z07 §11).

### 9.5 Mushroom (mini-house creation): `0x3468` / `0x3469`

```pseudo
0x3468 CREATEMUSHROOMSUC_ACK { ref, u16 lockindex }     @ FUN_0043ee30 → so_ply_MakeMiniHouse FUN_0043f010 (vt 0x3dc)
    Apply (the mini-house item is created); if the mini-house box slot 0 (p+0xe778) now holds an item:
        MiniHouseStr_mhs_Init(p+0x292ac, p, cell)       # activate the new mini-house (Z07 §6)
0x3469 CREATEMUSHROOMFAIL_ACK { ref, u16 lockindex, u32 owner }    @ FUN_0043ef10:  vt 0x34c (no-op); Free
```

### 9.6 Mini-house furniture effect: `0x347E` (answers Z07 §6.10)

```pseudo
0x347E NC_ITEMDB_MINIHOUSE_EFFECT_DEMANDGOOD_ACK { ref, u16 lockindex, u16 nEffectHandle, u16 err }   @ FUN_0056f360
    p missing / charNo / closing: log "cannot find player [h]. ignore 'minihouse effect' command"
    if err == 0x1700:
        Apply (NeedItem consumed, NeedMoney paid); so_MH_EffectApply(p, nEffectHandle)         @ FUN_005751f0 (vt 0x15c)
            (in the house, effect row found: play it for everyone in the house; reply 0x8C41 { nEffectHandle, 0x16C0 })
    else:
        p ← 0x8C41 NC_MINIHOUSE_FURNITURE_EFFECT_ACK { nEffectHandle, code } with code by err:
            0x1702 → 0x16D1, 0x1703 → 0x16D2, 0x1704 → 0x16D3, 0x1705 → 0x16D4, 0x1706 → 0x16D5, other → 0x16D0
        Free
```

**Portal effects:** the request `0x3489 NC_ITEMDB_MINIHOUSE_PORTAL_EFFECT_DEMANDGOOD_REQ` has no handler in the 2016 Character
server and the zone registers no `0x348A` handler: a paid portal effect keeps its item/money reservation locked until relog and the
client never gets `0x8C57` (original bug) Z05-B12. Free portal effects apply directly (Z07 §6.10).

### 9.7 Furniture endurance: `0x348C`

```pseudo
0x348C NC_ITEMDB_FURNITURE_ENDURE_ACK { ref, u16 lockindex, u16 nFurnitureHnd, u64 nItemKey, u32 dNewEndureTime, u16 Error }
                                                            @ FUN_00570dc0
    Error == 0x700:
        Apply (repair kit consumed)
        r = so_ply_MH_FurnitureEndureUpdate(p, pkt)        @ FUN_00570fe0 (vt 0x140)
            not in a mini-house 0x1a76; furniture handle unknown 0x1a75; other failure 0x1a73
            ok: furniture endure date = dNewEndureTime; p ← 0x3034 { dNewEndureTime, 0x1a70 };
                house ← 0x8C61 NC_MINIHOUSE_FURNITURE_ENDURE_CMD { nFurnitureHnd, … }; return 0x1a70
        if r ≠ 0x1a70: p ← 0x3034 NC_ITEM_MH_FURNITURE_ENDURE_KIT_USE_ACK { dEndEndureDate = stale g_buf, Error = r }
    else: p ← 0x3034 { stale, Error }; Free
```

Error replies write `Error` at payload +4 and leave `dEndEndureDate` stale (cosmetic; the client shows "Repair has been completed."
only on success).

### 9.8 Mystery vault: `0x349F`

```pseudo
0x349F NC_ITEMDB_MYSTERY_VAULT_MAKEITEM_ACK { ref, u16 itemLockIndex, u16 err }   @ FUN_00519ff0
    p missing/charNo/closing: log "gds_NC_ITEMDB_ENCHANT_ADD_NEW_SOCKET_ACK Null Char Handle" (copy-paste string)
    err == 0x2140: Apply (log "gds_NC_ITEMDB_ENCHANT_ADD_GEM_ACK Not Free" when nothing applied)   else Free
    # no client packet
```

The request comes from opening a "mystery bolt" box: `UseEffect::UseItemMysteryBolt::uib_DirectUse` (FUN_005997c0) →
`sp_MysteryVaultMakeItem` (FUN_005658f0, name from its log strings):

```pseudo
sp_MysteryVaultMakeItem(p, boxCell, &code):                    @ FUN_005658f0
    code = 0x700; no cell: 0x702
    rows = MysteryVaultServer.shn rows of the box item id; none: log "MysteryBoltTable::ItemBoxOpen Not Register ItemId", 0x724
    for each row (+0x47 group, +0x45 rate ‰, +0x20 class mask, +0x24 item InxName, +0x44 lot):
        group 0: independent roll r = Random(1000), hit if r ≤ rate
        group ≠ 0: one roll per group, rates add up along the group until one hits (one item per group)
        hit and the player's class passes (MysteryVaultTable::IsCheckClassType FUN_005c82e0): add (item id, lot) to the result list
    empty result: 0x724
    free inventory cells (FUN_00560910) < result count: 0x725
    inventory not lockable: 0x723
    → DB 0x349E NC_ITEMDB_MYSTERY_VAULT_MAKEITEM_REQ { ref, u16 lockindex, u64 box key, u16 box id, u8 count,
          count × PROTO_ITEM_CREATE { owner = charNo, map name + x/y, location = inventory cell, key = ItemKey_Make(id, kind 2, zone, world),
          id, attr offset }, then each item's attribute bytes (random options rolled from RandomOption by the item's +0x89 group) }
        reservations: the box cell (L.vt[0x34]) and one StoreItem (L.vt[0x40]) per created item; unknown created id: Free, 0x701
    # code goes to the client as 0x3016 USE_ACK (0x723 "Inventory full"; 0x724/0x725 have empty texts)
```

### 9.9 Friend points: `0x34C0` (answers Z08 knowledge)

```pseudo
0x34C0 NC_ITEMDB_UES_FRIEND_POINT_ACK { ref, u16 error, u16 itemID, u16 friendpoint, u16 lockindex, u8 numofitem }   @ FUN_00469d00
    p = som_FindPlayer(ref.charNo); not closing; charNo check
    error == 0x36C0:
        Apply(lockindex)
        id = named value "FriendBroadcastItemID" (FUN_0062efc0, cached in DAT_0d026c24)
        if itemID == id: → WM 0x5423 NC_FRIEND_SOMEONE_GET_SPECIALITEM_ZONE_CMD { char name[20] }     # the WM tells the friends
    else Free
    p ← 0x5422 NC_FRIEND_UES_FRIEND_POINT_ACK { u16 error, u16 friendpoint, u16 itemID, u8 numofitem }
```

The DB checks and deducts the points (Z08 knowledge). Client `0x5422` FUN_004ae070: "You have received (%s) %d with your friend
points." / "You do not have enough Friend Points." / …

### 9.10 Trade: `0x343C` / `0x343D` (Z06 owns the trade window)

```pseudo
0x343D NC_ITEMDB_ITEMTRADESUC_ACK { ref, u16 lockindex }          @ FUN_00593ed0 (charNo check only)
    Apply (both sides' items/money were reserved under this player's lock); so_CloseTradeMenu(p)
0x343C NC_ITEMDB_ITEMTRADEFAIL_ACK { ref, u16 lockindex, u16 err }  @ FUN_00593dd0
    Free; so_CloseTradeMenu(p); p ← 0x4C23 NC_TRADE_TRADEFAIL_CMD { err } ("Trade has been failed.")
so_CloseTradeMenu(p):  L.Free(trade lock = p.vt[…]()+0x10); FUN_00559eb0 (clear trade state); MenuOpenClear(2)   @ FUN_005924c0
```

The request `0x343B` is sent once per trade (FUN_00594870) and carries both partners' refs and lock indexes; the Character server
(FUN_0040ca80) answers each partner with its own `0x343D` (or `0x343C { ref, lock, err }`), so each zone applies its own lock.

### 9.11 Booth trade: `0x3456`

```pseudo
0x3456 NC_ITEMDB_BOOTHTRADE_ACK { ref seller, ref buyer, u16 boothlockindexSeller, u16 boothlockindexBuyer,
                                  u32 nBoothTradeType, u64 nItemKey, u16 nLotTraded, u16 err }          @ FUN_005914a0
    seller = som_GetObject(seller handle); buyer = som_GetObject(buyer handle)
    err == 0x0A41:
        for each side present, charNo matching, not closing: Apply(its lock)
        nBoothTradeType ∈ {4 SELL_ALL, 5 SELL_MERGE, 6 SELL_SPLITCREATE} (BOOTH_TRADE_TYPE, pdb2017):
            booth manager of the seller's map (map+0x1f0):
              4: BoothManager_RemoveItem(seller handle, nItemKey) (FUN_0043ad30)
              5, 6: FUN_0043ae40 (reduce or remove the booth entry by nLotTraded, inferred)
            failures only log
    else:
        Free both locks; buyer ← 0x680E NC_BOOTH_ITEMTRADE_ACK { err }
```

Neither side gets a success packet here; the booth window updates come from the cell changes and the booth code (Z06).

## 10. Client handling of the answers (2016 client)

What the 2016 client does with the result codes the answers above produce. Texts are from `TextData*.shn`; "ErrMsgTable" = the
generic table `FUN_00416430` (`docs/protocol/client-error-codes.json`), whose fallback is "An unidentified error code has occurred."
plus the number. "silent" = no message.

| Packet (client handler) | Success | Other codes |
|---|---|---|
| `0x3004` BUY_ACK (FUN_004ab770) | `0x201` "Item has been purchased." | `0x205/0x207/0x20b` "Not enough money to buy the item.", `0x20a` "Inventory is full.", `0x20c` fame, `0x20d` "already in possession", `0x20f` coins, `0x211` purchase level; others silent (so DB errors from §2.1/§2.4/§2.5 are silent unless the DB uses these codes) |
| `0x3005` SELL_ACK (FUN_004ab870) | `0x381` (sound) | `0x38f`/`0x390` ErrMsgTable; others "Failed to sell the item." |
| `0x3008` DROP_ACK (FUN_004ab990) | `0x301` | `0x30d` "You cannot drop a bound item.", `0x30e` "You cannot throw away items in that area.", `0x387`/`0x38b` "You do not have the right to pick up the item.", `0x13c1` "Cannot execute order for the menu is opened."; others silent |
| `0x300A` PICK_ACK (FUN_004aba00) | `0x341` "[%s] has been obtained." / "[%s (%d)] …" (+ quest window refresh) | `0x344` too far, `0x345` no right, `0x346` "Inventory is full.", `0x34b` removes the drop, dice codes `0x2001–0x2005`, `0x2009`, `0x34c–0x34e`; others "Failed to obtain the item." |
| `0x300C` RELOC_ACK (FUN_004ab910) | `0x241` | `0x242–0x249` silent, `0x24a` bound item, `0x24c` "You cannot put items in the Guild Tournament Storage"; others "Failed to move the item." |
| `0x300E` SPLIT_ACK (FUN_004a8360) | `0x441` | `0x447` "You can't store the premium item into storage."; others silent |
| `0x3011` EQUIP_ACK (FUN_004abd20) | `0x281` | `0x293` "You have to remove Weapon Skin."; others "The item cannot be equipped." |
| `0x3013` UNEQUIP_ACK (FUN_004abd80) | `0x2c1` (never sent, Z05-B2) | others "Failed to unequip the item." |
| `0x3016` USE_ACK (FUN_004abdb0) | `0x700` (mover/pet window updates; useditem `0x7578` "Location Save Slot of the Wing item was increased by 1.") | `0x10c2`, `0x10c7–0x10ca` mover texts, `0x714` "Your Inventory is currently full.", `0x718`, `0x719`, `0x71a–0x71c` estate texts, `0x723` "Inventory full", `0x726` "Your item has expired and cannot be used"; `0x70a/0x70e/0x70f/0x10c4` silent; others ErrMsgTable (`0x702` "You cannot use this") |
| `0x3018`/`0x306E`/`0x3070` UPGRADE (FUN_0049a5d0 → `ItemUpgradeWin::UpGradeResult` FUN_0052da90 stores the code; `EndSlotRotate` FUN_0052e950 shows it after the slot animation) | `0x8c3`/`0x3803`/`0x3c07` "Enhancement is successfully completed, item has been upgraded", `0x8c4`/`0x3c08` (the +2 text) | fail `0x8c5`/`0x3804`/`0x3c09` "Item Enhancement has been failed.", `0x8c6`/`0x3805`/`0x3c0a` "… downgraded by 1.", `0x8c7`/`0x3c0b` "… the item has been broken apart." (clears the slot); `0x8c2`/`0x3802`/`0x3c01` "Unknown error has occurred during enhancement.", `0x8c8`/`0x3806` "The item cannot be enhanced.", `0x8ca`/`0x3808`/`0x3c05` "… reached the top …", `0x8cb` "You have insufficient money.", `0x8cf–0x8d4` slot/material texts, `0x3801` "Item enhancement has to be same.", `0x3c02/0x3c04` "%s can't enhance with %s. Please use %s.", `0x3c03` "You cannot enhance equipped items."; `0x8c9`/`0x3807` text id with an empty string; others silent |
| `0x3052` MOVER_UPGRADE_ACK (FUN_0049d720) | `0x3228` (result window) | others ErrMsgTable, then the result window |
| `0x3054` RANDOMOPTION_CHANGE_ACK (FUN_004b45a0) | `0x3248` (shows the rolled options) | `0x3249–0x3250` "The stats cannot be changed right now. Please try later."; others silent |
| `0x3062` …CHANGE_ACCEPT_ACK (FUN_0049da00) | `0x3248` | silent |
| `0x306C` …RECOVER_COUNT_LIMIT_ACK (FUN_004a73d0) | `0x3251` | ErrMsgTable, result window |
| `0x3056` CHAT_COLOR_CHANGE_ACK (FUN_0049da30) | `0x3600` (sets the colour) | `0x3601–0x3607` "Error ChatColorSystem[ %d ]" (format string, no text table); others silent |
| `0x3058` TERMEXTEND_ACK (FUN_0049da90) | `0x3618` | ErrMsgTable |
| `0x305A` REPURCHASE_ACK (FUN_004b46a0) | `0x3668` silent | `0x366b` purchase level, `0x366c` money, `0x366d` inventory full; others silent |
| `0x305F` CLASS_CHANGE_ACK (FUN_004b4700) | `0x3680`: `ClassChangeWin::GoCharSelectFrameWork` (the client leaves to character select itself; the zone's 30 s logout, §8.5, is the fallback, inferred) | `0x3682` "No Changable Class specialization found.", `0x3684` "… without Respecialization Scroll", `0x3685` "… with equiped armor and weapons …"; others "Error Class Change[ %d ]" |
| `0x3068` MAPLINK_SCROLL_ACK (FUN_0049dd40) | `0x3748` (closes the world map) | `WorldMapWin::WorldMapLinkFail` FUN_005a98f0: `0x3749` "You must have a location move scroll …", `0x374a` "Cannot use due to the Level Limit.", `0x374b` "Cannot use the item yet.", `0x374c` "You cannot move to that area at the moment …", `0x374d` "You can move to %s after %d level.", `0x374e` "You cannot move to %s area.", `0x374f` "You are currently in %s area.", `0x3750` "Mana energy for location move scroll is weakened …", `0x3751` "… due to an Abnormal State.", `0x3752` "This place is restricted for location scroll use."; others silent |
| `0x306A` MIX_ITEM_ACK (FUN_0049ddb0) | `0x37c0` | ErrMsgTable (`0x37c1` "Related data cannot be found."), result window |
| `0x302B` DISMANTLE_ACK (FUN_004af8f0) | `0x1680` "Item has been dismantled. Karis has been created." | ErrMsgTable (`0x1681` "Unknown error.") |
| `0x3049` BELONGED_CANCEL_USE_ACK (FUN_004b3940) | `0x2880` "Succesfully Unbound %s" | ErrMsgTable |
| `0x3041`/`0x3045` ENCHANT (FUN_004b2d40 / FUN_004b3030) | `0x2080` "Enchant Successed" / `0x20a0` | `0x2081–0x2088` / `0x20a1–0x20a5` ErrMsgTable; others "An unknown error has occurred." |
| `0x301D`/`0x301F` DEPOSIT/WITHDRAW (FUN_004ac170 / FUN_004ac1c0) | `0xf80` (updates the storage money) | `0xf83` "Not enough money to deposit." / "… to withdaw."; others silent |
| `0x3027` GUILD_STORAGE_WITHDRAW_ACK (`GuildTask` FUN_006b4f90) | `0x1480` | `0x1481` "Withdraw Invalid at this time", `0x1482` "Storage is closed", `0x1483` "There is no money in the Storage", others "You have no authority" |
| `0x3030` ACADEMY REWARD WITHDRAW_ACK (FUN_006f54c0) | `0x17e0` | `0x17e1–0x17e8` texts (`0x17e8` "Failed to report. (DB Error)"); others silent |
| `0x3036`/`0x3065` ENDURE_CHARGE_ACK (`ItemRepairTask` FUN_0066cb20 / FUN_0066cc80) | `0x1a80` (sets the charge, completes the repair window) | `0x1a81/0x1a83/0x1a84` mode, `0x1a82` fear, `0x1a86` skin, `0x1a87` at maximum, `0x1a88` kit, `0x1a89` DB error; repair window cancelled |
| `0x3034` FURNITURE_ENDURE_KIT_USE_ACK (FUN_004af590) | `0x1a70` "Repair has been completed." | ErrMsgTable |
| `0x8C41` FURNITURE_EFFECT_ACK (FUN_00499a20) | `0x16c0` | `0x16c7/0x16c8/0x16cf` via `MiniHouseIndoor::ObjEffErrMsg`; others ErrMsgTable (so the §9.6 codes `0x16d0–0x16d5`) |
| `0x5422` UES_FRIEND_POINT_ACK (FUN_004ae070) | `0x36c0` "You have received (%s) %d with your friend points." | `0x36c1` "Cannot be used right now.", `0x36c2` "Error has occurred. Please try again.", `0x36c3` not enough points |
| `0x680E` BOOTH_ITEMTRADE_ACK (FUN_004a8620) | `0xa41` "Item has been successfully sold." | `0xa42–0xa55`, `0xa59`, `0xa5a` specific texts (`0xa4d–0xa52` are DB failures); others "Failed to sell the item." |
| `0xC407` COLLECT_CARDOPEN_CMD (FUN_004b36e0) | `0x2b80` (opens the card) | ErrMsgTable |
| `0x5003`/`0x5004` SOULSTONE_*_BUY_ACK (FUN_004a3060 / FUN_004a3110) | `{u16 total}` sets the stone count | – |

Not handled by the 2016 client: `0x203B`, `0x203C`, `0x3024`, `0x3025`, `0x3032`, `0x8C57`.

## 11. Invariants and state

- One lock index per request; the index is a 16-bit counter per player (`p+0xfaac`); answers carry it back unchanged.
- Style-1 handlers never change memory on failure; style-2 failures always disconnect (0x684). `0x68c` = lot mismatch after a
  merge/split; `0x690` = corrupted lock list.
- Answers for a player that has left or been replaced (`IsClosing`, charNo mismatch, handle reused) are dropped without freeing
  anything: the locks belonged to the old object.
- No timers: a lost answer leaves the reservation (and, for style 2, the DB-pending flag) in place until the player logs out.
- Flags cleared by answers: `p+0x173cc` equip-in-flight (EQUIP), `p+0x5cba` bit 0 mover upgrade, bit 1 item-money buy,
  `p+0x2ab18` auto-arrange running (cleared by move failures), menu bit 6 (upgrade), menu bit 2 (trade), `p+0x5cb8` bit 0x20 (storage open failed).

## Original-server bugs

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z05-B1 | `0x3412`, `0x3415`, `0x3418`, `0x341B`, `0x341E`, `0x3421`, `0x343A`, `0x3424`, `0x3427` | the u16 sent as the client's error code is `pkt.ref.objHandle` (payload +0, the player's own object handle), not the DB `error` at +6 | small: each client handler shows its generic failure text for unknown codes ("The item cannot be equipped.", "Failed to unequip the item.", "Failed to sell the item.", "Failed to obtain the item."; drop: nothing); the DB's specific code is lost, and a handle that equals a handled code shows that text instead (`0x281` = equip success → silence, `0x38f`/`0x390` sell texts, `0x344`… pick texts) | pass the `error` field, as the sibling FAIL handlers (BUY, RELOC, MERGE, SPLIT, soul stone) do |
| Z05-B2 | `0x3414` | the unequip success is sent as `0x3011` EQUIP_ACK `{0x281}` (`so_SendErrorCode(12, 0x11, …)`) | none visible: the client's EQUIP handler is silent on `0x281`; the UNEQUIP handler (success `0x2c1`) never sees a success | `0x3013 {0x2c1}` |
| Z05-B3 | §4 move/split successes | `ItemLotInspector_CheckAndReset(1)` always returns true, so the `so_Disconnect(0x68c)` after it is dead | an inspector mismatch is never acted upon (only logged inside `ili_Check`, if at all) | return the check result |
| Z05-B4 | `0x3417` | unknown item id or `so_ItemDrop` failure leaves the DB-pending flag set; the item already left the inventory | all further item requests are refused until relog; the item is gone from the zone but (presumably) not on the ground | clear the flag / disconnect as in the FAIL path |
| Z05-B5 | `0x3415`, `0x3481` | frees lock index = the `error` field (always `0x28a` from the Character server) instead of `lockindex` | the real reservation stays locked → item requests blocked until relog; a lock with index 0x28a, if any, is wrongly freed | read payload +8 |
| Z05-B6 | `0x3440` | failure sends `0x3016` with `error = lockindex` | the client gets a meaningless use error | send the DB `error` |
| Z05-B7 | `0x3452` | GETFROMCHESTFAIL replies `0x3016 {0x700}` (success) | the client believes the chest opened | send a failure code (0x702 as in §6.3) |
| Z05-B8 | `0x34A9` | `0xC407` error reply is sent with length 0x6C but only `err` written | 104 stale `g_buf` bytes on the wire; the client reads only `err` for codes ≠ `0x2b80` (ErrMsgTable text) | length 4 |
| Z05-B9 | `0x3472`, `0x3483` | OPEN_*STORAGE_FAIL answers are bound to the empty handler | the client's storage window never gets an error; the open request stays pending client-side | send the storage error (e.g. `sp_GuildStorageError`) |
| Z05-B10 | `0x3475`, `0x3486`, `0x3488` | failure path writes the error code into the *received* packet and sends `0x3027`/`0x3030`/`0x3032` without filling `g_buf` | money and error code are stale bytes from the previous packet; client `0x3027`: stale `0x1480` = success, `0x1481`–`0x1483` specific texts, anything else "You have no authority"; `0x3030`: only `0x17e0`–`0x17e8` are handled, anything else is silent | write `g_buf+2..11` (the intended codes are `0x1485` / `0x17e8` "Failed to report. (DB Error)") |
| Z05-B11 | `0x348E`, `0x34C7` | success ACK `0x3036`/`0x3065` is sent with length 0x1A for an 8-byte struct | 16 stale `g_buf` bytes on the wire (client reads only the struct) | length 10 |
| Z05-B12 | `0x3489` / `0x348A` | no Character-server handler for the portal request, no zone handler for its answer | paid mini-house portal effects hang with their item/money locked | implement both ends like `0x347D`/`0x347E` |

## 12. Not reconstructed / uncertain

- Client texts in §10 are resolved by text id against the first `TextData*` table that has it; ids whose row is an empty string
  (`0x8c9`/`0x3807`, pick `0x342`, use `0x724`/`0x725`) show an empty message.
- Which codes the Character server returns on each failure, and which DB checks produce them, is D03's scope (its handlers for every
  request in §1.7 are in D03's table); this file lists the codes the zone tests and the client understands.
- `LC_Machine` as a vending machine is inferred from the NPC name only.
