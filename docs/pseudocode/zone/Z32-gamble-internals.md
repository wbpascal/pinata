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

*(part 3)*

## 4. Slot machines (`SlotMachine::*`)

*(parts 3 and 4)*
