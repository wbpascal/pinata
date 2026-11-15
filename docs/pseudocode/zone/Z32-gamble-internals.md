# Zone: gamble internals: TaiSai win tables, gamble objects, slot machines (Z32)

Source: the 2016 zone `Files/Server/2016/w00_Zone00/5ZoneServer2.exe`, read with
`python3 -I tools/protocol-re/clean.py re-data/exports/zone-pdb - <addr>…` (official names and member names from the NA2016
`Zone.pdb`, *(pdb2016)*: every class, member, enum and function name in this document comes from it unless marked). Data tables:
`Files/Server/2016/9Data/Shine/*.shn` (`python3 -I tools/protocol-re/shn.py`). Evidence markers as in `AGENTS.md`; no capture covers
dept 47.

This item extends Z06 (`docs/pseudocode/zone/Z06-economy.md`): Z06 documents the gamble-house handlers (§4), the mini-house TaiSai
(§3) and the slot-machine handlers (§5); this document documents the classes behind them: the TaiSai outcome and dividend
rules shared by both TaiSai games (§1), the gamble object base class and manager (§2), the gamble-house TaiSai table object
`CGambleDiceTaiSaiObject` (§3) and the slot-machine classes (§4).

## 1. TaiSai rules shared by both TaiSai games (`DiceTaiSai`, `DiceTaiSaiDividind`)

Two TaiSai games use the same two classes with separate instances:

| Global | Class | Used by | Initialised from |
|---|---|---|---|
| `gMiniHouseDiceTaiSai` DAT_13386e30 | `DiceTaiSai` (0x1290 bytes) | mini-house TaiSai (Z06 §3) | `zs_start_star` (Z10): `DiceTaiSai::Init(DiceDividind row 0 .AnyTriple)` |
| `gMiniHouseDiceTaiSaiDividind` DAT_133886f8 | `DiceTaiSaiDividind` (0x100) | mini-house TaiSai | `zs_start_star`: one `Init(rate r, DividendRate[r])` per column of `DiceDividind.shn` row 0 |
| `gGBDiceTaiSai` DAT_13295b38 | `DiceTaiSai` | gamble-house TaiSai (§3) | `zs_start_sleep` (Z10): `DiceTaiSai::Init(GBDiceDividind row 0 .AnyTriple)` |
| `gGBDiceTaiSaiDividind` DAT_13388578 | `DiceTaiSaiDividind` | gamble-house TaiSai | `zs_start_sleep`: `Init(r, GBDiceDividind row 0 .DividendRate[r])` for r = 0…14; `isInitFinishe` false → assert + ShineExit |

### 1.1 Tables

| Table | Columns (2016 values) | Use |
|---|---|---|
| `DiceDividind.shn`, `GBDiceDividind.shn` (1 row each, identical in 2016) | `DividendRate[15]` u16, indexed by enum `DividendRate`: `DR_Even 100, DR_Big 100, DR_Pair 800, DR_Triple 15000, DR_AnyTriple 2400, DR_4_17 5000, DR_5_16 3000, DR_6_15 1800, DR_7_14 1200, DR_8_13 800, DR_9_10_11_12 600, DR_Domino 500, DR_Single1 100, DR_Single2 200, DR_Single3 300`; `AnyTriple` u8 = 1 | dividend per bet group in percent of the stake (§1.5); `AnyTriple` is the `DiceTaiSai::Init` flag "a triple also wins its sum bet" (§1.3), not a rate |
| `DiceRate.shn`, `GBDiceRate.shn` (216 rows each) | `Rate` u32, all 100 in 2016 | weight of outcome index i (§1.2): the roll draws an index with probability `Rate[i] / ΣRate` (Z06 §3.4 for the house, §3 here for the gamble house); uniform in 2016, so each ordered throw has probability 1/216 |
| `GBDiceGame.shn` (1 row) | `MaxBetMoney 150000`, `CastTime 30000` (ms), `DelayTime 15000` (ms) | gamble-house TaiSai limits (§3); the mini-house uses `DiceGame.shn` per dice-table item (Z06 §3.1) |
| `GBJoinGameMember.shn` | `{GameType (MobType), MinJoinMember, MaxJoinMember}`: `{23 MT_GB_DICE, 1, 6}`, `{26 MT_GB_SLOTMACHINE, 1, 2}` | max gamers per object (`go_MaxPlayerInObject`, §2.2) |
| `GBTaxRate.shn` | `{GameType, u16 GB_TaxRate, GB_JPSaveType GB_JPSave, u16 GB_JPSaveRate}` *(pdb2016 struct: `GB_JPSave` at +6, `GB_JPSaveRate` at +0xa)*: `{23, 10, GB_JP_NONE, 0}`, `{26, 0, GB_JP_BET, 100}` | house cut per game (§3, §4) and the slot-machine jackpot saving (§4) |
| `GBEventCode.shn` | `{GameType, GB_ANIType GB_ANI, u32 GB_ECode}`: dice `0 801100, 1 801900, 2 802200` (wins), `3 801100, 4 801400, 5 801800` (losses); slot machine the same six plus `6 GB_START_Game 801000`, `7 GB_END_Game 801100` | player animation broadcast by `go_PlayerAction` (§2.4) |
| `GBReward.shn` (`SHND::g_GBReward` DAT_14d70e38) | `{GameType, GBRewardType RewardType, char Item_INX[32]}`: `{26, GBSM_JACKPOT, "M_GB_Slot01"}` | slot-machine jackpot reward item (§4); loader `cd_Load` FUN_005b8880, lookup `cd_Find` FUN_00620970 (§2.5) |

### 1.2 Outcome index and dice

An outcome is one of the 216 ordered throws of three dice `DiceTaiSaiInfo { u8 nNumber[3] }` (values 1–6).

```pseudo
DiceTaiSai::ConvertDice(dice → index)                                        @ FUN_00633830
    false if dice null / out null, or any of the three values is 0 or > 6
    index = (d0 − 1) × 36 + (d1 − 1) × 6 + (d2 − 1)          # 0 … 215
DiceTaiSai::ConvertDice(index → dice)                                        @ FUN_006338a0
    false if index ≥ 216 (0xd8) or out null
    d0 = index / 36 % 6 + 1;  d1 = index / 6 % 6 + 1;  d2 = index % 6 + 1
```

### 1.3 Outcome classification (`DiceTaiSai::Init`)

`DiceTaiSai.m_Dice[216]` holds one `DiceVariety` (0x16 bytes) per outcome index: `+0 Dice[3]`, `+3 char isEven`, `+4 isBig`,
`+5 isPair`, `+6 isTriple`, `+7 isSum`, `+8 u8 nDominoCnt`, `+9 u8 nDominoNum[6]` (3 pairs), `+0xf u8 nSingleCnt`,
`+0x10 u8 nSingleNum[6]` (3 pairs `{value, count}`).

```pseudo
DiceTaiSai::Init(bTripleSum)                                                  @ FUN_00634330
    for i in 0 … 215:
        v.Dice = ConvertDice(i)
        isEven = isBig = isPair = isTriple = isSum = −1;  nDominoCnt = 3; nSingleCnt = 3; the number arrays 0
    for each outcome v (dice a, b, c):
        equal pairs among (a,b), (b,c), (c,a): 0, 1 or 3
        1 (a pair x, odd one y): isPair = x; nDominoCnt = 1, domino (x, y); nSingleCnt = 2, singles {x, 2}, {y, 1}
        0 (all different):      dominoes (a,b), (a,c), (b,c); singles {a,1}, {b,1}, {c,1}
        3 (triple x):           isTriple = x; nDominoCnt = 0; nSingleCnt = 1, single {x, 3}
        each domino pair is stored low value first
        not a triple:  s = a + b + c; isSum = s; isEven = (s even) ? 1 : 2; isBig = (11 ≤ s ≤ 17) ? 1 : 2
        triple:        bTripleSum ≠ 0 and x ∉ {1, 6}: isSum = s (6, 9, 12 or 15); isEven / isBig stay −1
```

The domino and single arrays and their counts are filled but `get_PrizeWinningBet` (§1.4) recomputes both from the dice and never
reads them (nor does anything else in the 2016 zone *(inferred: no other reader of `nDominoNum` / `nSingleNum` in the export)*).

### 1.4 Winning bets of an outcome (`get_PrizeWinningBet`)

Bet kinds are `DICE_TAISAI_BETTING` (52): `DTB_EVEN 0, DTB_ODD 1, DTB_BIG 2, DTB_SMALL 3, DTB_PAIR_1…6 = 4…9, DTB_TRIPLE_1…6 = 10…15,
DTB_ANYTRIPLE 16, DTB_SUM_4…17 = 17…30, DTB_DOMINO_12 … DTB_DOMINO_56 = 31…45` (the 15 pairs a < b in the order 12, 13, 14, 15, 16,
23, 24, 25, 26, 34, 35, 36, 45, 46, 56), `DTB_SINGLE_1…6 = 46…51`.

```pseudo
DiceTaiSai::get_PrizeWinningBet(index, out DiceTaiSaiPrizeWinning)          @ FUN_00633920
    false if index ≥ 216 or out null
    out = { u8 nPrizeWinningBetCnt, PrizeWinningBetInfo { u8 nSingle, DICE_TAISAI_BETTING nBetting }[12] }
    clear the count and every nSingle (nBetting of unused entries keeps old stack bytes; callers read only the first Cnt)
    v = m_Dice[index]; append in this order:
        isEven 1 → DTB_EVEN, 2 → DTB_ODD
        isBig  1 → DTB_BIG,  2 → DTB_SMALL
        isPair > 0   → DTB_PAIR_1 + isPair − 1
        isTriple > 0 → DTB_TRIPLE_1 + isTriple − 1, then DTB_ANYTRIPLE
        isSum > 0    → DTB_SUM_4 + isSum − 4
        for each domino (a, b), a < b, in enum order: both a and b among the three dice → DTB_DOMINO_ab
        for each value n = 1 … 6: k = number of dice showing n; k > 0 → { nSingle = k, DTB_SINGLE_n }
    out.nPrizeWinningBetCnt = number appended (at most 10: even/odd, big/small, pair, sum, 3 dominoes, 3 singles)
```

### 1.5 Bet groups, dividends and the bet limit (`DiceTaiSaiDividind`)

`DiceTaiSaiDividind { u16 DividendRate[15] @0, bool bIsInitDividendRate[15] @0x1e, DividendRate ConertDividendRateTable[52] @0x30 }`.

```pseudo
DiceTaiSaiDividind::DiceTaiSaiDividind()                                       @ FUN_00634000
    all rates 0, none initialised; ConertDividendRateTable (bet kind → group):
        EVEN, ODD → DR_Even;  BIG, SMALL → DR_Big;  PAIR_* → DR_Pair;  TRIPLE_* → DR_Triple;  ANYTRIPLE → DR_AnyTriple
        SUM_4, SUM_17 → DR_4_17;  SUM_5, 16 → DR_5_16;  SUM_6, 15 → DR_6_15;  SUM_7, 14 → DR_7_14;  SUM_8, 13 → DR_8_13
        SUM_9 … SUM_12 → DR_9_10_11_12;  DOMINO_* → DR_Domino;  SINGLE_* → DR_Single3
Init(group r, rate)                                                             @ FUN_00634190
    r ≥ 15 → false; DividendRate[r] = rate; bIsInitDividendRate[r] = true; return "all 15 initialised"
isInitFinishe()                                                                 @ FUN_00634170
    all 15 bIsInitDividendRate set
get_DividendRate(kind, nSingle)                                                 @ FUN_006342d0
    kind ≥ 52 → 0
    group = ConertDividendRateTable[kind]; for SINGLE_* the group is DR_Single1/2/3 by nSingle 1/2/3 (any other nSingle → 0)
    group not initialised → 0; else DividendRate[group]
get_DividindMoney(kind, nSingle, u32 bet)                                       @ FUN_00634230
    group as in get_DividendRate (0 on the same failures)
    return (u32) round(bet × DividendRate[group] / 100.0)     # x87 rounding; exact for the 2016 rates (multiples of 100)
is_CanBettingMoney(kind, u32 maxBet, u32 amount)                                @ FUN_006341d0
    kind ≥ 52, group ≥ 15 or group not initialised → false
    limit = (maxBet × 100, computed in 32 bits) / DividendRate[group]        # u64 division
    return amount ≤ limit                    # SINGLE_* always use DR_Single3 here, i.e. the 3-dice rate
```

The callers pass `amount` = the gamer's bet already on that kind + the new bet and `maxBet` = the game's `MaxBetMoney`
(gamble house `GDTSO_DiceTaiSai_CanBetting` FUN_00618db0, §3; mini house Z06 §3.3): the limit keeps the dividend of one bet kind
at or below `MaxBetMoney`. A group whose rate is 0 would divide by zero (no 2016 row has one).

### 1.6 Win table (what a rebuild needs)

For outcome dice (a, b, c), with the 2016 rates. "×" = dividend as a multiple of the stake (`DividendRate / 100`); whether the
stake is returned on top is settled by the payout code (§3; Z06 §3.4: net = Σ won dividends − cut − Σ lost stakes, the winning
stake is neither added nor taken *(read in Z06; re-read for the gamble house in §3)*):

| Bet kind | Wins when | Group | × (2016) | Max bet at MaxBetMoney 150 000 |
|---|---|---|---|---|
| EVEN / ODD | no triple and the sum is even / odd | DR_Even | 1 | 150 000 |
| BIG / SMALL | no triple and the sum is 11–17 / 4–10 | DR_Big | 1 | 150 000 |
| PAIR_v | exactly two dice show v (a triple of v does **not** win) | DR_Pair | 8 | 18 750 |
| TRIPLE_v | all three show v | DR_Triple | 150 | 1 000 |
| ANYTRIPLE | any triple | DR_AnyTriple | 24 | 6 250 |
| SUM_s, s = 4…17 | a + b + c = s and no triple; with `AnyTriple` = 1 (2016) also the triples 2, 3, 4, 5 for s = 6, 9, 12, 15 | 4/17: 50, 5/16: 30, 6/15: 18, 7/14: 12, 8/13: 8, 9–12: 6 | 3 000, 5 000, 8 333, 12 500, 18 750, 25 000 |
| DOMINO_ab | both a and b appear among the dice | DR_Domino | 5 | 30 000 |
| SINGLE_v | v appears k = 1, 2, 3 times | DR_Single1/2/3 | k (1, 2, 3) | 50 000 (limit uses the 3× rate) |

There is no SUM_3 / SUM_18 bet. Pair bets losing on a triple differs from the usual sic-bo rule (*(inferred)* intended or not:
`Init` sets `isPair` only for exactly two equal dice); not tagged as a bug since the client's bet board cannot tell us the intent.

## 2. Gamble objects: base class and manager

### 2.1 `CGambleObject` (base of `CGambleDiceTaiSaiObject`, `SlotMachineCluster`, `SlotMachineScreen`)

Layout (0x18): `+0 vftable`, `+4 ShineObject* go_pGambleNPCObj` (dealer NPC), `+8 u8 go_nMaxEnterPlayerCnt`, `+9 u8 go_nEnterPlayerCnt`,
`+0xc ShineObject** go_pEnterPlayerObj` (gamers, packed at the front), `+0x10 u8 go_nMaxWhereStandCnt` (seats), `+0x11 u8
go_nWhereStandCurr` (next seat to try), `+0x14 u16* go_nWhoStandHnd` (seat → player handle, 0xFFFF free).

Virtual slots (63; recovered from RTTI, `tools/protocol-re/rtti.py`). Names are the overriding classes' names (*pdb2016*); the
base entries are mostly folded one-line stubs whose PDB name belongs to an unrelated function with the same code (COMDAT folding), so the
base name of a slot is not known. Base stub values in brackets.

| Slot | Name | Base | TaiSai (§3) | Cluster / Screen (§4) |
|---|---|---|---|---|
| 0x00 | go_Enter_Player | FUN_00614a60 | base | FUN_0061f0b0 / FUN_00620d00 |
| 0x04 | go_Out_Player | FUN_006152d0 | base | FUN_0061f1d0 / base |
| 0x08 | go_Init(npc) | [1] FUN_00500380 | FUN_00614f10 | FUN_0061dd70 / FUN_00620b00 |
| 0x0c | go_Get_GambleType | [0] FUN_00570b00 | GBT_DICETAISAI (1) FUN_00557bb0 | GBT_SLOTMACHINE (2) FUN_00647230 |
| 0x10 | go_CanEnter | FUN_00614cb0 | base | base |
| 0x14 | go_WhereStand | FUN_00614cc0 | base | base |
| 0x18 | go_CanWhereStand | FUN_00614d40 | base | base |
| 0x1c | go_CanLevel(level) | [1] FUN_00500380 | `GambleActiveDice.UseMinLv ≤ level` FUN_00614d70 | [1] |
| 0x20 | go_Routine | [no-op] FUN_00417480 | FUN_006181e0 | FUN_0061f300 / FUN_00620de0 |
| 0x24 | go_SendGameInfo | [0x2617] FUN_00618150 | FUN_006183d0 | FUN_00620b80 / [0x2617] |
| 0x28 | GDTSO_GetDiceTaiSaiInfo (TaiSai) / go_FindSubGambleObject (cluster) | [null] FUN_004a9c90 | [null] | FUN_0061eec0 / [null] |
| 0x2c | "full check": add the "game full" abstate to the NPC when the last place is taken | [1] FUN_005af8d0 | [1] | [1] / [0] `SlotMachineScreen::go_IsFullCheck` FUN_004b8d20 |
| 0x30 | go_PlayerAction | FUN_00615180 | base | base |
| 0x34 | go_Init_MaxPlayer | [0] FUN_00615e70 | FUN_006180d0 | FUN_00618110 |
| 0x38 | GDTSO_GetGameStatus | [0] | FUN_00618130 | [0] |
| 0x3c … 0xd4 | TaiSai methods (`GDTSO_*`) | stubs returning the method's "no object" code: SendTaiSaiBettingInfo 0x2619, Enter 0x1C88, Out / BroadOut 0x2625, CanBetting 0x2635, CanBettingCancel 0x2643, CanAutoDiceRoll / MoneyResult 0x2652, PrepareNextGame 0x1CD4, info getters null, SetDiceFix / SetDiceProbability 0 | §3 | stubs |
| 0xd8 | go_PlayerUnmarking | `_purecall` | FUN_0061b1d0 | FUN_0061f3b0 / FUN_0061f480 |
| 0xdc … 0xec | slot-machine screen methods `SMS_Start`, `SMS_StopButton`, `SMS_StopButton` (2nd), `SMS_WheelStop`, `SMS_WheelStop` (2nd) | 0x28CD (FUN_00614db0, FUN_00614d90, FUN_00614da0) | stubs | stubs / FUN_0061f540, FUN_0061f6e0, FUN_00625340, FUN_0061f8c0, FUN_0061f930 |
| 0xf0, 0xf4 | go_SMS_PacketMake_JackpotRank / _WintRank | [no-op] FUN_00549070 | stubs | stubs / FUN_00620ef0, FUN_00624520 |
| 0xf8 | go_SMC_WinRank | [no-op] FUN_00509900 | stub | FUN_00625280 / stub |

The 0x28CD code (the base `SMS_*` result) is what the slot handlers return when the object found is not a screen (§4).

### 2.2 Base methods

```pseudo
CGambleObject()  / ~CGambleObject()                                            @ FUN_00614930 / FUN_00614950
    all members 0; the destructor frees the gamer and seat arrays
go_Init_NpcObject(npc)        npc null → 0; else go_pGambleNPCObj = npc, 1       @ FUN_00614980
go_Init_PlayerObject(n)       max gamers = n, count 0, gamers = new ShineObject*[n] all null; 0 if allocation failed   @ FUN_006149a0
go_Init_nWhoStandHnd(n)       seats = n; seat array = new u16[n] all 0xFFFF; 0 if allocation failed                   @ FUN_00614a00
go_MaxPlayerInObject(MobType t)                                                    @ FUN_00614dc0
    first GBJoinGameMember row with GameType == t → its MaxJoinMember; none (or no table) → 0

go_Enter_Player(p)                                                                 @ FUN_00614a60
    false if no gamer array, p null, count ≥ max, or gamers[count] already set
    gamers[count++] = p
    vt[0x2c]() and count == max and abstate 0x1A3 STA_GBGAMEMEMBERFULL exists:
        npc.so_AbnormalState_Set(0x1A3, strength 1, now, …, no end)  (vt 0x638) succeeded →
            so_AbnormalState_BitSet(npc, 0x1A3); its sub-abstate 1 has info → so_AbnormalState_BroadcastSet(npc, 0x1A3, KeepTime, 1)
    return true                       # the "full" abstate shows the dealer NPC as full to the clients around it
go_Out_Player(p)                                                                   @ FUN_006152d0
    false if no gamer array or p null or p not a gamer
    remove p and close the gap (order kept), count −= 1
    the NPC has STA_GBGAMEMEMBERFULL (so_mobile_AbstateList, asl_Abstate_IsSet):
        npc.vt[0x650] so_AbnormalState_Reset(0x1A3); so_AbnormalState_BitReset; so_AbnormalState_BroadcastReset
    return true                       # the seat array is not touched here (the callers free the seat, §3 / §4)
go_Find_Player(charNo)        first gamer whose so_GetCharRegistNumber (vt 0x344) == charNo, else null             @ FUN_00614b10
go_Get_EnterPlayerCnt / go_Get_EnterPlayer(i) (null outside 0 … count−1)                                          @ FUN_00614b70 / FUN_00614b80
go_Get_EnterPlayerIndex(out i, by object / by handle / by charNo)                                                 @ FUN_00614bb0 / FUN_00614c00 / FUN_00614c50
go_CanEnter()                 count < max                                                                         @ FUN_00614cb0
go_WhereStand(out seat)                                                                                            @ FUN_00614cc0
    try at most `seats` seats starting at go_nWhereStandCurr (round robin): the first free one → *seat = it; the cursor moves
    past it; true.  None free → false (the cursor has gone once round)
go_CanWhereStand(seat)        seat < seats and seat free                                                           @ FUN_00614d40
go_Get_NpcObject / go_Get_MaxEnterPlayerCnt                                                                        @ FUN_0045ff90 / FUN_00591ff0
```

`go_WhereStand` only proposes a seat; it does not mark it (`0xBC17` TYPE_AND_WHERE_STAND returns it, Z06 §4.3; the join handlers
mark the seat, §3 / §4).

### 2.3 Player animation (`go_PlayerAction`, `0xBC1E`)

```pseudo
go_PlayerAction(p, MobType game, GB_ANIType choices[], n)                          @ FUN_00615180
    k = rndbox[n] for 1 ≤ n ≤ 100 (uniform 0 … n−1, Z23 §8.6), else 0
    row = GBEventCode (SHND::g_EventCode) with GameType == game and GB_ANI == choices[k]; none → nothing
    every player in range of p (so_AllOfRange with the default range argument) ← 0xBC1E NC_GAMBLE_PLAYERACT_CMD
        { u16 playerhandle = p.handle, u32 effect_body = row.GB_ECode }                    # 6 bytes
```

Client (`MHDiceGameTask` dispatcher, `FUN_0071b4d0`): finds the object by `playerhandle` (none → ignored), looks `effect_body` up
(FUN_004984e0, an action/emotion table *(inferred)*) and plays it on that object (object vt 0x1c4). The callers pass the win codes
(ANI 0–2) or the loss codes (3–5) with n = 3 (§3, §4).

### 2.4 `CGambleObjectManager` (`gGambleObjectManager` DAT_14d70e58, ours `g_GambleMgr` in Z06)

Layout (0x204): `+0 std::vector<CGambleObject*> gom_GambleObject` (every bound object), `+0x10 int gom_DiceTaisaiMaxCnt`, `+0x14
CGambleDiceTaiSaiObject* gom_DiceTaisai` (array, stride 0x570), `+0x18 u8 gom_NeedRecalDiceRankInfo`, `+0x19 u8 gom_DiceRankInfoCnt`,
`+0x1a GDT_DiceRankInfo gom_DiceRankInfo[20]` (`{Name5 sCharID, u32 nWinCnt}`, 0x18), `+0x1fc gom_SlotMachine { int MaxNumber;
SlotMachineCluster* SlotMachine }` (stride 0xb8). Constructed empty at start-up (`dynamic_initializer_for_gGambleObjectManager`
FUN_0069b830), destroyed at exit (FUN_00615910: both arrays with their element destructors, the vector).

```pseudo
gom_Init()                              (stage zs_start_long, Z10)                  @ FUN_00615a00
    NPC list (som_Getlist 4) missing → 0
    pass 1: per NPC, MobInfo (mobdatabox[npc.so_mob_MobID], vt 0x708).Type == MT_GB_DICE (23) → dice count +1;
            == MT_GB_SLOTMACHINE (26) → slot count +1
    no gamble NPC → 1
    gom_DiceTaisai = new CGambleDiceTaiSaiObject[dice count]; gom_SlotMachine.SlotMachine = new SlotMachineCluster[slot count]
        (an allocation failure is not checked)
    pass 2: per gamble NPC in list order, the next unused object of its kind:
        the list node is past the end or holds no object → return 1 (binding ends quietly)
        obj.vt[8] go_Init(npc) false → return 0          # Z10-B31: the stage ignores the result
        push obj into gom_GambleObject
    return 1
gom_Routine()                           (every main-loop pass, zs_mainthreadfunction) @ FUN_006158d0
    every bound object: vt[0x20] go_Routine()
gom_GetGambleObject(npcHandle)          bound object whose NPC handle (so_GetZoneHandle) == npcHandle   @ FUN_00615830
gom_FindPlayerObject(charNo)            the gamer (player object) with that charNo in any bound object  @ FUN_00615890
gom_FindGambleObject(charNo, type)      the object of that type (dice array or cluster array) that has a gamer with that charNo @ FUN_00615490
gom_GetGambleObject(type, i)            dice[i] / cluster[i] or null (GM `&GB_DiceFix`, Z11 §6.7)   @ FUN_00615440
gom_GetGambleObjectMaxCnt(type)         dice count / cluster count / 0 (used by the slot win ranking, §4)  @ FUN_00615410
gom_SetNeedRecalDiceRankInfo()          gom_NeedRecalDiceRankInfo = 1   (TaiSai Enter, Out, MoneyResult, ResultLog, §3)  @ FUN_00615530
gom_GetDiceRankInfo(out GDT_DiceRankInfo[], out u8 n)   (0xBC6F CURR_RANK_REQ, Z06 §4.4)          @ FUN_00615540
    if recalculation needed:
        collect for every TaiSai object, every gamer i: { brief info charid (vt 0x6d0, +2), nWinCnt = obj.vt[0xcc](i) }
            (GDTSO_GetTotalWinCnt, §3); after the 100th entry: sort and keep 20, continue
        no TaiSai object → count 0, return 0
        qsort descending by nWinCnt (GDTSO_RankSortCompare FUN_006181c0 returns a.nWinCnt < b.nWinCnt: 1 or 0, never
            negative; MSVC qsort only tests > 0, so the order is descending, ties in any order *(inferred from the CRT)*)
        cache the first min(count, 20); clear the flag
    copy the cache to out; *n = cache count; return 1
```

### 2.5 `GBReward` table

```pseudo
SHND::CommonData<GBReward, CmpGambleItemReward>(name)      vector empty, name stored                     @ FUN_006153a0
cd_Load()                                                                                                   @ FUN_005b8880
    name null → assert "CommonData<T, C>::cd_Load : Name NULL" + ShineExit; read "../9Data/Shine/<name>" (BinaryDataBox<GBReward>),
    append every row (0x28 bytes) to the vector (a missing file gives an empty table, no error)
cd_Find({GameType, RewardType})    first row with both equal, else null                                   @ FUN_00620970
```

## 3. Gamble-house TaiSai table (`CGambleDiceTaiSaiObject`)

One object per dealer NPC of MobInfo type `MT_GB_DICE` (23), bound by `gom_Init` (§2.4). The handlers that drive it (join, leave,
bet, cancel, ranks) are Z06 §4.4; this section documents the object. Coins are the currency (`p+0x2aa70`, player vt 0xb04 get /
0xb08 set, Z06 §4.1). The game is always in auto mode (`DTGM_AUTO`): the server rolls when the betting timer runs out; there is
no manual mode in the gamble house (`bModeType` is always sent as 0).

### 3.1 Layout, tables, states

`CGambleDiceTaiSaiObject : CGambleObject` (0x570) *(pdb2016)*: `+0x18 GI_DiceTaiSai* DiceTaiSai` (never used by the methods read),
`+0x1c GambleGamerInfo* G_GamerInfo` (one record per gamer, same index as `go_pEnterPlayerObj`), `+0x20 GambleDiceTaiSai
G_DiceTaiSai`:

| Offset (object) | Member | Meaning |
|---|---|---|
| +0x20 | `GambleActiveDice.MaxBetMoney` u32 | `GBDiceGame.MaxBetMoney` (150 000): the bet limit base (§1.5) |
| +0x24 / +0x26 | `.CastTime` / `.DelayTime` u16 | betting time / stand-by time, **in ticks of 0.1 s** (`GBDiceGame` ms × 10 / 1000: 300 = 30 s, 150 = 15 s) |
| +0x28 | `.UseMinLv` u16 | minimum level, always 0 (`go_CanLevel` slot 0x1c: `UseMinLv ≤ level`, so never refuses) |
| +0x2a | `.GetSysRate` u16 | house cut, `GBTaxRate` row of game type 23 `.GB_TaxRate` (10); its use in the payout: §3.10 |
| +0x2c / +0x38 | `.WinCode[3]` / `.LoseCode[3]` u32 | `GBEventCode` (type 23, GB_ANI 0…2) / (GB_ANI 3…5) `.GB_ECode`: 801100 801900 802200 / 801100 801400 801800 (0 if a row is missing) |
| +0x44 | `nGameStatus` | `DICE_TAISAI_GAME_STATUS`: 0 `DTGS_NONE_BETTING` (board empty), 1 `DTGS_BETTING` (timer running), 2 `DTGS_ROLLING`, 3 `DTGS_STAND_BY` |
| +0x48 / +0x4c | `bIsActiveTimerCheckTime` u8 / `nTimerCheckTime` u32 | the one timer: active flag and due tick (`clockwatch.cw_CurrTick`) |
| +0x50 | `History[7]` (`DiceTaiSaiInfo`, 3 bytes each) | the last 7 throws, newest first |
| +0x65 | `bIsAdminDice` u8 | GM-fixed throw pending (§3.9) |
| +0x66 | `CurrentRollingDice` | the throw of the current round (or the GM-fixed one) |
| +0x70 | `BettingInfo[52]` (`BettingSumInfo {u64 nMoney; u16 nPlayerCnt}`, 0x10) | per bet kind: total staked by all gamers and the number of gamers with a non-zero stake on it |
| +0x3b0 | `nBetSumMoney` u64 | total staked on the board |
| +0x3b8 / +0x568 | `nDiceRate[216]` u16 / `nDiceRateSum` u32 | outcome weights (`GBDiceRate`, GM-adjustable) and their sum, used by the roll (§3.10) |

Gamer record `GambleGamerInfo` (0xe8): `+0 GI_DiceTaiSai DiceTaiSaiInfo { u8 bGameLeaveReserve; u8 bRoomLeaveReserve; +4
DiceTaiSaiAllBetting BetInfo { u32 nBetMoney[52]; +0xd0 u32 nBetSumMoney }; +0xd8 u64 nTotalDividend }`, `+0xe0 u32 nTotalWinCnt`.
`bGameLeaveReserve` = "leave when this round is over" (§3.7); `bRoomLeaveReserve` is cleared at Enter and never set in the gamble
house (only the mini-house player record of the same type uses it, Z06 §3).

State cycle (details in §3.6–§3.8, §3.10):

```
NONE_BETTING --first stake on an empty board (BroadSetTimer: timer = CastTime, 0xBC81 start)--> BETTING
BETTING --last stake cancelled (BroadSetTimer cancel) / last gamer with stakes leaves (Out)--> NONE_BETTING  (0xBC81 stop)
BETTING --timer due (go_Routine): CanAutoDiceRoll + DiceRoll ok → BroadDiceRoll, Result_DiceRoll--> ROLLING … STAND_BY (§3.10)
STAND_BY --timer due (go_Routine): BroadLargeAmount, clear board and bets, reserved leaves, 0xBC80--> NONE_BETTING
```

Stakes are not taken from the coins when they are placed: betting only checks that the coins cover all own stakes (§3.6); the round
result books the net amount (§3.10). Leaving during betting therefore simply removes the stakes (§3.7).

### 3.2 Construction and initialisation

```pseudo
CGambleDiceTaiSaiObject()                                                      @ FUN_00618050
    CGambleObject(); status NONE_BETTING; timer inactive, due 0; History, bIsAdminDice, CurrentRollingDice, BettingInfo[52],
    nBetSumMoney all 0     (GambleActiveDice, nDiceRate and the gamer records are set by go_Init)
~CGambleDiceTaiSaiObject()        base destructor only (G_GamerInfo, from malloc, is not freed: process exit only)   @ FUN_006180c0

go_Init(npc)                      (vt 0x08, from gom_Init §2.4)                 @ FUN_00614f10
    npc null → 0
    go_pGambleNPCObj = npc; seats go_nMaxWhereStandCnt = 13; go_nWhoStandHnd = new u16[13], all 0xFFFF   (allocation failure → 0)
    n = go_MaxPlayerInObject(MT_GB_DICE) (GBJoinGameMember: 6); n = 0 → 0
    vt 0x34 go_Init_MaxPlayer(n) false → 0
    row = GBDiceGame record 0 (gGBDiceGame); none → 0
    MaxBetMoney, CastTime, DelayTime ← row; UseMinLv = 0
    GetSysRate = (u16) GBTaxRate.cd_Find(GameType 23).<u32 at +4>       # COMDAT-shared CommonData<GBBanGame> find: the u32 at +4
                                                                        # truncated to u16 is GB_TaxRate (10)
        # (original bug) Z32-B1: the find result is not null-checked: a GBTaxRate.shn without a row 23 crashes the zone at start-up
    WinCode[k] = GBEventCode.cd_Find({23, ANI k}).GB_ECode for k = 0, 1, 2; LoseCode[k] for ANI 3, 4, 5 (0 when no row)
    CastTime = CastTime × 10 / 1000; DelayTime = DelayTime × 10 / 1000     # ms → 0.1 s ticks
    vt 0xac GDTSO_SetDiceProbability(null, 0)        # load the weights (§3.9); its result is ignored
    return 1
go_Init_MaxPlayer(n)              (vt 0x34)                                     @ FUN_006180d0
    go_Init_PlayerObject(n) (§2.2) false → 0; G_GamerInfo = malloc(n × 0xe8) (not zeroed: each record is cleared when a gamer
    takes it, §3.4); return G_GamerInfo ≠ null
GDTSO_GetGameStatus()             (vt 0x38) nGameStatus                          @ FUN_00618130
```

### 3.3 Player-side gamble state (`ShinePlayer::so_Gamble_*`)

The player's current game type is `sp_Gamble_JoinType` (`GAMBLE_TYPE`, `p+0x2aa78`, Z06 §4.1: `GBT_BASE` 0 none, `GBT_DICETAISAI` 1,
`GBT_SLOTMACHINE` 2).

```pseudo
so_Gamble_IsGambleHouse()        (player vt 0xaf8) current map's FieldList row +0x3a == 7          @ FUN_00615cf0
so_Gamble_CharCoinData(PROTO_NC_CHAR_COININFO_CMD)   (vt 0xb00; Z06 §4.1, from WM 0x10DD)          @ FUN_00615d10
    coins (vt 0xb08) = nCoin; exchanged coins (vt 0xb14) = nExchangedCoin
    max = GBExchangeMaxCoin row whose Level == p's level (vt 0x4d8), first match; no match → 0
        (a null record while scanning → return without sending)
    remaining = max − exchanged if exchanged < max (and its high dword 0), else 0
    p ← 0x10DE { u64 nCoin, u64 remaining }
so_Gamble_CanJoinGamble(type)    (vt 0xb1c) sp_Gamble_JoinType == GBT_BASE (argument ignored)       @ FUN_00615e60
so_Gamble_IsJoinThisGamble(type) (vt 0xb20) sp_Gamble_JoinType == type                              @ FUN_00615e80
so_Gamble_IsJoinAnyGamble(out)   (vt 0xb24) *out = type (if out); type ≠ GBT_BASE                   @ FUN_00615ea0
so_Gamble_SetGambleType(type)    (vt 0xb28) sp_Gamble_JoinType = type; 1                            @ FUN_00615ec0
```

Every TaiSai method below treats "p is in this game" as `vt 0xb20(GBT_DICETAISAI)`, and every broadcast goes to the gamers that
pass it (all of them, in practice).

### 3.4 Gamer records

```pseudo
GDTSO_GetDiceTaiSaiInfo(int i)          (vt 0xbc) &G_GamerInfo[i] for 0 ≤ i < count, else null          @ FUN_0061b830
GDTSO_GetDiceTaiSaiInfo(ShineObject p)  (vt 0xb8) record of gamer p (go_Get_EnterPlayerIndex), else null @ FUN_0061b940
GDTSO_GetDiceTaiSaiInfo(u16 handle)     (vt 0xb4) by object handle (0xFFFF → null)                       @ FUN_0061ba50
GDTSO_GetDiceTaiSaiInfo(u32 charNo)     (vt 0xb0) by charNo (0xFFFFFFFF → null)                          @ FUN_0061bb70
GDTSO_GetTotalWinCnt(int i / p / handle / charNo)   (vt 0xcc / 0xc8 / 0xc4 / 0xc0) &record.nTotalWinCnt, same lookups
                                                    @ FUN_0061bc80 / FUN_0061bda0 / FUN_0061bec0 / FUN_0061bff0
    # all eight return null when G_GamerInfo is null
GDTSO_ClearDiceTaiSaiInfo()             (vt 0xa4)                                                        @ FUN_0061b490
    count < max: record[count] (the one the next gamer gets) = all 0 (leave flags, stakes, nTotalDividend, nTotalWinCnt); 1
    else 0
GDTSO_GetDiceTaiSaiGameLeaveInfo(p, out u8)   (vt 0xd0)                                                   @ FUN_0061c110
    p in this game and a gamer → *out = bGameLeaveReserve; 1.  Else 0
GDTSO_SetDiceTaiSaiGameLeaveInfo(p, u8 v)     (vt 0xd4)                                                   @ FUN_0061c220
    v ≠ 0, p in this game and a gamer → bGameLeaveReserve = v; 1.  Else 0      # cannot clear the flag
```

`nTotalWinCnt` is per seat-holding session: cleared at Enter, counted by the round result (§3.10), read by the current-rank list
(`gom_GetDiceRankInfo`, §2.4).

### 3.5 Joining

Z06 §4.4 `0xBC64 GAME_JOIN_REQ` (FUN_0061ccc0) checks the field, the NPC, the distance, `go_CanEnter` (0x2615) and
`go_CanWhereStand(nWhereStand)` (0x2616), sets the direction, then calls, in this order: `go_SendGameInfo` (must return 0x2610),
`GDTSO_SendTaiSaiBettingInfo` (0x2610 or 0x2618), `GDTSO_DiceTaiSai_Enter` (0x2610) → `GDTSO_DiceTaiSai_BroadEnter`. The join
answer is therefore sent **before** Enter; an Enter failure after it is not reported (all of Enter's refusals are checked earlier by the
handler, so this is not reachable in practice).

(original bug) Z32-B2: no TaiSai code writes the seat array `go_nWhoStandHnd` (neither the join handler nor Enter / Out / the
round code read for this item mark or free a seat; *(inferred: no writer found; the slot-machine parts re-check the shared base)*):
every seat < 13 stays "free", so `0x2616` (seat taken) is only returned for a seat number ≥ 13 and several gamers may stand on the
same seat; `0xBC17` (Z06 §4.3) never answers `0x2606` and proposes the seats round-robin.

```pseudo
go_SendGameInfo(p)             (vt 0x24)                                                        @ FUN_006183d0
    p null → 0x2617
    p ← 0xBC65 NC_GAMBLE_DICE_TAISAI_GAME_JOIN_ACK {                    # 0x32 + 2n bytes
        u16 nError = 0x2610
        DiceTaiSaiInfo DiceHistory[7] = History (newest first)
        u32 nGameStatus = nGameStatus;  u32 bModeType = 0 (DTGM_AUTO)
        u16 nTimer = CastTime (ticks)
        u32 nInterval = nTimerCheckTime − now if status is BETTING, else 0   (ticks left)
        u16 nGetSysRate = GetSysRate;  u64 nMaxBetMoney = MaxBetMoney
        u16 nUseMinLv = not written   # (original bug) Z32-B3: payload bytes 0x2f–0x30 keep whatever the shared send buffer held
        u8 nGamerCnt = n;  u16 nGamerHnd[n] = handles of the current gamers except p
    }
    return 0x2610
```

Client (`MHDiceGameTask::Recv_NC_GAMBLE_DICE_TAISAI_GAME_JOIN_ACK` FUN_00707e10): 0x2610 → clears its gamer and bet maps, stores
status, `nTimer / 10` and (the low 16 bits of) `nInterval / 10` as seconds, the sys rate and max bet; replays the history oldest
first; adds the listed gamers and itself; status 1 draws the remaining time bar; status 2 or 3 sets "round in progress" (betting
disabled); `nMaxBetMoney ≠ 0` shows "Lucky House Dice Game - MAX BET %d coins" (text 0x620ee2ae). It does not read `nUseMinLv`, so
Z32-B3 has no visible effect. Other codes: 0x261B → its error-table message; 0x261A → a modal (text 0x236e0f79); 0x2615 / 0x2617 →
the literal system message "%d" (a client formatting slip).

```pseudo
GDTSO_SendTaiSaiBettingInfo(p)    (vt 0x3c)                                                     @ FUN_006185f0
    p null or G_GamerInfo null → 0x2619
    status ≠ BETTING → 0x2618 (nothing sent)
    entries = for every gamer g ≠ p in this game, every kind k with g.nBetMoney[k] ≠ 0: { u16 g.handle, u32 k, u32 g.nBetMoney[k] }
    p ← 0xBC67 NC_GAMBLE_DICE_TAISAI_GAME_BETTING_INFO_CMD { u8 PartMask, u16 nBettingCnt, GDT_BettingInfo Betting[] (10 bytes) }
        split when the packet would pass 7 500 bytes: PartMask bit 0 = first packet, bit 1 = last (one packet: 3); with at most
        6 × 52 entries (3 125 bytes) one packet always suffices
    return 0x2610
```

Client (FUN_00706fd0): a first part (bit 0) is applied, a later part only while it waits for one; each entry adds the amount to that
gamer's stake on that kind and redraws the chip (`CheckBettingChip`).

```pseudo
GDTSO_DiceTaiSai_Enter(p)         (vt 0x40)                                                     @ FUN_00618890
    p null → 0x2617;  count ≥ max → 0x2615;  p already in a gamble game (vt 0xb1c false) → 0x261B
    p.sp_Gamble_JoinType = GBT_DICETAISAI (vt 0xb28)
    vt 0xd4 SetGameLeaveInfo(p, 0)      # (original bug) Z32-B4: dead call: Set refuses 0 and p is not a gamer yet;
                                        # ClearDiceTaiSaiInfo below does the reset
    vt 0xa4 ClearDiceTaiSaiInfo() and vt 0x00 go_Enter_Player(p) (§2.2: may set the NPC's "game full" abstate) →
        gom_SetNeedRecalDiceRankInfo(); return 0x2610
    else p.sp_Gamble_JoinType = GBT_BASE; return 0x2617
GDTSO_DiceTaiSai_BroadEnter(p)    (vt 0x44)                                                     @ FUN_00618a80
    p null → 0x2617;  p not in this game or not a gamer → 0x261B
    every other gamer ← 0xBC66 NC_GAMBLE_DICE_TAISAI_GAME_JOIN_CMD { u16 nPlayerHnd = p.handle };  return 0x2610
```

Client 0xBC66 (FUN_00708600): adds the gamer and shows "%s has entered." (text 0x7f90c3d5).

### 3.6 Betting, cancelling and the betting timer

The request structs are `PROTO_NC_GAMBLE_DICE_TAISAI_BETTING_REQ / _CANCEL_REQ { DiceTaiSaiBetting {u32 nBetting (kind), u32 nMoney},
u16 index }` (Z06 §4.4); the handler passes the request's `DiceTaiSaiBetting` unchanged and calls `CanBetting`, `Betting`,
`BroadSetTimer(bet, DTBT_BETTING)`, `BroadBetting` (cancel: `CanBettingCancel`, `BettingCancel`, `BroadSetTimer(bet,
DTBT_BETTING_CANCEL)`, `BroadBettingCancel`).

```pseudo
GDTSO_DiceTaiSai_CanBetting(p, bet)   (vt 0x54)                                                 @ FUN_00618db0
GDTSO_DiceTaiSai_Betting(p, bet)      (vt 0x58; repeats every check of CanBetting, then books)  @ FUN_0061c6c0
    p or bet null → 0x2635;  p not in this game → 0x2634;  status ∉ {NONE_BETTING, BETTING} → 0x2636
    bet.nMoney = 0 → 0x2637;  kind ∉ 0…51 → 0x2638;  p not a gamer → 0x2639
    coins (vt 0xb04) < own nBetSumMoney + nMoney → 0x263A          # only compared when the coins' high dword is 0
    not is_CanBettingMoney(kind, MaxBetMoney, own nBetMoney[kind] + nMoney) (gGBDiceTaiSaiDividind, §1.5) → 0x263B
    # (original bug) Z32-B5: both sums are 32-bit and wrap: nMoney close to 2^32 passes both checks (e.g. own stake 100, nMoney
    # 2^32 − 51: the sums are 49)
    Betting only:
        GDTSO_SetDiceTaiSaiAllBettingInfo(record, bet, out first) false → 0x2635
        BettingInfo[kind].nMoney += nMoney (u64); BettingInfo[kind].nPlayerCnt += first; nBetSumMoney += nMoney (u64)
    return 0x2630
GDTSO_SetDiceTaiSaiAllBettingInfo(record, bet, out first)                                        @ FUN_006198c0
    any null or nMoney = 0 → 0
    first = (record.nBetMoney[kind] = 0); record.nBetSumMoney += nMoney; record.nBetMoney[kind] += nMoney (u32); 1
```

Z32-B5 effect: the gamer's record wraps to the small value, while the board (`BettingInfo[kind].nMoney`, `nBetSumMoney`, 64-bit) and
the `0xBC73` broadcast carry the full `nMoney`. Cancels can only remove the recorded (small) amount, so the board total stays
non-zero until the round's clear (§3.8): the "board empty" stop in `Out` and the cancel-stop of the timer then never fire for that
round, and the other clients show a stake of about 4.29 × 10⁹. The payout uses the gamer's record (§3.10).

```pseudo
GDTSO_DiceTaiSai_BroadBetting(p, bet)   (vt 0x5c)                                                @ FUN_00619080
    p or bet null → 0x2635
    every other gamer ← 0xBC73 NC_GAMBLE_DICE_TAISAI_BETTING_CMD { u16 nPlayerHnd, u32 nBetting, u32 nMoney };  return 0x2630

GDTSO_DiceTaiSai_CanBettingCancel(p, bet) (vt 0x60)                                              @ FUN_00619200
GDTSO_DiceTaiSai_BettingCancel(p, bet)    (vt 0x64; same checks, then books)                     @ FUN_0061ca00
    p or bet null → 0x2643;  p not in this game → 0x2644;  status ∉ {NONE_BETTING, BETTING} → 0x2647
    nMoney = 0 → 0x2648;  kind ∉ 0…51 → 0x264B;  p not a gamer → 0x2649;  own nBetMoney[kind] < nMoney → 0x264A
    BettingCancel only:
        GDTSO_SetDiceTaiSaiAllBettingCancelInfo(record, bet, out emptied) false → 0x2643
        BettingInfo[kind].nMoney −= nMoney; .nPlayerCnt −= emptied; nBetSumMoney −= nMoney
    return 0x2640          # 0x2645 / 0x2646 are never returned (Z06 §4.4)
GDTSO_SetDiceTaiSaiAllBettingCancelInfo(record, bet, out emptied)                               @ FUN_006199c0
    any null, nMoney = 0 or nMoney > record.nBetMoney[kind] → 0
    record.nBetSumMoney −= nMoney; record.nBetMoney[kind] −= nMoney; emptied = (record.nBetMoney[kind] = 0); 1
GDTSO_DiceTaiSai_BroadBettingCancel(p, bet) (vt 0x68)                                            @ FUN_00619450
    p or bet null → 0x2643
    every other gamer ← 0xBC76 NC_GAMBLE_DICE_TAISAI_BETTING_CANCEL_CMD { u16 nPlayerHnd, u32 nBetting, u32 nMoney };  0x2640

GDTSO_DiceTaiSai_BroadSetTimer(bet, type)   (vt 0x50)                                            @ FUN_006195d0
    bet null or type > 1 → 0x2635
    type DTBT_BETTING:
        status ≠ NONE_BETTING → 0x2630 (timer already running: nothing)
        Σ over the 52 kinds of BettingInfo[k].nPlayerCnt ≠ 1 → 0x2635          # only the very first stake starts the timer
        timer active, due = now + CastTime
        every gamer ← 0xBC81 NC_GAMBLE_DICE_TAISAI_TIMER_CMD { u8 bIsStart = 1, u16 nTimer = CastTime, u32 nInterval = CastTime }
        status = BETTING
    type DTBT_BETTING_CANCEL:
        status ≠ BETTING → 0x2635
        some kind still has nPlayerCnt ≠ 0 → 0x2630
        every gamer ← 0xBC81 { 0, 0, 0 }; status = NONE_BETTING       # the timer flag stays set: when it falls due go_Routine
                                                                      # finds status 0 and only clears it
    return 0x2630    (the handlers ignore the result)
```

Client: `0xBC73` (FUN_00707420) ignores its own handle, adds the stake to that gamer, sets "betting" and redraws the chip;
`0xBC76` (FUN_00707700) ignores its own handle, subtracts the stake and, when no gamer has a stake left, shows "All betting has been
canceled." (text 0x8aa5acb9) and returns to status 0; `0xBC81` (FUN_007067d0) `bIsStart = 0` resets the time bar, otherwise it
stores `nTimer / 10` seconds (`nInterval` is not read).

### 3.7 Leaving

`GDTSO_DiceTaiSai_Out` is called by `0xBC68 GAME_LEAVE_REQ` (Z06 §4.4) and by `go_PlayerUnmarking` / `GDTSO_ExcuteLeaveGame`
(§3.10). On 0x2627 the handler sets `SetGameLeaveInfo(p, 1)` (leave at the end of the round); on 0x2620 / 0x2627 it calls
`BroadOut(p, reserve)`.

```pseudo
GDTSO_DiceTaiSai_Out(p)            (vt 0x48)                                                     @ FUN_0061c330
    p null → 0x2625;  p not in this game → 0x2623;  p not a gamer → 0x2624
    status ROLLING or STAND_BY → 0x2627         # reserved: the caller decides (handler: SetGameLeaveInfo(p, 1))
    record of p: for every kind k with a stake: SetDiceTaiSaiAllBettingCancelInfo(record, {k, nBetMoney[k]}) →
        BettingInfo[k].nMoney −= stake; .nPlayerCnt −= emptied (always 1 here); nBetSumMoney −= stake
        # nothing to refund: stakes were never taken from the coins
    vt 0x04 go_Out_Player(p) false → 0x2624      (§2.2: also removes the NPC's "game full" abstate)
    close the gap in G_GamerInfo (records after p move down one; memcpy of (new count − index) records)
    p.sp_Gamble_JoinType = GBT_BASE
    no gamer left → timer inactive, due 0
    nBetSumMoney = 0:
        status BETTING and every nPlayerCnt = 0 → every remaining gamer ← 0xBC81 { 0, 0, 0 }
        status = NONE_BETTING
    gom_SetNeedRecalDiceRankInfo(); return 0x2620
GDTSO_DiceTaiSai_BroadOut(p, u8 reserve)   (vt 0x4c)                                             @ FUN_00618c40
    p null → 0x2625
    every gamer ≠ p in this game ← 0xBC6A NC_GAMBLE_DICE_TAISAI_GAME_LEAVE_CMD { u8 bReserve = reserve, u16 nPlayerHnd = p.handle }
    return 0x2620
```

The seat is not freed (none is ever marked, Z32-B2). Client `0xBC6A` (FUN_00707850): `bReserve = 1` only marks the gamer (removed
at the next `0xBC80`); otherwise it drops that gamer's chips (in status 1), removes the gamer, shows "%s has stopped playing game."
(text 0x37452093) and returns to status 0 when no stake is left on the board.

### 3.8 Round routine and the round reset

```pseudo
go_Routine()                       (vt 0x20; gom_Routine every main-loop pass, §2.4)              @ FUN_006181e0
    (calls a folded no-op, FUN_00417480)
    timer inactive or not due → return
    status BETTING:
        vt 0x78 CanAutoDiceRoll() = 0x2650 and vt 0x7c DiceRoll() = 0x2650 →
            vt 0x80 BroadDiceRoll(); vt 0x88 Result_DiceRoll()            (§3.10: ROLLING, then STAND_BY with DelayTime)
    status STAND_BY:
        vt 0xa0 BroadLargeAmount()            (§3.10)
        vt 0x6c ClearDiceBettingInfo()        board cleared, status NONE_BETTING, history shifted
        vt 0x74 ClearGamerBettingInfo()       every gamer's stakes and nTotalDividend 0
        vt 0x9c ExcuteLeaveGame()             reserved gamers leave (§3.10)
        every gamer ← 0xBC80 NC_GAMBLE_DICE_TAISAI_BET_START_CMD { u32 bModeType = 0 (DTGM_AUTO), DiceTaiSaiInfo
            CurrentRollingDice }              # the throw just played
        vt 0x70 SetDiceHistory()              History[0] = CurrentRollingDice; CurrentRollingDice = 0
        status = NONE_BETTING
    timer inactive                            # in every case, also when the roll checks failed (§3.10)
GDTSO_ClearDiceBettingInfo()       (vt 0x6c)                                                       @ FUN_00619ad0
    nBetSumMoney = 0; BettingInfo[52] = 0; status NONE_BETTING; History[1…6] = History[0…5] (the oldest is dropped); 1
GDTSO_SetDiceHistory()             (vt 0x70)                                                       @ FUN_00619b70
    History[0] = CurrentRollingDice; CurrentRollingDice = {0, 0, 0}; 1
GDTSO_ClearGamerBettingInfo()      (vt 0x74)                                                       @ FUN_00619be0
    every gamer record (by index): nBetMoney[52] = 0, nBetSumMoney = 0, nTotalDividend = 0 (leave flags and nTotalWinCnt kept); 1
```

Client `0xBC80` (FUN_00707bd0): stores the mode, adds the dice to its history, zeroes every gamer's stakes, resets the board,
removes the gamers marked by a reserved `0xBC6A` (if the marked one is the player itself it sends `0xBC68 GAME_LEAVE_REQ` itself) and
opens the dealer dialog "Please make your bet.\nWish you luck." (text 0x367e5072).

### 3.9 GM: fixed throw and outcome weights

Z11 §6.7 `&GB_DiceFix` / `&GB_DiceProbability` find the machine and call:

```pseudo
GDTSO_SetDiceFix(DiceTaiSaiInfo dice)       (vt 0xa8)                                             @ FUN_0061b5d0
    dice null or status ∉ {NONE_BETTING, BETTING} → 0
    bIsAdminDice = 1; CurrentRollingDice = dice; 1          # used by the next roll (§3.10); the dice are not range-checked here
GDTSO_SetDiceProbability(DiceTaiSaiInfo* dice, u16 weight)  (vt 0xac)                            @ FUN_0061b6b0
    dice null (reload):
        nDiceRateSum = 0; for i = 0…215: rec = GBDiceRate record i (none → return 0, the sum is partial);
            nDiceRate[i] = (u16) rec.Rate; nDiceRateSum += rec.Rate (u32)
        # (original bug) Z32-B6: the weight is stored truncated to 16 bits but summed in full: a Rate above 65 535 makes the sum
        # disagree with the weights (latent: every 2016 Rate is 100)
    else:
        i = ConvertDice(dice) (§1.2) false → 0
        nDiceRateSum += weight − nDiceRate[i]; nDiceRate[i] = weight        # any status, takes effect at the next roll
    return 1
```

### 3.10 Roll, result and payout

The round runs in four steps, all from `go_Routine` (§3.8) or from the GameDB answer: the timer falls due in BETTING → roll and
the payout request to GameDB (`0xBC78`) → GameDB answer `0xBC79` books the coins, logs and animates, starts the stand-by timer →
the stand-by timer falls due → board reset, reserved leaves, `0xBC80` (§3.8). Return codes are `0x26xx` result codes; the callers
ignore them unless stated.

**Roll** (status BETTING, timer due):

```pseudo
GDTSO_DiceTaiSai_CanAutoDiceRoll()   (vt 0x78)                                                    @ FUN_00619cd0
    status ≠ BETTING → 0x2655;  nBetSumMoney = 0 → 0x2656;  else 0x2650
GDTSO_DiceTaiSai_DiceRoll()          (vt 0x7c)                                                    @ FUN_00619dd0
    status ≠ BETTING → 0x2655;  nBetSumMoney = 0 → 0x2656
    bIsAdminDice = 1 (GM fix, §3.9) → bIsAdminDice = 0; CurrentRollingDice is already the fixed throw
    else:
        r = ((rand() << 15) | rand()) % nDiceRateSum + 1        # C runtime rand(), 15 bits each; the first call gives the high bits
            # (original bug) Z32-B8: no check for nDiceRateSum = 0: a GM who sets all 216 weights to 0 (&GB_DiceProbability, §3.9)
            # makes the next roll divide by zero (zone crash)
        i = first outcome index 0…215 with r ≤ nDiceRate[0] + … + nDiceRate[i]   (r −= nDiceRate[i] while r > nDiceRate[i])
            # no such index (weights summing to less than nDiceRateSum, Z32-B6) → i = 216
        ConvertDice(i → CurrentRollingDice) (§1.2) false (i = 216) → 0x2652
    status = ROLLING; 0x2650
```

So the outcome is drawn with probability `nDiceRate[i] / nDiceRateSum` (2016: every `GBDiceRate.Rate` is 100, i.e. 1/216 each, fair
dice; `% nDiceRateSum` of a 30-bit value adds a negligible modulo bias). go_Routine calls `BroadDiceRoll` and `Result_DiceRoll`
only when both return 0x2650; otherwise it just clears the timer flag. (original bug) Z32-B9: a failed roll (i = 216) leaves the
table in BETTING with the timer off, and `BroadSetTimer` starts a timer only from NONE_BETTING (§3.6): the board accepts stakes but
never rolls until every stake is cancelled (or every gamer with stakes leaves, §3.7) and a new first stake restarts the timer.

```pseudo
GDTSO_DiceTaiSai_BroadDiceRoll()     (vt 0x80)                                                    @ FUN_00619fc0
    every gamer p (index order, null slots skipped) ← 0xBC77 NC_GAMBLE_DICE_TAISAI_DICE_ROLL_CMD { u16 nError }:
        0x2661 p not in this game (vt 0xb20(1));  0x2662 no gamer record (vt 0xb8);
        0x2663 coins (vt 0xb04) < record.nBetSumMoney;  0x2664 lock list (vt 0x7d4) null or busy (L.vt[0x10], Z05 §1.2);
        else 0x2660                       # the same four tests decide below whether p's stakes are settled
    0x2650
```

Client `0xBC77` (`MHDiceGameTask::Recv_NC_GAMBLE_DICE_TAISAI_DICE_ROLL_CMD` FUN_007064b0): only `0x2660` → task state 2 (rolling);
any other code is ignored (no text).

**Payout request** (status ROLLING):

```pseudo
GDTSO_DiceTaiSai_Result_DiceRoll()   (vt 0x88)                                                    @ FUN_0061a350
    npc = go_Get_NpcObject(); null → 0x2652
        # (original bug) Z32-B9: also here the status stays ROLLING with the timer off (go_Routine clears it): the table is stuck
        # for good (Out refuses in ROLLING, §3.7); unreachable in practice (go_Init stores a non-null NPC, §3.2)
    W = get_PrizeWinningBet(ConvertDice(CurrentRollingDice)) (§1.4)      # both results ignored; the dice are valid here
    for every gamer p in index order:
        skip p if: null, not in this game (vt 0xb20(1)), no record (vt 0xb8), coins < record.nBetSumMoney (64-bit compare),
                   lock list L (vt 0x7d4) null, or L busy (L.vt[0x10] = 1)          # = BroadDiceRoll codes 0x2661…0x2664
        for k = 0…51 with record.nBetMoney[k] ≠ 0:
            is_CanBettingMoney(k, MaxBetMoney, nBetMoney[k])    # result ignored: (original bug) Z32-B7, dead check (as Z06-B17)
        net = 0 (s64)
        for k = 0…51 with stake b = record.nBetMoney[k] ≠ 0:
            k ∈ W (entry e with e.nBetting = k):
                d = get_DividindMoney(k, e.nSingle, b)                 (§1.5: round(b × DividendRate / 100))
                net += d + (s64)(GetSysRate × d) / −1000               # = d − trunc(GetSysRate × d / 1000): the house cut, ‰
            else:
                net −= b                                                # lost stake
            # a winning stake is neither returned nor taken: stakes were never deducted (§3.1), so the dividend is the gain
        record i of the request (i = number of gamers settled so far) = { u16 nError = 0, u16 lockindex = L.index,
                                                                          u32 nPlayerNo = p.charNo (vt 0x344), i64 nTotalDividend = net }
        net ≥ 0 → L.icl_StoreGBCoin(L.index, net, +1, 0)   else L.icl_StoreGBCoin(L.index, −net, −1, 0)     (L.vt[0x70])
            # coin reservation with releaser CoinChange (Z05 §1.4, Z06 §4.1); last argument 0 = not an exchange
        L.icl_IncIndex()                                    # FUN_0043c130: next lock index
    GameDB (sock2gameDB) ← 0xBC78 NC_GAMBLE_DICE_TAISAI_DB_DICE_ROLL_RESULT_REQ {
        NETPACKETZONEHEADER header = { u16 npc handle, u32 npc vt 0x344 }, DiceTaiSaiInfo DiceNum = CurrentRollingDice,
        u16 nResultCnt, GDT_DiceRollApplyResult[nResultCnt] (0x10 each) }          # size 0xb + 0x10 × n
    bIsActiveTimerCheckTime = 0; 0x2650
```

GameDB runs `usp_Gamble_setDice` / `usp_Gamble_setDiceResult` and answers `0xBC79` (D03 §11, `FUN_00421a30`: overall `nError` 0x2680 ok,
0x2681…0x2683 failures, and a game number `nGameNo`).

**GameDB answer** (`0xBC79 NC_GAMBLE_DICE_TAISAI_DB_DICE_ROLL_RESULT_ACK { u16 nError, i32 nGameNo, NETPACKETZONEHEADER header, u16
nResultCnt, GDT_DiceRollApplyResult[] }`, handler `GameDBSession::gds_NC_GAMBLE_DICE_TAISAI_DB_DICE_ROLL_RESULT_ACK` FUN_0061d930, Z06 §4.4):

```pseudo
gds_NC_GAMBLE_DICE_TAISAI_DB_DICE_ROLL_RESULT_ACK(ack)                                          @ FUN_0061d930
    ack.nError ≠ 0x2680 → nothing                      # Z06-B10: coins stay reserved, the table stays in ROLLING without timer
    npc = som_GetObject(header.clienthandle); npc null, npc.vt 0x344 ≠ header.charregistnumber or npc not on a map → nothing
    o = gom_GetGambleObject(header.clienthandle) (§2.4); null or o.vt 0x0c (game type) ≠ 1 (GBT_DICETAISAI) → nothing
    o.MoneyResult_DiceRoll(ack) (vt 0x84); o.ResultLog_DiceRoll(ack.nGameNo) (vt 0x8c); o.BroadResult_DiceRoll() (vt 0x90);
    o.BroadEmotion_DiceRoll(ack) (vt 0x94); o.PrepareNextGame() (vt 0x98)

GDTSO_DiceTaiSai_MoneyResult_DiceRoll(ack)   (vt 0x84)                                           @ FUN_0061a180
    for each result r (ack.nResultCnt):
        p = gamer whose charNo = r.nPlayerNo (go_Get_EnterPlayerIndex by charNo); none, p.charNo ≠ r.nPlayerNo or p not in this
            game → skip              # its lock reservation is neither applied nor freed
        r.nError = 0x2680 → L.icl_Apply_N_Free(p, r.lockindex, 0) (L.vt[0x1c], Z05 §1.3): the CoinChange releaser books the
            coins (net ≥ 0: coins += net; else coins −= |net|, or 0 with an assert when they do not cover it) and sends
            0xBC04 (Z06 §4.1); false → LockIndexLog "…MoneyResult_DiceRoll : <lock>"
        else → L.icl_Free(r.lockindex) (L.vt[0x28])               # reservation dropped, coins unchanged
        record(p).nTotalDividend = r.nTotalDividend if > 0 else 0
    gom_SetNeedRecalDiceRankInfo() (§2.4); 0x2650

GDTSO_DiceTaiSai_ResultLog_DiceRoll(i32 nGameNo)   (vt 0x8c)                                     @ FUN_0061a7c0
    npc null → 0x2652
    packet 0xBC7A NC_GAMBLE_DICE_TAISAI_DB_DICE_ROLL_RESULT_LOG_CMD { header (npc, as 0xBC78), i32 nGameNo, u16 nResultLogCnt,
        GDT_DiceRollApplyResultLog[] (0x15 each) }
    W = winning bets of CurrentRollingDice (as above)
    for every gamer p with a record (vt 0xb8) and a win counter (vt 0xc8): wins[p] = 0
        # no "in game", coin or lock test: (original bug) Z32-B10: gamers that Result_DiceRoll skipped (0x2662…0x2664) are logged
        # as if settled and their winning kinds count for nTotalWinCnt and the title below
        for k = 0…51 with stake b ≠ 0: append { nPlayerNo = p.charNo, nBetting = k, nBettingMoney = b,
                nBattingRate = 0, bStatus = 0, nSysRate = GetSysRate, nDividendMoney = 0 }
            k ∈ W: nBattingRate = get_DividendRate(k, nSingle) (§1.5); bStatus = 1;
                   nDividendMoney = d − (GetSysRate × d) / 1000 (u32 arithmetic; d as above);  wins[p] += 1;  record.nTotalWinCnt += 1
            count × 0x15 + 0xc > 7500 → send the full packet to GameDB and start a new one (same header and nGameNo)
    remaining count ≠ 0 → send to GameDB (no answer: D03 FUN_00421d60, usp_Gamble_setDiceLog)
    every gamer with wins[p] ≠ 0: p.so_SetCTDiceTaiSaiWin(wins[p]) (player vt 0x1b4, FUN_005113c0)
        → CCharacterTitleZone::CT_WinDiceTaiSaiWin FUN_005cc490: m_TitleValues[58].TitleValue += wins (u64), bTitleSave = 1,
          CheckNewTitle(58) (title unlocks: Z18 §6.2)
    gom_SetNeedRecalDiceRankInfo(); 0x2650
```

`nTotalWinCnt` and the title counter therefore count winning **bet kinds**, not winning rounds (a throw that pays BIG, SUM_10 and a
domino counts 3).

```pseudo
GDTSO_DiceTaiSai_BroadResult_DiceRoll()   (vt 0x90)                                              @ FUN_0061abe0
    every gamer p ← 0xBC7B NC_GAMBLE_DICE_TAISAI_DICE_ROLL_RESULT_CMD { u16 nError = 0x2670 (0x2671 if p not in this game),
        DiceTaiSaiInfo nDiceInfo = CurrentRollingDice }                       # size 5
    0x2650
GDTSO_DiceTaiSai_BroadEmotion_DiceRoll(ack)   (vt 0x94)                                          @ FUN_0061ad40
    n = 0
    for each result r at position j:
        repeat gamer-count times:                          # (original bug) Z32-B11: the inner loop re-tests gamer j (the
            p = go_Get_EnterPlayer(j)                      # result's position), never the other gamers
            p non-null, p.charNo = r.nPlayerNo, p in this game and r.nError = 0x2680:
                r.nTotalDividend > 0 → code = WinCode[rand() % 3];  < 0 → code = LoseCode[rand() % 3];  = 0 → none (try again)
                entry n = { u16 nGamerHnd = p.handle, u32 nEmotion = code }; n += 1; last = p; stop the repeat
    n ≠ 0 → 0xBC7C NC_GAMBLE_DICE_TAISAI_DICE_ROLL_RESULT_EMOTION_CMD { u8 nGamerCnt = n, GDT_EmotionInfo[n] (6 each) }
            to every player in last's map (AxialListPacketBroadcast, so_AllInMap(last, …, 1))
    0x2650
GDTSO_DiceTaiSai_PrepareNextGame()   (vt 0x98)                                                   @ FUN_0061af50
    status ≠ ROLLING → 0x2652
    timer active, due = now + DelayTime (stand-by, 15 s); status = STAND_BY; 0x1cd0
```

Result j matches gamer j only while the request order still holds: B11 drops the emotion of every gamer after one that
`Result_DiceRoll` skipped. WinCode / LoseCode are the `GBEventCode` effects of §3.1 (801100 / 801900 / 802200 and 801100 / 801400 /
801800).

Clients: `0xBC7B` (FUN_007063f0): only `0x2670` → task state 3, stores the outcome index (client `DiceTaiSai::ConvertDice`) and
starts the dice animation with the three values. `0xBC7C` (FUN_00706d30): per entry finds the character by handle, looks the code
up in the client table at `DAT_00a7f034` (record field +0x69 = code) and plays that record's action on the character (char vt 0x1c4);
an unknown handle aborts the rest of the list.

**Stand-by end** (status STAND_BY, timer due; go_Routine §3.8 calls these in this order before `0xBC80`):

```pseudo
GDTSO_DiceTaiSai_BroadLargeAmount()   (vt 0xa0)                                                  @ FUN_0061b2c0
    list = gamers p in this game with a record whose nTotalDividend ≥ MaxBetMoney (64-bit compare): { u16 handle, u32 low dword }
    list not empty → every gamer in this game ← 0xBC7F NC_GAMBLE_DICE_TAISAI_LARGE_AMOUNT_CMD { u8 nGamerCnt,
        GDT_LargeAmountInfo { u16 nGamerHnd, u32 nMoney }[] }      # size 1 + 6 × n
    1
GDTSO_ExcuteLeaveGame()               (vt 0x9c; after ClearDiceBettingInfo, so the status is NONE_BETTING)   @ FUN_0061b020
    for every gamer p from the last index down to 0:
        p in this game, GetGameLeaveInfo(p) ok and bGameLeaveReserve = 1:
            e = Out(p) (vt 0x48, §3.7)              # 0x2620 here (status NONE_BETTING)
            e = 0x2627 → SetGameLeaveInfo(p, 1)
            p ← 0xBC69 NC_GAMBLE_DICE_TAISAI_GAME_LEAVE_ACK { u16 nError = e }
            e = 0x1c90 → BroadOut(p, …)            # (original bug) Z32-B12: Out never returns 0x1c90 (0x2620 meant):
                                                    # the other gamers get no 0xBC6A; harmless, their clients drop the
                                                    # gamer marked by the earlier reserved 0xBC6A at the next 0xBC80 (§3.8)
    1
```

Client `0xBC7F` (FUN_00706e50): per entry with a known handle and `nMoney ≠ 0`: the amount as text over that character and the
announcement "%s has received %s by game result. Congratulation!" (TextData2 0x4746208a). Client `0xBC69` (FUN_00706390): `0x2620`
→ `ShutDownGambleHouse` (closes the TaiSai window); other codes are ignored.

### 3.11 Unmarking and the logout gate

```pseudo
ShinePlayer::so_Unmark(…)  (FUN_00558900, Z01): p in any gamble (vt 0xb24) → gom_FindGambleObject(p.charNo, type).go_PlayerUnmarking(p)
CGambleDiceTaiSaiObject::go_PlayerUnmarking(p)   (vt 0xd8)                                       @ FUN_0061b1d0
    e = Out(p) (§3.7)
    0x2620 → BroadOut(p, 0)                        # left at once: stakes removed from the board
    0x2627 → SetGameLeaveInfo(p, 1); BroadOut(p, 1) # ROLLING / STAND_BY: only reserved
    other → nothing
ShinePlayer::so_Gamble_IsCanSessionCloseing()   (player vt 0xb2c)                                @ FUN_00615ee0
    sp_Gamble_JoinType = GBT_DICETAISAI, o = gom_FindGambleObject(charNo, GBT_DICETAISAI) and o.status (vt 0x38) = ROLLING:
        sp_Gamble_SessionCloseingTime = 0 → set it to now + 0x32 (5 s); return 0
        now ≥ sp_Gamble_SessionCloseingTime → 1;  else 0
    otherwise 1
```

`sp_Schedule_Logout` (FUN_00558160) and `ZoneServer::zs_disconnect` (FUN_005abb60) free the player only when vt 0x17c (mini-house
TaiSai, Z06 §3) and vt 0xb2c both return 1 (`confidence.md` L6): a gamer who logs out while the dice roll waits up to 5 s for the
GameDB answer. The gate does not cover STAND_BY. (original bug) Z32-B13: a gamer unmarked in STAND_BY (or in ROLLING after the 5 s)
gets only the reservation; `go_pEnterPlayerObj` keeps the raw pointer of the freed player object until `ExcuteLeaveGame` (stand-by
end) or `MoneyResult` use it. What that touches depends on the pool slot's reuse *(inferred)*: the slot's memory stays a
`ShinePlayer` (Z01 §4 fixed pools), so the calls go through a valid vtable, but `Out` then writes `sp_Gamble_JoinType = 0` and sends
`0xBC69` to whatever player holds that slot. (original bug) Z32-B14: `sp_Gamble_SessionCloseingTime` is only zeroed by the
`ShinePlayer` constructor (FUN_0055bc80), never after a gate: a second logout attempt in the same session during a later roll passes
at once.

### 3.12 Worked example round

Gamer A stakes 1 000 on BIG, 500 on PAIR_3, 200 on SUM_10 (limits §1.6: 150 000 / 18 750 / 25 000); gamer B stakes 2 000 on SMALL.
Both have ≥ their stake sums in coins. `GetSysRate` = 10 (‰), `GBDiceRate` uniform.

1. The first stake starts the 30 s timer (`0xBC81`, status BETTING). When it falls due both get `0xBC77` 0x2660, and the
   roll draws index 87 = (3 − 1) × 36 + (3 − 1) × 6 + (4 − 1), i.e. dice (3, 3, 4): sum 10, no triple.
2. Winning kinds (§1.4): SMALL (sum 4–10), EVEN (10), PAIR_3, SUM_10, DOMINO_34, SINGLE_3 (k = 2), SINGLE_4 (k = 1).
3. A: BIG loses −1 000; PAIR_3 d = 500 × 8 = 4 000, cut 40 → +3 960; SUM_10 d = 200 × 6 = 1 200, cut 12 → +1 188. net = 4 148.
   B: SMALL d = 2 000 × 1 = 2 000, cut 20 → +1 980.
4. `0xBC78` to GameDB with {0, lockA, A, 4 148} and {0, lockB, B, 1 980}; coin reservations +4 148 / +1 980.
5. `0xBC79` 0x2680: coins A += 4 148, B += 1 980 (`0xBC04` each); nTotalDividend 4 148 / 1 980. `0xBC7A` logs 4 rows (A: BIG
   rate 0 status 0 dividend 0, PAIR_3 rate 800 status 1 dividend 3 960, SUM_10 rate 600 status 1 dividend 1 188; B: SMALL rate 100
   status 1 dividend 1 980); A's nTotalWinCnt += 2, B's += 1 (and title value 58). `0xBC7B` (3, 3, 4) to both; `0xBC7C` with a random
   WinCode for A and for B; status STAND_BY, 15 s.
6. Stand-by over: nobody reached 150 000 → no `0xBC7F`; board and stakes cleared; `0xBC80 { 0, (3, 3, 4) }`; status NONE_BETTING.

Had A been short of coins (coins < 1 700) at the roll, A would get `0xBC77` 0x2663, no settlement (neither loss nor win), but
the `0xBC7A` rows and the win count would still be written (Z32-B10).

## 4. Slot machines (`SlotMachine::*`)

A slot-machine **cluster** (`SlotMachineCluster`, one per dealer NPC, gamble type `GBT_SLOTMACHINE` 2) holds two **screens**
(`SlotMachineScreen smc_Screens[2]`, one per seated player); the handlers are Z06 §5. Three zone-wide singletons carry the game
rules; all screens of the zone share them: `g_SlotMachineScreenManager` DAT_14d71160 (symbol decks, bet coins), `g_SlotMachineAnalyse`
DAT_14d710a0 (pattern tables) and `g_SlotMachineJackPotRanking` DAT_14d712a8 (jackpot pools, rankings). This part (§4.1…§4.6) covers
the spin: tables, symbol draw, pattern match, jackpot and payout. The lifecycle (objects, join and leave, start, DB answer, wheel stop,
routine, rankings) is §4.7…§4.11.

### 4.1 Tables and the three singletons

`ZoneServer::zs_start_long` FUN_005b8c00 loads, after `g_TaxRate` (`GBTaxRate`), `g_EventCode` (`GBEventCode`) and `g_GBReward`,
unconditionally and in this order: `smsm_Load`, `sma_Load`, `smjpr_Load`, then `gom_Init` (§2.4). A missing or unreadable file
stops the server (`ShineExit`). The 2016 data (`shn.py`):

| Table (row struct, size) | Columns | 2016 rows | Read by |
|---|---|---|---|
| `GBSMCardRate` (6) | `GBSMCardType GBSMCard`, u16 `GBSM_CardRate` | symbol weights: 0 HPPotion 210, 1 SPPotion 210, 2 Honeying 120, 3 Boogy 110, 4 Pinky 110, 5 PrinceSlime 50, 6 QueenSlime 50, 7 KingSlime 50, 8 FiestaLogo 50 (Σ 960) | `smsm_Load` |
| `GBSMNPC` (0x24) | `char GBSM_MobInx[32]`, `GBSMBetType GBSMBet` | `GB_SlotMachine_01_01…_12` → 0, `_02_01…_08` → 1, `_03_01…_04` → 2 | `smsm_Load` |
| `GBSMBetCoin` (6) | `GBSMBetType GBSMBet`, u16 `GBSMCoin` | 0 → 10, 1 → 100, 2 → 500 coins per bet unit | `smsm_Load` (kept open as `smsm_BetCoin`) |
| `GBSMGroup` (5) | u8 `GBSM_GroupID`, `GBSMCardType GBSMCard` | groups 1…9 = symbol 0…8 alone; group 10 = the three slimes 5, 6, 7 | `sma_Load` |
| `GBSMLine` (4) | u8 `GBSM_GroupID`, u8 `GBSM_Num`, u16 `GBSM_RatioLine` | (1,1) 20, (2,1) 20, (3,1) 30, (4,1) 40, (5,1) 50, (6,1) 35, (7,1) 45, (8,1) 55, (9,1) 100, (10,2) 20, (10,3) 25 | `sma_Load` |
| `GBSMAll` (5) | u8 `GBSM_GroupID`, u8 `GBSM_Num`, u16 `GBSM_RatioAll`, u8 `GBSM_IsJP` | (1…9, 1): 200 200 300 400 500 350 450 550 1000; IsJP only for group 9 | `sma_Load` |
| `GBSMCenter` (3) | u8 `GBSM_GroupID`, u16 `GBSM_RatioCenter` | (9) 2 | `sma_Load` |
| `GBSMJPRate` (`GBSMJackpotRate`, 0xc) | u32 `GBSM_MinCount`, `GBSM_MaxCount`, `GBSM_JPRate` | 0…100 000 → 0, 100 001…500 000 → 100, 500 001…1 000 000 → 5 000, 1 000 001…9 999 999 → 10 000 | `smjpr_Load` |
| `GBTaxRate` (0xc) | `MobType GameType`, u16 `GB_TaxRate`, `GB_JPSaveType GB_JPSave`, u16 `GB_JPSaveRate` | slot machine = row 26 (0x1a): tax 0 ‰, `GB_JP_BET` (1), JP rate 100 ‰ | `smjpr_Load` |
| `GBReward` (§2.5) | | row 26 = jackpot reward item | `SMS_StopButton` |
| `GBEventCode` (§2.3) | | GameType 26, ANI 0…2 win / 3…5 loss | `go_PlayerAction` |

Symbols (`GBSMCardType`): 0 HPPotion, 1 SPPotion, 2 Honeying, 3 Boogy, 4 Pinky, 5 PrinceSlime, 6 QueenSlime, 7 KingSlime,
8 FiestaLogo. Machine types (`GBSMBetType`): `GB_SlotMachine_01` 0, `_02` 1, `_03` 2, `MAX_GBSMBETTYPE` 3 (= "none").

```pseudo
SlotMachineScreenManager (0x148)                                       ctor @ FUN_00623860, dtor @ FUN_00623900
    +0x00 vector<u8> smsm_LocateDeck          # permutation deck index → screen cell 0…8
    +0x10 vector<u8> smsm_CardDeck[9]         # one symbol deck per cell
    +0xa0 u32 smsm_CardDeckPoint              # common read position of all nine decks
    +0xa8 double smsm_CardRateArray[9]        # symbol probability (written, never read by the zone)
    +0xf0 vector<NPCvsBetType {Name8 NPC; GBSMBetType betype}> smsm_NPC
    +0x100 BinaryDataBox<GBSMBetCoin> smsm_BetCoin
    # ctor/dtor only construct / free these members

smsm_Load()                                                             @ FUN_00624820
    clear the nine decks
    for each GBSMCardRate row, GBSM_CardRate times: append GBSMCard to every one of the nine decks
        # each deck = the same multiset of Σ rate = 960 symbols
    for each row: smsm_CardRateArray[GBSMCard] = GBSM_CardRate / |deck 0|
    smsm_Shuffle(); smsm_CardDeckPoint = 0
    smsm_NPC = all GBSMNPC rows { MobInx (32 bytes), GBSMBet }
    read GBSMBetCoin.shn into smsm_BetCoin; 0 rows → "smsm_Load : GBSMBetCoin.shn read fail", ShineExit
    smsm_LocateDeck = [0, 1, …, 8]

smsm_Shuffle()                                                          @ FUN_0061fa10
    for each of the nine decks (n = size):
        for i in 0 … n−1:
            j = round(n · rand() / 32767.0)          # CRT rand() 0…32767; round to nearest (x87 default)
            if j < n: swap(deck[i], deck[j])         # j == n (rand() near 32767) → no swap
    # not a Fisher–Yates shuffle: positions 0 and n get half the weight of the others; the result is close to uniform

smsm_NPCData(char* mobInx) → GBSMBetType                                @ FUN_0061fac0
    first smsm_NPC entry whose 32-byte name equals mobInx (compared as 8 dwords, after strncpy 32) → its betype
    none → MAX_GBSMBETTYPE (3)

smsm_BettingAtOnce(GBSMBetType t) → u16                                 @ FUN_0061fc40
    first GBSMBetCoin row with GBSMBet == t → GBSMCoin; none (also t = 3) → 0

SlotMachineAnalyse (0xc0)                                               dtor @ FUN_00623570 (frees the vectors and sets)
    +0x00 set<u16> sma_GroupForCard[9]        # symbol → the group ids that contain it
    +0x90 vector<GBSMLine>   sma_LineMatch
    +0xa0 vector<GBSMAll>    sma_AllMatch
    +0xb0 vector<GBSMCenter> sma_PointMatch

sma_Load()                                                              @ FUN_006239b0
    clear the nine sets; for each GBSMGroup row: sma_GroupForCard[GBSMCard].insert(GBSM_GroupID)
        # 2016: symbols 0…4 and 8 → {own group}; 5, 6, 7 → {own group, 10}
    sma_LineMatch = GBSMLine rows, sma_AllMatch = GBSMAll rows, sma_PointMatch = GBSMCenter rows (file order)

SlotMachineJackPotRanking (0x28)
    +0x00 u8 smjpr_IsReq
    +0x04 vector<SlotMachineInfo {u32 JackPotPrice; vector<SLOTMACHINE_JackPotRank> JackPotRank}> smjpr_InfoArr   # per GBSMBetType
    +0x14 vector<GBSMJackpotRate> smjpr_JackPotRate
    +0x24 GBTaxRate* smjpr_TaxInfo

smjpr_Load()                                                            @ FUN_00624270
    smjpr_TaxInfo = g_TaxRate.cd_Find(GameType 26)
    none → "smjpr_Load : TaxInfo Load fail", ShineExit
    smjpr_JackPotRate = all GBSMJPRate rows
    # smjpr_InfoArr is filled from the GameDB answer 0xBCD6 (smjpr_RankingSet FUN_00625130, part 5); until then it is empty and
    # every jackpot function below returns 0 / does nothing
```

### 4.2 Symbol draw (`smsm_Action`)

The screen is `SLOTMACHINE_ScreenState { u8 Card[3][3] }` (row, column). The client and the line names use keypad numbering:
row 0 = keys 7 8 9 (top), row 1 = 4 5 6, row 2 = 1 2 3 (bottom); `Card[r][c]` = key (2 − r)·3 + c + 1.

```pseudo
smsm_Action(out STOPBUTTON_ACK* ack, GBSMBetType type, u16 unit, START_REQ* bet, char* god)      @ FUN_006228f0
    allLines = all eight 3-bit line counts of bet (§4.3) are non-zero
    if strlen(god) == 9:                                     # GM screen: player.sp_GodOfSlotMachine (vt 0xb58), Z11 §3.4
        for k in 0…8: v = god[k] − '0' (god[k] < 'A') or god[k] − 'A' + 10; v > 8 → 0
                      cell of key k+1 = v                    # chars 0‑2 → row 2, 3‑5 → row 1, 6‑8 → row 0
        return                                               # no jackpot roll, decks untouched
    jpRate = g_SlotMachineJackPotRanking.smjpr_JackPotRateCalc(type, unit)     # per million (§4.4)
    if allLines and RandomBox::rb_1000000() < jpRate:        # Well512 0…999 999 (Z28 FUN_0048dfb0)
        all nine cells = 8 (FiestaLogo); return              # the jackpot screen
    a = rndbox[9]; b = rndbox[9]; swap(smsm_LocateDeck[a], smsm_LocateDeck[b])       # rndbox: Z23 §8.6
    smsm_CardDeckPoint += 1
    if smsm_CardDeckPoint ≥ |deck 0|: smsm_CardDeckPoint = 0; smsm_Shuffle()
    all cells = 99
    for k in 0…8: cell number smsm_LocateDeck[k] (row = n / 3, column = n % 3) = smsm_CardDeck[k][smsm_CardDeckPoint]
    cells > 8 → 0
    # ack.nError is not written (the caller overwrites it, §4.5)
```

So every cell is drawn from its own shuffled 960-symbol deck at a common position that advances by one per spin of **any**
slot machine in the zone (sampling without replacement within a deck pass: after 960 spins every deck has given every symbol
exactly its weight). For a rebuild each cell is, to a very good approximation, an independent draw with P(symbol) =
`GBSM_CardRate / 960`: HPPotion and SPPotion 21.9 %, Honeying 12.5 %, Boogy and Pinky 11.5 %, each slime and the FiestaLogo 5.2 %.
The first spin after start-up reads position 1 (position 0 is only read after a reshuffle) *(inferred from the increment-then-read
order; no effect on the odds)*.

### 4.3 Patterns (`SlotMachineAnalyse`, `sms_LineRate`)

The bet (`PROTO_NC_GAMBLE_SLOTMACHINE_START_REQ { SLOTMACHINE_BettingLine betting }`, 4 bytes) holds a 3-bit unit count
(0…7) per line: byte 0 bits 0‑2 `_789`, bits 3‑5 `_456`; byte 1 `_123`, `_741`; byte 2 `_852`, `_963`; byte 3 `_753`, `_951`
(bits 6‑7 unused). `sms_LineRate(screen, r0, c0, dr, dc)` checks the three cells `Card[r0 + i·dr][c0 + i·dc]`, i = 0…2:

| Line | Keys | (r0, c0, dr, dc) | Through the centre |
|---|---|---|---|
| `_789` | top row | (0, 0, 0, 1) | |
| `_456` | middle row | (1, 0, 0, 1) | yes |
| `_123` | bottom row | (2, 0, 0, 1) | |
| `_741` | left column | (0, 0, 1, 0) | |
| `_852` | middle column | (0, 1, 1, 0) | yes |
| `_963` | right column | (0, 2, 1, 0) | |
| `_753` | diagonal 7‑5‑3 | (0, 0, 1, 1) | yes |
| `_951` | diagonal 9‑5‑1 | (0, 2, 1, −1) | yes |

```pseudo
sma_1LineMatch(screen, r0, c0, dr, dc) → GBSMLine*                      @ FUN_00621c10
    for each row L of sma_LineMatch in file order:
        if all three cells' symbols have L.GBSM_GroupID in sma_GroupForCard[symbol]
           and the number of distinct symbols among them == L.GBSM_Num: return L
    return null
sms_LineRate(screen, r0, c0, dr, dc) → int = sma_1LineMatch(…)?.GBSM_RatioLine or 0          @ FUN_00622800

sma_ScreenMatch(screen) → GBSMAll*            (profiler string "sma_AllMatch")             @ FUN_00621dd0
    first row A of sma_AllMatch for which all nine cells are in group A.GBSM_GroupID and the distinct-symbol count == A.GBSM_Num
    none → null
sma_CenterMatch(screen) → GBSMCenter*                                                     @ FUN_00621fa0
    first row C of sma_PointMatch with C.GBSM_GroupID in sma_GroupForCard[Card[1][1]]; none → null
```

With the 2016 tables: a line pays when its three symbols are equal (rate 20 / 20 / 30 / 40 / 50 / 35 / 45 / 55 / 100 for symbols
0…8), or all slimes of two kinds (20) or of three kinds (25); three equal slimes match their own group row first (35 / 45 / 55).
The whole screen pays when all nine symbols are equal (`GBSMAll`); the centre bonus pays when the centre is the FiestaLogo.

### 4.4 Jackpot pools (`SlotMachineJackPotRanking`)

One pool per machine type: `smjpr_InfoArr[type].JackPotPrice` (u32 coins), filled from the DB at start-up (part 5).

```pseudo
smjpr_JackpotAccumulate(type, bet)          ("…(DWRD machine, DWRD bet)")                  @ FUN_006201c0
    type < |smjpr_InfoArr|: InfoArr[type].JackPotPrice += bet           # u32, wraps
smjpr_JackpotAccumulate(type) → u32         ("…(DWRD machine)")                            @ FUN_00620250
    type < |smjpr_InfoArr| → InfoArr[type].JackPotPrice, else 0
smjpr_GetJackpotPrice(type, GBTaxRate* tax) → u32                                         @ FUN_006200c0
    type ≥ |smjpr_InfoArr| → 0
    pool = InfoArr[type].JackPotPrice; InfoArr[type].JackPotPrice = 0
    return (tax.GB_JPSaveRate · pool) / 1000                 # u32 product: wraps for pool > 42 949 672 at rate 100 (original bug) Z32-B16
    # 2016: the winner gets 10 % of the pool, the other 90 % vanish (the DB procedure does the same, §4.5) (inferred: intended)
smjpr_JackPotRateCalc(type, unit) → u32 (per million)                                     @ FUN_006220e0
    type ≥ |smjpr_InfoArr| → 0
    x = InfoArr[type].JackPotPrice / unit                    # pool in bet units (unit 0 cannot come with a valid type, Z32-B18)
    first GBSMJPRate row with MinCount ≤ x ≤ MaxCount → its GBSM_JPRate
    none → the largest GBSM_JPRate of all rows               # 2016: x > 9 999 999 → 10 000
```

2016 jackpot chance per spin with all eight lines bet: 0 while the pool is ≤ 100 000 units, then 0.01 %, 0.5 % (500 001…1 000 000
units) and 1 % above. With fewer than eight lines the jackpot is never rolled.

### 4.5 Stop button: payout and settlement request (`SMS_StopButton`, vt 0xe4)

Reached from `0xBCCE NC_GAMBLE_SLOTMACHINE_STOPBUTTON_REQ` (`sp_NC_GAMBLE_SLOTMACHINE_STOPBUTTON_REQ` FUN_0061e980, Z06 §5) on the
player's screen. Screen fields used: `+0x18 sms_BettingType`, `+0x1c u16 sms_BettingAtOnce` (coins per unit), `+0x20 sms_State`
(`SMS_READY` 0, `SMS_ROLLING` 1, `SMS_STOPPING` 2, `SMS_WAITDB` 3), `+0x30 sms_WinNumber`, `+0x34 sms_BettingInfo` (the START_REQ
bet), `+0x38 sms_ScreenInfo` (STOPBUTTON_ACK, 11 bytes), `+0x43 sms_WheelStop` (WHEELSTOP_ACK { u16 nError, u16 bet, u32 win,
SLOTMACHINE_WinState WinLine }, 10 bytes).

```pseudo
SMS_StopButton(p, out STOPBUTTON_ACK* ack) → code                       @ FUN_00625340
    if sms_State ≠ SMS_ROLLING: return 0x28D3
    smsm_Action(&tmp, sms_BettingType, sms_BettingAtOnce, &sms_BettingInfo, p.so_ply_GodOfSlotMachine())   # §4.2; vt 0xb58 FUN_0061ddf0
    sms_ScreenInfo = tmp                                     # nError: uninitialised stack word (never sent, see below)
    sms_WheelStop = {0}
    units = Σ of the eight line counts; lines = number of lines with count > 0
    stake = sms_BettingAtOnce · units
    win = 0; any = false
    if lines == 8 and (A = sma_ScreenMatch(screen)):
        win = A.GBSM_RatioAll · stake; WinLine.all = 1; any = true
        if A.GBSM_IsJP: WinLine.jackpot = 1
        # no line wins in this case
    else for each line in the order _123, _456, _789, _741, _852, _963, _753, _951 with count > 0:
        r = sms_LineRate(screen, line geometry §4.3)
        if r > 0: win += count · sms_BettingAtOnce · r; WinLine.<line> = 1; any = true
    if any of _456, _852, _753, _951 has count > 0 and (C = sma_CenterMatch(screen)):
        win += C.GBSM_RatioCenter · stake; WinLine.bonus = 1; sms_WinNumber += 1
    else if any: sms_WinNumber += 1
    tax = smjpr_TaxInfo                                      # GBTaxRate row 26
    if tax.GB_JPSave == GB_JP_BET: smjpr_JackpotAccumulate(sms_BettingType, stake)          # 2016: yes, the full stake
    if WinLine.jackpot:
        win += smjpr_GetJackpotPrice(sms_BettingType, tax)  # takes 10 % and empties the pool (§4.4)
        smjpr_JackPotRankingSet(sms_BettingType, p.name (vt 0x56c), win)                    # FUN_00625000, part 5
        p.so_ply_IBurstJackPot(u64 win)                      # vt 0xb54 FUN_00620410: map ← 0xBCDD (part 5)
        R = g_GBReward.cd_Find(26)
        if R and its item (ItemDataBox idb_2itemid(R.Item_INX)) exists:
            item = default attributes of that item (ItemAttributeClass vt 0x14), key = iti_mkregnum(id, kind 0xB, zone, world)
            GameDB ← 0x344D NC_ITEMDB_CREATEITEMLIST_REQ {   # sock2gameDB (the Character server), Z05 §9.2 / D03
                hdr { u16 clienthandle = p.handle, u32 charregistnumber = p.charNo (vt 0x344) },
                u32 owner = p.charNo, u16 lockindex = L.index (L = p.so_ply_GetInventoryLockList(), vt 0x7d4),
                u16 map = map id of p's map, u64 price = 0,
                PROTO_ITEM_CMD itemlist = ItemListMaker(2) with that one item }
            L.icl_IncIndex()
            # the packet-too-long assert text is copied from sp_KQReward
    win −= (tax.GB_TaxRate · win) / 1000                     # signed; 2016 slot tax 0 ‰; applied after the jackpot was added
    sms_WheelStop.bet = (u16) stake; sms_WheelStop.win = win
    if L == null: return 0x28D6                              # dead for players (ShinePlayer FUN_0055a1d0 returns a member) (original bug) Z32-B17
    GameDB ← 0xBCD3 NC_GAMBLE_SLOTMACHINE_DB_RESULT_REQ {    # 0x24 bytes
        hdr { u16 clienthandle = p.handle, u32 charregistnumber = p.charNo },
        u16 lockindex = L.index, u32 PlayerRegistNumber = p.charNo,
        char CardDisplay[10] = the nine symbols in key order 1…9 (row 2, row 1, row 0), each '0' + v (v > 9 would give 'A' + v,
                               never reached: v ≤ 8), then NUL,
        u8 IsJackPot = WinLine.jackpot, u32 JackPotAccumulate = smjpr_JackpotAccumulate(type)   # after a jackpot: 0 (just emptied)
        u16 BetUnit = sms_BettingAtOnce, u8 BetLine = stake / sms_BettingAtOnce (= units),
            # sms_BettingAtOnce = 0 when the dealer's MobInx is not in GBSMNPC: SlotMachineScreen::go_Init FUN_00620b00 stores
            # type 3 and unit 0 without refusing, SMS_Start's coin check then always passes, and this integer division
            # faults: a zone crash; data-dependent (the 24 MobInfo GB_SlotMachine_* NPCs of 2016 are all in GBSMNPC) (original bug) Z32-B18
        u16 nJackpotRate = tax.GB_JPSaveRate, u32 WinMoney = win }
    d = win − stake
    L.vt[0x70] icl_StoreGBCoin(L.index, |d|, d < 0 ? −1 : +1, 0)      # coin reservation (part 3 working notes; FUN_00489d90)
    L.icl_IncIndex()
    if win > stake: go_PlayerAction(p, 26, {0, 1, 2}, 3)     # vt 0x30, §2.3: a win motion (DAT_008711b0)
    elif win < stake: go_PlayerAction(p, 26, {3, 4, 5}, 3)   # a loss motion (DAT_008711a4); equal: none
    *ack = sms_ScreenInfo; sms_State = SMS_STOPPING
    return 0x28D2
```

The handler (Z06 §5) writes the returned code over `ack.nError` and sends `0xBCCF NC_GAMBLE_SLOTMACHINE_STOPBUTTON_ACK { u16 nError,
u8 screen[3][3] }` (11 bytes). On 0x28D3 / 0x28D6 / 0x28CD (object not a screen, base stub §2.1) `ack` was never written, so the
nine screen bytes are uninitialised stack (original bug) Z32-B19. The coins themselves change only when the GameDB answers
`0xBCD4` (`so_ply_SlotMachineDBResult`, part 5); the win numbers reach the client with `0xBCD1` (`SMS_WheelStop`, part 5).

Client (`MHDiceGameTask`, FUN_0071b010): only for nError 0x28D2 it reads the nine symbols in key order 1…9 (row 2 first) and
hands them to the slot window (`this+0x15c4`, FUN_0071c0f0); every other code is ignored without a message (none of the
0x28CD…0x28D6 codes has a client text in `client-error-codes.json`).

GameDB side (D03 §11, `fc_NC_GAMBLE_SLOTMACHINE_DB_RESULT_REQ` FUN_004251a0 → `usp_Gamble_setSlotMachineResult`): coins =
max(0, coins − BetUnit · BetLine + WinMoney); on IsJackPot it also adds `tGambleJackpot.nJackpotCoin · nJackpotRate / 1000` for
this BetUnit and empties that pool, else it adds the stake to it *(db-backup)*. The DB pool is a second pool (per bet unit) next
to the zone's in-memory pool (per machine type), and `WinMoney` already contains the zone's 10 % share: a jackpot is credited
twice in the DB, once in the zone's reservation (original bug) Z32-B15 *(db-backup: the 2016 procedure body is not available)*.

### 4.6 Payout table (what a rebuild needs)

For a spin with unit coin `u` (`GBSMBetCoin` of the machine type, 10 / 100 / 500), line counts `n_l` (0…7), `U = Σ n_l`, stake
`S = u · U`:

1. Screen: each cell an independent symbol with weight `GBSM_CardRate` (§4.2); if all eight lines are bet, first a jackpot roll
   with `smjpr_JackPotRateCalc` per million (§4.4) that forces nine FiestaLogos. A GM's 9-character `&godofslotmachine` string
   replaces both.
2. All eight lines bet and nine equal symbols: `win = RatioAll(symbol) · S` (200…1 000×), no line wins; FiestaLogo also sets the jackpot.
3. Otherwise `win = Σ_l n_l · u · RatioLine(line l)` (§4.3).
4. Centre bonus: a centre line bet (`_456`, `_852`, `_753`, `_951`) and the centre FiestaLogo: `win += 2 · S`.
5. Pool: `pool[type] += S` (`GB_JP_BET`); jackpot: `win += pool · 100 / 1000`, `pool = 0`, ranking, `0xBCDD`, `GBReward` row 26 item.
6. `win −= win · GB_TaxRate / 1000` (0 in 2016). Player net = `win − S`.

Expected return (2016 tables, independent cells, no jackpot): one line pays on average 0.718 × its stake; the centre bonus adds
2 × 5.21 % = 0.104 × S when a centre line is bet; all eight lines with one unit each → 0.822 × S *(computed from the tables)*.

Worked example: machine `GB_SlotMachine_02_03` (type 1, u = 100), bet `_456` = 2, `_123` = 1 → U = 3, S = 300 (7 lines unbet,
no jackpot roll). Screen keys 7 8 9 = (Pinky, HPPotion, Boogy), 4 5 6 = (QueenSlime, FiestaLogo, KingSlime), 1 2 3 = (SPPotion,
SPPotion, SPPotion). `_456` = Queen, Logo, King: Logo is not in group 10 → 0. `_123` = three SPPotion → group 2, rate 20 → 1 · 100 ·
20 = 2 000. Centre bonus: `_456` is a centre line and the centre is the FiestaLogo → + 2 · 300 = 600. win = 2 600, tax 0, pool[1]
+= 300. `0xBCD3` { CardDisplay "111687403" (keys 1…9: SP SP SP, Queen Logo King, Pinky HP Boogy), IsJackPot 0, BetUnit 100,
BetLine 3, nJackpotRate 100, WinMoney 2 600 }; reservation +2 300 (`icl_StoreGBCoin(+1)`); a win motion; `sms_WinNumber` + 1;
`0xBCCF { 0x28D2, screen }`; state STOPPING. Had all eight lines been bet with one unit each (S = 800), `_123` would pay 1 · 100 · 20
and the centre bonus 2 · 800, the other lines nothing: win 3 600.

### 4.7 Cluster and screen objects

```pseudo
SlotMachineCluster : CGambleObject (0xb8)          ctor @ FUN_0061dc90, dtor @ FUN_0061dd00 (base + the two screens, eh vector iterators)
    +0x00 CGambleObject base (§2.1)            # gamers: max 2; seats: 2
    +0x18 SlotMachineScreen smc_Screens[2]     # 0x50 each
SlotMachineScreen : CGambleObject (0x50)           ctor @ FUN_0061dc60 (base; sms_WaitTick = 0), dtor @ FUN_0061dc80
    +0x00 CGambleObject base                   # gamers: max 1 (the player at this screen); seats: 1
    +0x18 GBSMBetType sms_BettingType          +0x1c u16 sms_BettingAtOnce (coins per bet unit)
    +0x20 sms_State (SMS_READY 0, SMS_ROLLING 1, SMS_STOPPING 2; SMS_WAITDB 3 is never assigned)
    +0x24 u32 sms_WaitTick (idle limit, §4.10)  +0x28 u32 sms_NextJackpotInfo (tick)   +0x2c u32 sms_LastStart (tick)
    +0x30 u32 sms_WinNumber (winning spins since the join, §4.5)
    +0x34 START_REQ sms_BettingInfo            +0x38 STOPBUTTON_ACK sms_ScreenInfo   +0x43 WHEELSTOP_ACK sms_WheelStop (§4.5)
    # the other screen members are not set by the constructor: the clusters come from new[] in gom_Init (§2.4) and the members are
    # first written by go_Init (type, unit) and by the join (sms_PlayerReady: state, win number, jackpot tick)
```

Both classes use FUN_00618110 for slot 0x34 `go_Init_MaxPlayer(n)` (= `go_Init_PlayerObject(n)`, §2.2; COMDAT-shared). Slot 0x2c
("full check", §2.1): the cluster keeps the base [1], so the dealer NPC gets `STA_GBGAMEMEMBERFULL` (0x1A3) when both places are taken;
the screen returns 0 (FUN_004b8d20), so the screens never touch the NPC's abstate.

```pseudo
SlotMachineCluster::go_Init(npc)                     (vt 0x08, from gom_Init §2.4)                     @ FUN_0061dd70
    go_Init_NpcObject(npc) and go_Init_nWhoStandHnd(2) and vt[0x34](2) else 0
    for both screens: screen.vt[0x08] go_Init(npc) false → 0          # all three objects share the dealer NPC
    1
SlotMachineScreen::go_Init(npc)                                                                         @ FUN_00620b00
    npc null or go_Init_NpcObject(npc) false → 0
    m = npc.vt[0x70c]() (the NPC's MobInfo record); m null or *m == 0 → 0
    sms_BettingType   = smsm_NPCData(m.InxName)                    # §4.1: GBSMNPC row of the MobInx; none → 3 (no refusal, Z32-B18)
    sms_BettingAtOnce = smsm_BettingAtOnce(sms_BettingType)        # GBSMBetCoin: 10 / 100 / 500; type 3 → 0
    go_Init_nWhoStandHnd(1) and vt[0x34](1) → 1, else 0
SlotMachineCluster::go_Init_MaxPlayer(n) = SlotMachineScreen's   go_Init_PlayerObject(n) ≠ 0          @ FUN_00618110
SlotMachineCluster::go_FindSubGambleObject(charNo)   (vt 0x28)                                         @ FUN_0061eec0
    the first screen whose gamer list holds charNo (go_Find_Player, §2.2) → that screen, else null
SlotMachineCluster::go_Routine()                     (vt 0x20, from gom_Routine every main-loop pass)  @ FUN_0061f300
    for both screens: screen.vt[0x20] go_Routine()                 # §4.10
```

The seat arrays (`go_nWhoStandHnd`, 2 seats on the cluster, 1 per screen) are allocated and never written by any slot-machine code
either: the join's seat check only tests `seat < 2` (`go_CanWhereStand`, §2.2), and two players may ask for the same seat. This
confirms Z32-B2 for the slot machines (no writer of the seat array exists in the zone).

### 4.8 Joining, leaving and unmarking

The handlers are Z06 §5 (`sp_NC_GAMBLE_SLOTMACHINE_GAME_JOIN_REQ` FUN_0061e400, `…_GAME_LEAVE_REQ` FUN_0061e660); the object side:

```pseudo
0xBCC8 NC_GAMBLE_SLOTMACHINE_GAME_JOIN_REQ { u16 npc, u8 seat, u8 direction }           (summary of Z06 §5)  @ FUN_0061e400
    answer 0xBCC9 { u16 BettingUnit, u16 nError } pre-set to nError 0x28C0
    p.so_Field (p+0x7a) null → 0x28C2; L.icl_IsAnyLock (lock list vt 0x10) → 0x28C3; p in any gamble (vt 0xb1c) → 0x28C1
    o = gom_GetGambleObject(npc) (by NPC handle, any gamble type); none or o has no NPC → 0x28C4
    distance²(p, NPC) > 1 000 000 → 0x28C5;  o.vt[0x10] go_CanEnter false → 0x28C6;  o.vt[0x18] go_CanWhereStand(seat) false → 0x28C7
    o.vt[0x00] go_Enter_Player(p) true → p.sp_Gamble_JoinType = 2 (vt 0xb28), sp_Gamble_DirectInfoBroadcastSet(direction) (0xBC1C),
        o.vt[0x24] go_SendGameInfo(p) (sends the JOIN_ACK, below); return
    else JoinType = 0, 0x28C1
    # error answers write only nError: BettingUnit (payload +0) is whatever the shared send buffer gpp held from the previous packet
    # (original bug) Z32-B25 (the client ignores every code except 0x28C0)
    # o is never checked to be a slot machine (vt 0x0c go_Get_GambleType): with the handle of a TaiSai dealer the player is added to
    # the TaiSai gamers (base go_Enter_Player, §2.2) with JoinType 2, and the TaiSai's go_SendGameInfo answers (0xBC65, §3.5). The
    # TaiSai broadcasts skip the player (they test JoinType 1, §3.3), the slot LEAVE finds no slot object (0x28CB), the TaiSai LEAVE
    # refuses (0x2623); the player holds a TaiSai place until logging out, and so_Unmark looks for a slot object, so the TaiSai keeps
    # the freed player's pointer as in Z32-B13 (original bug) Z32-B24. The TaiSai JOIN fails safely on a cluster: its vt 0x3c stub answers 0x2619.

SlotMachineCluster::go_Enter_Player(p)               (vt 0x00)                                          @ FUN_0061f0b0
    s = the first screen with no gamer (go_Get_EnterPlayerCnt == 0); none → 0
    s.vt[0x00] go_Enter_Player(p) false → 0                      # only this first free screen is tried
    base CGambleObject::go_Enter_Player(cluster, p) (§2.2: the cluster's own gamer list; "full" abstate on the NPC at 2) → 1
    else s.vt[0x04] go_Out_Player(p); 0
SlotMachineScreen::go_Enter_Player(p)                (vt 0x00)                                          @ FUN_00620d00
    sms_WaitTick == 0 and GBBanTime row GameType 26 exists (SHND::g_BanTime, GBBanGame): sms_WaitTick = GB_BanTime · 10
        # computed once per screen; the 2016 row: GB_Ban GB_BAN_NO_PLAY (0), GB_BanTime 300 000 → 3 000 000 ticks (§4.10)
    sms_LastStart = now
    return base go_Enter_Player(screen, p)                        # max 1 gamer
SlotMachineCluster::go_SendGameInfo(p)               (vt 0x24)                                          @ FUN_00620b80
    p null → return 0x28C1 (nothing sent)
    for both screens: s.sms_PlayerReady(p, &ack) true → stop
    found → p ← 0xBCC9 NC_GAMBLE_SLOTMACHINE_GAME_JOIN_ACK { u16 BettingUnit = s.sms_BettingAtOnce, u16 nError = 0x28C0 }
    none  → p ← 0xBCC9 { BettingUnit not written (stale gpp bytes, Z32-B25), nError = 0x28D9 }      # not reached after a successful enter
    return 0x28C0                                                  # the assert text names "CGambleDiceTaiSaiObject::sp_NC_…_JOIN_REQ"
SlotMachineScreen::sms_PlayerReady(p, ack)                                                              @ FUN_0061efc0
    p (by charNo, vt 0x344) not this screen's gamer → 0
    sms_State = SMS_READY; sms_WinNumber = 0; sms_NextJackpotInfo = now (the first 0xBCD8 goes out on the next routine pass)
    ack.BettingUnit = sms_BettingAtOnce; 1
```

Client (`MHDiceGameTask::Recv_NC_GAMBLE_SLOTMACHINE_GAME_JOIN_ACK` FUN_0071b370): any nError other than 0x28C0 is ignored without a
message. On 0x28C0 it opens the slot window (`this+0x15c4`), stores `BettingUnit` at window +0x31c, `SlotMachineWin::InitMachine`
(FUN_0071f3d0), shows the coin count, sets its own state, plays `GB_SlotMachine.mp3`. None of 0x28C0…0x28D9 has a client text.

```pseudo
0xBCCA NC_GAMBLE_SLOTMACHINE_GAME_LEAVE_REQ {}                                                           @ FUN_0061e660
    answer 0xBCCB NC_GAMBLE_SLOTMACHINE_GAME_LEAVE_ACK { u16 nError }
    p.so_Field null → 0x28C9;  L.icl_IsAnyLock → 0x28CA (a settlement is pending, §4.9);  p not in a slot machine (vt 0xb20(2)) → 0x28CB
    o = gom_FindGambleObject(p.charNo, GBT_SLOTMACHINE); none → 0x28CB
    p.sp_Gamble_JoinType = 0 (vt 0xb28); o.vt[0x04] go_Out_Player(p); answer 0x28C8   # the result of go_Out_Player is not looked at
    # no state check: leaving in ROLLING drops the spin; nothing was charged yet (coins move only from the stop button on, §4.5)
SlotMachineCluster::go_Out_Player(p)                 (vt 0x04)                                          @ FUN_0061f1d0
    base CGambleObject::go_Out_Player(cluster, p) (§2.2; removes the NPC's "full" abstate) false → 0
    the first screen whose gamer 0 has p's zone handle → s.vt[0x04] (base go_Out_Player) → 1;  none → 0
    # the screen keeps sms_State, sms_BettingInfo, sms_WheelStop; the next join resets the state (sms_PlayerReady)
SlotMachineCluster::go_PlayerUnmarking(p)            (vt 0xd8, from ShinePlayer::so_Unmark §3.11)       @ FUN_0061f3b0
    vt[0x04] go_Out_Player(p); then for both screens: s.vt[0xd8](p)
SlotMachineScreen::go_PlayerUnmarking(p)             (vt 0xd8)                                          @ FUN_0061f480
    p (by charNo) is this screen's gamer → vt[0x04] go_Out_Player(p)   # after the cluster's call above: never true (redundant)
```

A player who logs out at a slot machine is simply removed (no logout gate: `so_Gamble_IsCanSessionCloseing` tests only TaiSai,
§3.11). A pending settlement is not lost: the GameDB has already booked the coins (§4.5), and the answer finds no player (§4.9).

### 4.9 Spin state machine: start, settlement answer, wheel stop

```
READY ──0xBCCC START (0x28CF)──▶ ROLLING ──0xBCCE STOPBUTTON (0x28D2, §4.5)──▶ STOPPING ──0xBCD0 WHEELSTOP (0x28D4)──▶ READY
                                                         GameDB 0xBCD4 (while STOPPING): apply / drop the coin reservation, state kept
```

```pseudo
SlotMachineScreen::SMS_Start(p, START_REQ req)       (vt 0xdc; from 0xBCCC FUN_0061e870, Z06 §5)        @ FUN_0061f540
    sms_State ≠ SMS_READY → 0x28D0
    coins = p.vt[0xb04]() (u64)
    coins < 2^32 and (u32) coins < sms_BettingAtOnce · Σ the eight line counts of req → 0x28D1
    sms_BettingInfo = req.betting; sms_LastStart = now; sms_State = SMS_ROLLING
    return 0x28CF                                    # the handler answers 0xBCCD NC_GAMBLE_SLOTMACHINE_START_ACK { u16 nError }
    # no coin is reserved here; the coins are only checked. A start with zero units passes too (stake 0, §4.5)
```

Client (`Recv_NC_GAMBLE_SLOTMACHINE_START_ACK` FUN_0071afd0 → `SlotMachineWin::Spin` FUN_0071c010): only while the window waits for
a start answer (window state 2): 0x28CF → spin the reels (state 3, sound 0x3b); any other code → back to state 1. In every other window
state the packet is ignored, which is why the settlement answer below can reuse this opcode *(inferred)*.

```pseudo
GameDB 0xBCD4 NC_GAMBLE_SLOTMACHINE_DB_RESULT_ACK { hdr { u16 clienthandle, u32 charregistnumber }, u16 lockindex, u16 nError }
                                                     (GameDBSession, 10 bytes; D03 §11)                 @ FUN_00620330
    p = som_GetObject(clienthandle); p null, closing (vt 0x300) or p.charNo ≠ charregistnumber → dropped
    p.vt[0xb50] so_ply_SlotMachineDBResult(ack)
ShinePlayer::so_ply_SlotMachineDBResult(ack)                                                             @ FUN_00620560
    (saves and restores the shared send buffer around the call)
    o = gom_FindGambleObject(p.charNo, GBT_SLOTMACHINE); s = o.vt[0x28] go_FindSubGambleObject(p.charNo)
    o or s null → code = 0x28CE
    else code = s.vt[0xe0](p, ack)                   # below
    p ← 0xBCCD NC_GAMBLE_SLOTMACHINE_START_ACK { u16 nError = code }
SlotMachineScreen::SMS_StopButton(p, DB_RESULT_ACK ack, …)   (vt 0xe0; PDB name, the DB-answer overload) @ FUN_0061f6e0
    sms_State ≠ SMS_STOPPING → 0x28D7
    sms_State = SMS_STOPPING                          # unchanged
    ack.nError ∈ {0x28D8, 0x2900} (the Character server sends 0x2900 for success, D03 §11):
        L.icl_Apply_N_Free(p, ack.lockindex, 0)  (lock list vt 0x1c, Z05 §1.3): the CoinChange releaser books the coin difference
            and tells the client (part 3 notes: icr_Apply FUN_00489be0, 0xBC04)
        return 0x28CF
    else: L.icl_Free(ack.lockindex) (vt 0x28): reservation dropped, coins unchanged; return ack.nError (0x2901…0x2906, D03 §11)
```

(original bug) Z32-B20: the reservation is released only on this path. When the answer finds the screen in another state (the client
sent `0xBCD0` before the GameDB answered: the screen is READY, code 0x28D7) or finds no screen (code 0x28CE), the lock index is
neither applied nor freed. The GameDB has booked the coins, the zone's coin count stays old, and the pending lock makes every later
`icl_IsAnyLock` true: the player can no longer leave the machine (0x28CA) or join a game (0x28C3) until the next login *(inferred:
the lock list is per session)*. Normal clients send `0xBCD0` only after the reel animation, long after the answer.

```pseudo
0xBCD0 NC_GAMBLE_SLOTMACHINE_WHEELSTOP_REQ {}                                                            @ FUN_0061eaf0
    s = the player's screen (gom_FindGambleObject(charNo, 2), vt 0x28); none → so_SendErrorCode(0x2F, 0xD1, 0x28CE) = 0xBCD1 { 0x28CE }
    ack = {0}; code = s.vt[0xec](p, &ack)
    p ← 0xBCD1 NC_GAMBLE_SLOTMACHINE_WHEELSTOP_ACK { u16 nError = code, u16 bet, u32 win, SLOTMACHINE_WinState WinLine }   (10 bytes)
SlotMachineScreen::SMS_WheelStop(p, ack)             ("SMS_WheelStop3", vt 0xec)                        @ FUN_0061f930
    sms_State ≠ SMS_STOPPING → 0x28D7 (ack stays zero)
    ack = sms_WheelStop (bet = stake, win = payout after tax, WinLine bits; §4.5); sms_State = SMS_READY; 0x28D4
SlotMachineScreen::SMS_WheelStop(p)                  ("SMS_WheelStop2", vt 0xe8)                        @ FUN_0061f8c0
    sms_State = SMS_READY; 0x28D4                    # no caller found (no call through vt 0xe8 in the zone)
```

`SLOTMACHINE_WinState` (2 bytes, *pdb2016*): byte 0 bits 0…7 = lines `_789`, `_456`, `_123`, `_741`, `_852`, `_963`, `_753`, `_951`;
byte 1 bit 0 `all`, bit 1 `bonus` (centre), bit 2 `jackpot`. Client (`Recv_…_WHEELSTOP_ACK` FUN_0071b090): only 0x28D4 →
`SlotMachineWin::WheelStop` (FUN_0071c480): stores `WinLine` and `win` (as a u64 with high word 0) and counts the coin display up by
`win`; `bet` is not read.

### 4.10 Screen routine: idle kick and jackpot display

```pseudo
SlotMachineScreen::go_Routine()                      (vt 0x20, every main-loop pass via the cluster)    @ FUN_00620de0
    no gamer → return;  p = gamer 0
    idle = now − sms_LastStart                       # since the join or the last START (ticks of 0.1 s)
    if idle > sms_WaitTick and p:
        p.vt[0x304] so_SendProtocol(0x2F, 0xD2) = 0xBCD2 NC_GAMBLE_SLOTMACHINE_STAND_UP_CMD {}   # every pass (Z06-B19)
        if idle > sms_WaitTick + 600: p.vt[0x5fc] so_banning(0) (Z01 §8.3: disconnected); return
    if sms_NextJackpotInfo < now:                    # also reached in the 60 s between the stand-up and the kick
        smjpr_SendJackPotPriceTo(p); sms_NextJackpotInfo = now + 100            # every 10 s
SlotMachineJackPotRanking::smjpr_SendJackPotPriceTo(p)                                                   @ FUN_0061fe80
    p ← 0xBCD8 NC_GAMBLE_SLOTMACHINE_JACKPOTINFO_CMD (smjpr_PacketMake_JackPotPrice), size 1 + 6·JackPotNum
smjpr_PacketMake_JackPotPrice(cmd)                                                                        @ FUN_0061fd70
    JackPotNum = 0; smjpr_TaxInfo null → done (never: smjpr_Load exits without it)
    for type 0, 1, 2: JackPotList[n++] = { u16 BettingUnit = smsm_BettingAtOnce(type),
                                           u32 JackpotPrice = smjpr_TaxInfo.GB_JPSaveRate · InfoArr[type].JackPotPrice / 1000 }
    # = what a jackpot would pay now (10 % of the pool, §4.4), with the same u32 wrap as Z32-B16
    # reads InfoArr[0…2] without checking its size: before the GameDB link (smjpr_RankingReq, §4.11) the vector is empty and this
    # reads through a null pointer (original bug) Z32-B22 (unreachable in practice *(inferred)*: a player reaches a map only after the
    # DB servers are linked)
```

The 2016 idle limit: `GBBanTime.shn` row 26 `GB_BanTime` 300 000 ·10 = 3 000 000 ticks = 300 000 s ≈ 83 h, then 60 s of stand-up
commands, then the disconnect. In practice nobody is ever kicked. The ×10 converts seconds to ticks; read as milliseconds (5 min) the
value would need ÷100 (original bug) Z32-B26 *(intent inferred: the column is used nowhere else)*.

Client: `STAND_UP_CMD` (FUN_0071b0c0) does nothing; `JACKPOTINFO_CMD` (FUN_0071b0d0 → `SlotMachineWin::SetJackPotCoin` FUN_0071c3c0)
writes each `JackpotPrice` as `%d` into one of three labels chosen by `BettingUnit` 10, 100 or 500 (hard-coded in the client; other
units are not shown).

### 4.11 Jackpot pools from the DB, rankings, jackpot broadcast

```pseudo
GameDBSession::gds_NC_MISC_S2SCONNECTION_ACK (the GameDB link is up)                                   @ FUN_00468880
    sock2gameDB verification; smjpr_RankingReq()
SlotMachineJackPotRanking::smjpr_RankingReq()                                                            @ FUN_00626220
    smjpr_IsReq set → return                          # once per zone process: a GameDB reconnect asks nothing
    smjpr_IsReq = 1
    GameDB ← 0xBCD5 NC_GAMBLE_SLOTMACHINE_DB_GAMEINFO_REQ { u8 nSlotMachineNum = 3,
                 { u8 Machine = t, u16 BetUnits = smsm_BettingAtOnce(t) } for t = 0, 1, 2 }      # 10 bytes, no header; D03 §11
    smjpr_InfoArr.resize(3); every entry: JackPotPrice = 0, JackPotRank cleared
GameDB 0xBCD6 NC_GAMBLE_SLOTMACHINE_DB_GAMEINFO_ACK { u8 Machine, u16 nError, u32 JackPotPrice, u8 RankNumber,
                 SLOTMACHINE_JackPotRank RankList[RankNumber] }   (GameDBSession FUN_00625d30, no header) → smjpr_RankingSet
SlotMachineJackPotRanking::smjpr_RankingSet(ack)                                                         @ FUN_00625130
    nError ≠ 0x2940 → assert "…smjpr_RankingSet : Error occur", ShineExit
    Machine ≥ |InfoArr| → assert "…Invalid Machine", ShineExit
    InfoArr[Machine].JackPotPrice = JackPotPrice     # the zone pool starts from the DB pool of that BetUnit
    append the RankNumber entries to InfoArr[Machine].JackPotRank (no sort, no limit)
```

(original bug) Z32-B23: the Character server answers 0x2941 (jackpot query failed) or 0x2942 (ranking query failed) per machine (D03
§11), and either one stops the zone at once (`ShineExit`). D03-B22's trailing bytes are harmless here (only `RankNumber` entries are read).

```pseudo
smjpr_JackPotRankingSet(type, Name5 name, u32 win)   (from SMS_StopButton on a jackpot, §4.5)          @ FUN_00625000
    type ≥ |InfoArr| → nothing
    InfoArr[type].JackPotRank.push_back({ name, money = win })   # win = line / all wins + jackpot share, before the tax
    sort InfoArr[type].JackPotRank by money, descending (std::sort: introsort, ties in any order;
        FUN_006230d0 with FUN_00621600 / 006216f0 / 00622280 / 00622720; vector growth FUN_00624460 / FUN_00623690)
    # the list is never trimmed: it grows by one entry per jackpot for the life of the zone

0xBCD9 NC_GAMBLE_SLOTMACHINE_JACKPOTRANKING_REQ {}   (handler's profiler text says WHEELSTOP_REQ)        @ FUN_0061ec60
    s = the player's screen; none → ListLen = 0
    else s.vt[0xf0] go_SMS_PacketMake_JackpotRank(ack) (FUN_00620ef0): ListLen = 0; smjpr_PacketMake(ack, s.sms_BettingType)
    p ← 0xBCDA NC_GAMBLE_SLOTMACHINE_JACKPOTRANKING_ACK { u8 ListLen, SLOTMACHINE_JackPotRank RankList[ListLen] }   size 1 + 0x18·n
smjpr_PacketMake(ack, type)                                                                               @ FUN_0061ff80
    ListLen = 0; type ≥ |InfoArr| → done
    copy the entries of InfoArr[type].JackPotRank in order; the "at most 50" test reads ack.ListLen, which is only written after the
    loop (still 0), so it never stops the copy; ListLen = (u8) count
    # (original bug) Z32-B21: with 51…255 entries the answer carries them all; from 256 on ListLen wraps and the packet length
    # (1 + 0x18·ListLen) cuts the list to count mod 256 entries; past 341 entries the copy runs beyond the send buffer *(inferred:
    # gpp is the 0x2000-byte buffer the other senders save and restore)*. Intended: the first 50 (the win ranking below tests its
    # counter correctly)

0xBCDB NC_GAMBLE_SLOTMACHINE_WINRANKING_REQ {}                                                            @ FUN_0061ed90
    s = the player's screen; none → no answer
    s.vt[0xf4] go_SMS_PacketMake_WintRank(ack); p ← 0xBCDC NC_GAMBLE_SLOTMACHINE_WINRANKING_ACK { u8 ListLen, SLOTMACHINE_JackPotRank
        RankList[ListLen] }  size 1 + 0x18·n
SlotMachineScreen::go_SMS_PacketMake_WintRank(ack)   (vt 0xf4)                                           @ FUN_00624520
    ListLen = 0; n = gom_GetGambleObjectMaxCnt(GBT_SLOTMACHINE); n == 0 → done
    wincollect (function-static vector) = []
    for every cluster i < n: cluster.vt[0xf8] go_SMC_WinRank(&wincollect, sms_BettingType)
    sort wincollect by money, descending (std::sort); copy the first min(count, 50); ListLen = that number
SlotMachineCluster::go_SMC_WinRank(list, type)       (vt 0xf8)                                           @ FUN_00625280
    for both screens: SMS_WinRank(list, type)
SlotMachineScreen::SMS_WinRank(list, type)                                                               @ FUN_00624710
    type == sms_BettingType and the screen has a gamer p: list.push_back({ name = p.vt[0x56c] (Name5), money = sms_WinNumber })
```

The win ranking is live: only the players seated right now at machines of the requester's type in this zone, ranked by their number of
winning spins since they sat down. The jackpot ranking is the DB list (per BetUnit) plus this zone's jackpots since start, by amount.

```pseudo
ShinePlayer::so_ply_IBurstJackPot(u64 win)           (vt 0xb54, from SMS_StopButton; win sign-extended from i32)   @ FUN_00620410
    every player in p's map (so_AllInMap, including p) ← 0xBCDD NC_GAMBLE_SLOTMACHINE_SOMEONE_GET_JACKPOT_CMD {
        Name5 charid = p.vt[0x56c], u64 price = win }                 # 0x1C bytes
ShineObject::so_ply_GodOfSlotMachine() / ShinePlayer:: (vt 0xb58)      @ FUN_0061dde0 (global `tmp`) / FUN_0061ddf0 (sp_GodOfSlotMachine)
    the GM screen string handed to smsm_Action (§4.2; set by the GM command, Z11 §3.4)
```

Client: `JACKPOTRANKING_ACK` (FUN_0071b820) and `WINRANKING_ACK` (FUN_0071b790) open or raise the rank window (`GBSlotRankWin`,
`this+0x15cc`), switch to tab 1 / tab 2 and copy all `ListLen` entries (`UpdateJackpotRankList` FUN_0071bca0, `UpdateWinRankList`
FUN_0071bd40; no limit on the client side either). `SOMEONE_GET_JACKPOT_CMD` (FUN_0071b5b0) adds the system message text 0x7344739
"%s has won the Jackpot in the amount of %I64d …" with `charid` and `price`.

Corrections to Z06 §5 (done item; Z32 is the reference for these): `0xBCDD` is `{ Name5 charid, u64 price }` (0x1C, no trailing u32);
the "house cut" and "accumulation flag" read from "config DAT_14d712cc" are `smjpr_TaxInfo` (GBTaxRate row 26) `GB_TaxRate` and
`GB_JPSave` (§4.1, §4.5); `GBSMNPC` holds only `{ MobInx, GBSMBet }`; the settlement answer `0xBCD4` keeps the screen in STOPPING
(it is the wheel stop that returns to READY); the 0xBCD0 handler uses vt 0xec (`SMS_WheelStop3`), vt 0xe8 is not called.
