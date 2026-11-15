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

*(part 2)*

## 4. Slot machines (`SlotMachine::*`)

*(parts 3 and 4)*
