# Capture scenarios 14–44 (X02)

Continues the 13 scenarios of `docs/plan/capture-guide.md`. Those gave seven captures (login, idle, walk and
portals, shop and storage, combat with `&levelup` / `&linkto`); everything else in the reconstruction is read
from code only (`docs/review/confidence.md` §2: 1 882 sections rated medium or low). Each scenario here names the
claims it tests, the steps, and a **prediction**: the opcodes our documents expect, in order, with the field
values they give. A capture that differs from the prediction is a finding; P02 validates the captures as usual
(`docs/plan/items/P02.md`), then X02 is re-run to update the ratings.

State of this file: scenarios, GM setups and boundary values (X02 part 8). The SQL of the database setups
**S1–S14** and the table / config experiments **X1–X7** named below is written in X02 part 9 (§6 lists what each
must do). Until then a scenario marked "needs S…" cannot be run as written.

## 1. Conventions

- **Test server only.** Every scenario changes characters, some crash or disconnect on purpose (41, 42, 43).
  Test accounts only (`capture-guide.md` "Privacy").
- **Record the server links too.** Use the widened filter of capture batch 2 (`capture-validation.md` §7.1: the
  client ports plus the WM ↔ zone, zone ↔ Character server (9411) and GameLog links, loopback when all servers
  run on one PC). Half of every prediction is on those links; they are not encrypted.
- **Clients.** A = first test account, B = second account on a second client. "A and B on two zones" = A on a map
  of zone 0, B on a map another zone process hosts (`9Data/ServerInfo` map list; walk B through a gate first).
- **GM character.** A is a GM with admin level 100 (setup S1). `&` commands are typed into normal chat (Z11 §1.1).
  A GM login adds `0x10C6 NC_CHAR_ADMIN_LEVEL_INFORM_CMD {nAdminLevel}` to the login burst (Z11 §1.4): seeing it
  is the check that S1 worked.
- **Notes file** as in `capture-guide.md`: character names, levels, money before and after, item names and
  cells, the time of each step. For item scenarios also the `tItem` rows before and after
  (`docs/knowledge/D03.md` "For capture scenarios (X02)", 13 SQL checks that run alongside 20–22, 34, 35).
- **Notation.** `C→Z`, `Z→D` … as in `docs/pseudocode/README.md` §3.1 (C client, L Login, W WM, Z zone, D
  Character server, G GameLog, AL AccountLog). `{…}` = payload fields by our documents' names. "all Z" = the WM
  broadcast to every zone link. A section reference is the place the prediction was taken from.
- **Verdict words in "Disproved by":** a missing packet, another opcode, another order, or another value of a
  named field. A prediction that holds raises the section to high; one that fails becomes a correction row in
  `docs/knowledge/X02.md` §0.

Common GM setups (Z11 §2; all persistent unless noted):

| Need | Command | What to expect on the wire |
|---|---|---|
| level | `&levelup <n>` | per level `0x240C`, `0x240D`, `0x2446`, W `0x1074`, G `0x041E`, save (captured once, Z11 §7.3) |
| money | `&getmoney <n>` | D `0x3438`, C `0x1033`, `0x300A` (Z11 §7.4) |
| an item | `&makeitem <InxName> [-l<lot>] [-u<n>]` | D `0x3401` → `0x3402`, C `0x3001` (Z11 §4.3) |
| empty inventory | `&cleariv` | D `0x3459` → `0x345A`, C `0x3001` per cell (Z11 §4.3) |
| full HP / SP | `&fullpoint` | nothing (Z11 §4.4) |
| a skill | `&learnskill <skillId>` | D `0x4801` → `0x4802`, C `0x4804` (Z11 §4.4) |
| go to a map | `&linkto <map> [<x> <y>]` | `0x1809` or the zone change of README §3.11 (captured) |
| mobs | `&mobbreed <Mob> 1 10 n 5` | mob appear packets, `0x2011` "Mob : %d" (Z11 §4.2) |

`InxName` values come from `ItemInfo.shn` / `MobInfo.shn`
(`python3 -I tools/protocol-re/shn.py Files/Server/2016/9Data/Shine/ItemInfo.shn | rg -i <word>`).

## 2. Order of work

"Sections reached" = sections rated medium or low that name at least one opcode the scenario should put on the
wire and no capture holds yet (`docs/plan/status/X02-scen.py`, which also holds each scenario's opcode set). It is
a reach count, not a proof; the last column orders the work. Scenario 37 leads because its opcode set holds the
character-load blocks (`0x1008`–`0x1032`), which every login recorded with the server links delivers: run it
first for that reason, its own steps are short.

<!-- ORDER:begin -->
| # | Scenario | Needs | Minutes | Sections reached | Opcodes not yet captured | Sections per minute |
|---|---|---|---|---|---|---|
| 37 | Login side: idle heartbeat, refusals, character delete | DB / config setup | 6 | 205 | 125 | 34.2 |
| 14 | Second client in sight | 2 clients | 5 | 92 | 41 | 18.4 |
| 21 | Items II: drop, split, storage, use, shop | GM | 10 | 178 | 153 | 17.8 |
| 24 | Skills, abstates, stat points | GM, 2 clients for revive | 10 | 162 | 86 | 16.2 |
| 19 | Guild academy | 2 clients, GM | 6 | 89 | 151 | 14.8 |
| 36 | Block list, reports, options, megaphone | 2 clients | 5 | 72 | 101 | 14.4 |
| 18 | Guild life cycle and guild storage | 2 clients, GM | 12 | 149 | 255 | 12.4 |
| 23 | Quest: accept, kill, finish, give up; class change | GM | 8 | 93 | 56 | 11.6 |
| 17 | Friends and character titles | 2 clients | 4 | 45 | 41 | 11.2 |
| 27 | Wing stone and silver wing | GM | 5 | 55 | 15 | 11.0 |
| 40 | Gathering, production, item emotes, way-finding gate, tutorial, attendance | GM | 8 | 82 | 52 | 10.2 |
| 34 | Premium inventory, charged buffs | DB setup | 5 | 47 | 33 | 9.4 |
| 28 | Mini-house | 2 clients, GM | 10 | 78 | 94 | 7.8 |
| 39 | Combat extras: death penalty, PK, revive item, knock-back | 2 clients, GM | 8 | 54 | 29 | 6.8 |
| 35 | Dice table, gamble house, card collection | GM, mini-house | 10 | 66 | 151 | 6.6 |
| 15 | Party across two zones | 2 clients | 8 | 52 | 52 | 6.5 |
| 22 | Upgrade, gems, random options, endurance | GM | 8 | 49 | 58 | 6.1 |
| 16 | Raid | 2 clients (3 better) | 6 | 36 | 66 | 6.0 |
| 32 | GM command session | GM, 2 clients | 12 | 64 | 24 | 5.3 |
| 26 | Mounts and minimon | GM | 5 | 26 | 24 | 5.2 |
| 30 | Kingdom quest | 2 clients, GM, SHN / schedule setup | 20 | 103 | 99 | 5.2 |
| 38 | Session loss, kicks, back to character select | GM, 2 clients, process kill | 10 | 38 | 20 | 3.8 |
| 31 | Instance dungeon | 2 clients (party), GM | 10 | 37 | 36 | 3.7 |
| 25 | Pet | GM | 8 | 29 | 19 | 3.6 |
| 29 | Wedding | 2 clients, GM | 15 | 51 | 45 | 3.4 |
| 43 | OPTool listener (test tool) | test tool | 15 | 50 | 59 | 3.3 |
| 41 | Test client: crafted client packets | test client | 15 | 49 | 21 | 3.3 |
| 44 | Holy promise (mentor and pupil) | 2 clients, GM | 8 | 25 | 43 | 3.1 |
| 20 | Trade and booth | 2 clients | 10 | 28 | 66 | 2.8 |
| 42 | Races: drop menu, two money pick-ups, link with a dead WM session | 2 clients | 10 | 24 | 9 | 2.4 |
| 33 | Prison | GM, 2 clients | 8 | 18 | 18 | 2.2 |
<!-- ORDER:end -->

Sessions that fit together (same setup): **I** one client, GM: 37, 21, 22, 23, 24, 27, 40, 26, 25, 34, 32.
**II** two clients: 14, 17, 15, 16, 36, 44, 18, 19, 20, 39. **III** content with a longer setup: 28, 35, 29, 31,
30, 33, 38. **IV** tools: 42, 41, 43.

## 3. Scenarios

### 14. Second client in sight

- **Claims:** Z02 §2 movement relays, §4 emotes, §5 sight and brief info (`0x1C01`, `0x1C06`, `0x1C07`: in no
  capture), §3.2 shout, W04 §2.1 whisper, Z03 §3 `SOMEONE…` attack packets; Z11 §3.1 `&hide` / `&show` /
  `&dimension` (re-check V24).
- **Setup:** A (GM) and B stand out of sight of each other on one map, then B walks to A.
- **Steps:** (1) B walks into A's sight. (2) B walks, runs, jumps, sits, stands. (3) B plays an emote, then moves
  while it plays. (4) A shouts; B whispers A; A whispers a name that is not online. (5) B attacks a mob next to A
  with a swing and one skill. (6) A types `&hide`, `&show`, `&dimension 1`, `&dimension 0`. (7) B walks out of
  sight.
- **Prediction:** (1) Z→A `0x1C06 NC_BRIEFINFO_LOGINCHARACTER_CMD` for B's handle (and Z→B for A); if a client
  meets an unknown handle first it asks with `0x1C01 {nMyHnd, …}` and gets the brief info packet of that object
  (Z02 §5.1). (2) B's `0x2003` → A `0x2004`; `0x2005` → `0x2006`; `0x2024` → `0x2025`; sit / stand → A `0x2009
  NC_ACT_SOMEONECHANGEMODE_CMD`. (3) `0x2020` → A `0x2021`; when the client stops the emote it sends `0x2022 {emoticonid,
  emoticonframe}` → A `0x2023` (Z02 §4). (4) `0x201E` →
  `0x201F` to every client of the map instance, also out of sight (README §3.16); whisper C→W `0x200C` → target
  `0x200D`, sender `0x200F`, W→sender's zone `0x6006`; unknown name → sender `0x200E`. (5) A receives the
  `SOMEONE` forms (`0x2449`, `0x242E`, `0x2438`, `0x244F`) while B receives the own-attack forms captured before
  (Z03 §3, §5). (6) `&hide`: abstate inform for STA_GMHIDEMODE and B loses A (removal packet of Z02 §5);
  `&show`: abstate reset, **no appear broadcast from the command itself** (V24): B sees A again only through the
  next sight update; `&dimension 1`: A disappears for B and stays so; `&dimension 0`: A is **not** shown to B
  again until A changes map (the command does not re-enter the map, V24).
- **Disproved by:** a shout that stops at sight range; a `0x1C07` where we expect `0x1C06`; B seeing A right
  after `&dimension 0`; a `0x200F` for the unknown name.

### 15. Party across two zones

- **Claims:** W02 §2 (invite, accept, leave, kick, master), §4.1 map-login refresh and party-release maps
  (re-check W7), §8 zone broadcasts; Z08 §1.2–§1.3 zone mirror and status packets; W04 §2.3 party chat; W02 has
  no capture at all.
- **Setup:** A and B on one zone, no party. Find a party-release map with X2.
- **Steps:** (1) A invites B; B refuses. (2) A invites again; B accepts. (3) Both say something in party chat.
  (4) B walks through a gate to another zone and back. (5) A hands the master role to B. (6) B logs out and in
  again. (7) B kicks A. (8) Form the party again and walk A into a party-release map.
- **Prediction:** (1) C→W `0x3802 {target}`, W→B `0x3803 {mastername}`, B→W `0x3805` (no payload); what A receives
  is W02 §2.3's answer. (2) `0x3804` → W→all Z `0x3801 NC_PARTY_FUNDAMENTAL_CMD`, members `0x3807 {name,
  class, 0x4C1}`, B `0x3809` member list; each client then sends Z `0x3848` and gets `0x3832` / `0x3833` /
  `0x3849` for members **on its own zone only** (README §3.17 a). (3) C→W `0x2014` → both `0x2015`, sender
  `0x2016`, W→sender's Z `0x6006`. (4) the map change of README §3.11, then on W `0x180C`: member list, all Z
  `0x383C`, members `0x383D`; while B is on the other zone A gets no `0x3833` for B. (5) `0x382A` (W02 §2;
  Z08 §1.3). (6) logout: all Z `0x3846`, A `0x3847`; with only A online the party is **released**: all Z `0x381F`,
  A `0x381E` (README §3.17 c: ≤ 1 member online). (7) with three members: `0x3814` → all Z `0x3816`; with two the
  kick dissolves the party (`0x381F` / `0x381E`). (8) on W `0x180C` with `IsPartyRelease = 1` (offset 0x2e, W7)
  the WM makes A leave: all Z `0x380C`, `0x380B`, and the party of two dissolves.
- **Disproved by:** the party surviving step 6 with one member online; status packets for a member on another
  zone; `0x180C +0x2e` = 0 on the release map while the party still ends (then the map test
  `IsInPartyReleaseMap` is the cause, W7 says either).

### 16. Raid

- **Claims:** W02 §5 (all raid requests), §6 map login / logout, §8; Z08 §2; Z14 §5.2–§5.3 raid status packets.
- **Setup:** A is master of a party with B (scenario 15 step 2). A third account C makes the invitation step
  real; without it use steps 1, 4, 5 only.
- **Steps:** (1) A makes the raid. (2) A invites C; C accepts. (3) A moves B to another slot, makes B a
  sub-leader, changes the looter. (4) B changes map. (5) B leaves; A dismisses the raid.
- **Prediction:** (1) C→W `0xB001` → A `0xB002`, members `0xB003`, all Z `0xB004 NC_RAID_ZONE_MAKE_CMD`.
  (2) `0xB00C` → invitee; `0xB00F` → inviter `0xB011`, members `0xB012`, all Z `0xB013`. (3) requests in
  `0xB014`…`0xB03A`, zone broadcasts `0xB02A`, `0xB02F`, `0xB034`, `0xB039`, `0xB03E` (W02 §5.6–§5.11).
  (4) on W `0x180C`: all Z `0xB01D`. (5) leave: all Z `0xB017`; dismiss: all Z `0xB007` (README §3.18).
- **Disproved by:** a raid request answered on another opcode than its W02 § gives; no `0xB004` to a zone that
  holds no member (the broadcast is to all zones).

### 17. Friends and character titles

- **Claims:** W04 §5.2–§5.6 friends, §7 titles; Z08 §6, §7.2; D04 §3; the friend-point item path (`0x34BF` /
  `0x34C0`, Z05).
- **Steps:** (1) A sends B a friend request; B refuses. (2) again; B accepts. (3) B changes map, levels up
  (`&levelup` needs B as GM, else kill mobs), logs out and in. (4) A deletes B from the list. (5) A opens the
  title window and picks another title.
- **Prediction:** (1) C→W `0x5401` → A `0x5402`, B `0x5403`; refusal → A `0x540B`. (2) B→W `0x5404` → D `0x5410`
  → W `0x5411` → both `0x5408 NC_FRIEND_ADD_CMD`, both zones `0x6007 NC_CT_ADD_FRIEND_CMD`, `0x5402`. (3) map
  login → A `0x540D`; level → A `0x540F` (from Z→W `0x1074`); logout → `0x540A`; login → `0x5409`, B's own list
  `0x5407`, W→D `0x5414` (README §3.22). (4), (5): W04 §5.4, §7.
- **Disproved by:** `0x5408` before the DB answer `0x5411`; a `0x6007` to one zone only.

### 18. Guild life cycle and guild storage

- **Claims:** W03 §2 (make, invite, join, leave, kick, grade, notice), §3.6 chat, §4 session hooks, §9.5 storage
  grade, §10 zone mirror; Z08 §8; Z05 §7.2; D04 §6; D03 §5.2. W03 has no capture (63 sections medium or low).
- **Setup:** A level ≥ 20 with the guild fee (`&levelup`, `&getmoney`), B without a guild.
- **Steps:** (1) A creates a guild; repeat with a name that exists (second GM character) for the refusal.
  (2) A invites B; B refuses; again; B accepts. (3) guild chat from both. (4) A changes the notice and B's
  grade. (5) A opens the guild storage, deposits an item, B withdraws it (if the grade allows; else note the
  refusal). (6) B logs out and in. (7) A kicks B; invite again; B leaves. (8) A dismisses the guild.
- **Prediction:** (1) C→W `0x7405` → D `0x7458` → W `0x7459` → C `0x7406`, members `0x7436`, all Z `0x7448`
  (README §3.19); item and money refusals come from the Character server's answer. (2) `0x7409` → invitee;
  `0x740C` → D `0x7469` → W `0x746A` → members `0x7436`, all Z `0x744A`; a refused invitation is **not** reported
  to the inviter. (3) C→W `0x7473` → online members. (4) notice `0x7410`, grade `0x7416` (W03 §2.8, §2.9).
  (5) C→Z `0x7491` → D `0x3471` → Z `0x3473` → C `0x7492`, and in parallel Z→W `0x749E` → Z `0x749F`; withdraw
  C→Z `0x3026` → D `0x3474` → Z `0x3475` → C `0x3027`, ring `0x7493`, members on the origin zone and the next
  ring zone `0x7494` (not further: Z14-B10). (6) W03 §4 hooks on W `0x180C` / logout. (7) kick `0x740E` → D
  `0x7471` → W `0x7472`; leave `0x741C` → D `0x746B` → W `0x746C`; all Z `0x744B`. (8) `0x7407` → D; the zones
  get `0x7449` when the DB executes the deletion (W03 §2.3, §9.2: possibly not at once; note the time).
- **Disproved by:** a message to the inviter on B's refusal; `0x7494` reaching a guild member on a third zone;
  `0x7449` in the same second as `0x7407` if W03 §2.3 says the deletion is delayed.

### 19. Guild academy

- **Claims:** W03 §5–§6, Z08 §10, Z14 §4, D04 §9, D07; re-check E18 (`0x980D`).
- **Setup:** the guild of scenario 18 before step 8; B without a guild, level below the academy limit.
- **Steps:** (1) B opens the academy list and joins A's academy. (2) academy chat / notice by A. (3) B opens the
  academy member list. (4) B gains levels (`&levelup 1` three times). (5) A opens the academy reward storage,
  puts in an item, B takes it. (6) A takes B from the academy into the guild. (7) alternative end: B leaves.
- **Prediction:** (1)–(2) dept 38 requests → D → W → members, all Z `0x9876` / `0x9877` (README §3.20).
  (3) `0x980D` → `0x980E` with the list (B has an academy and no guild: the handler does not close, E18).
  (4) each `0x1074` → academy points and level-up records W ↔ D (`0x9855`), all Z `0x987A` / `0x987B`; D07
  reward items. (5) C→Z → D `0x3483`…`0x3488`, grade Z→W `0x9870` → `0x9871`, other zones by ring `0x9872`,
  `0x9874`. (6) `0x740C` → D `0x982F` → W `0x9830` → all Z `0x9879`, members `0x982E` (the 2016 client ignores
  it).
- **Disproved by:** a guild-join that uses `0x7469` for an academy member; `0x980E` with zeros for a member.

### 20. Trade and booth

- **Claims:** Z06 §1 trade (35 `NC_TRADE_*` opcodes, none captured), §2 booth (re-check V9); Z05 §9.10–§9.11;
  D03 §14 and `docs/knowledge/D03.md` checks 6 and 7; bug Z06-B15 (complete before the DB answer).
- **Setup:** A and B next to each other; A holds a stack of 10, a weapon and money; B has free cells.
- **Steps:** (1) A asks B to trade; B refuses. (2) again, accepted: A puts up the weapon and 100 money, B
  nothing; A takes the weapon off the board and puts it back; both lock and decide. (3) A starts a trade and
  walks away. (4) A opens a sell booth with the stack at a price; B visits, buys 3, then the remaining 7.
  (5) B opens a buy booth for the same item; A sells into it. (6) B tries to buy from A's booth with too little
  money (set B's money with S2).
- **Prediction:** (2) dept 19 requests zone-only (Z06 §1.2–§1.3); on the second `0x4C1F NC_TRADE_DECIDE_REQ`
  both clients get `0x4C24 NC_TRADE_TRADECOMPLETE_CMD` **before** Z→D `0x343B`; then D→Z `0x343D` per partner,
  cell changes `0x3001`, money `0x1033`; G `0x0460` / `0x0461` / `0x044A`. (3) the next board request finds the partner too
  far: `sp_tradebreak`, the cancel packets of Z06 §1 to both. (4) C→Z `0x680D` → D `0x3455` (split, 3 of 10) then `0x3453` (whole stack) →
  Z `0x3456 {nLotTraded = 0}`; the owner gets `0x680F`; **the buyer gets no `0x680E {0xA41}`** (V9: success is
  shown by the item arriving). (5) the same three DB requests from the buy-booth side (`StreetBoothBuy::sb_Trade`, Z06 §2.5).
  (6) buyer `0x680E` with the money code of Z06 §2.5 (one of 0xA42…0xA59).
- **Disproved by:** `0x343B` before `0x4C24`; a `0x680E {0xA41}`; a non-zero `nLotTraded`.

### 21. Items II: drop, split, storage, use, shop

- **Claims:** Z04 §2 (repurchase, capsule and item-money shops), §3 (drop, destroy, pick: re-checks Q23, E37),
  §4.2 split (V5), §5.2–§5.3 ring and minimon equip, §6 use, §7 storage, §12, §13 soul stones; Z05 §2–§6 and
  §10 (V4); D03 §1–§7. The shop capture covered buy, sell, equip and the storage open only.
- **Setup:** `&makeitem` a stackable consumable (lot 10), a second stack of the same item (lot 3), a ring, a
  non-stackable item; a filled inventory for step 7 (`&makeitem` until `0x3402` stops coming; silent when full).
- **Steps:** (1) split 4 off the stack into a free cell; merge them back; split onto the lot-3 stack. (2) drop
  the lot-3 stack; pick it up. (3) drop the non-stackable item; pick it up with B if a second client runs
  (else skip). (4) destroy an item (drag out + confirm destroy). (5) use one consumable; use the last one of a
  stack. (6) equip the ring, then a second ring. (7) with a full inventory: unequip the ring. (8) storage:
  deposit a stack, change the page, withdraw; deposit and withdraw money. (9) sell an item to an NPC and buy it
  back from the repurchase list. (10) buy HP and SP soul stones; use both; use one at full HP. (11) pick-up
  over the limit: with X3 (an item whose stack limit is 1 lower than a stack on the ground) or two stacks whose
  sum exceeds the item's maximum lot.
- **Prediction:** (1) C→Z `0x300D` → D `0x3434` → Z `0x3435` → C cell changes; merge `0x342E` → `0x342F`;
  split-and-merge `0x3431` → `0x3432`; refusals come as `0x300E {0x442…0x44C}` (a split of 0 or of the whole
  lot: `{0x442}`), and whether a success sends `0x300E` too is for the capture to show (Z04 §4.2 lists refusal
  codes only). (2) `0x3007` → D `0x3416
  DROPALL` → `0x3417` → `0x3008 {0x301}` and the ground object (created in the success answer, V2); pick
  `0x3009` → D `0x341C` (or `0x341F` when it merges) → `0x300A`. (3) B's pick-up as (2) on B's links; whether `0x301B
  NC_ITEM_PICKOTHER_ACK` appears is Z04 §3.3's rule. (4) D `0x346A NC_ITEMDB_ITEMBREAK_REQ` → `0x346B` (Z04 §3.2).
  (5) `0x3015` → D `0x343E USELOT` (lot > 1) or `0x343F USEALL` (last one) → `0x3440` → C `0x3016 {0x700}`;
  others in sight `0x3029` (Z05 §6.1). (6) `0x3010 NC_ITEM_RINGEQUIP_REQ` → the equip round trip of Z04 §5.1 (D `0x3410` → `0x3411`, C `0x3011`); the
  second ring goes to the other ring slot (Z04 §5.2).
  (7) `0x3012` → `0x3013 {0x2C2}` or `{0x2C4}`, never 0x2C1; client text "Failed to unequip the item." (V4).
  (8) `0x301C` → D `0x345F` → `0x3460` → `0x301D`; `0x3028` page; `0x301E` → D `0x3461` → `0x3462` → `0x301F`;
  storage rows `nStorageType = 6`, `nOwner = userNo` (D03 check 3). (9) `0x305B NC_ITEM_SELL_ITEM_LIST_CMD`
  after the sale; `0x3059` → D `0x34B9` / `0x34BB` → `0x305A`, `0x305D`. (10) `0x5001` / `0x5002` → D `0x3441`
  → `0x3442` → `0x5003` / `0x5004`; use → others `0x500B` / `0x500C`; a refused use → `0x5006` (empty) (Z04 §13).
  (11) `0x300A {0x34A}` and **no client text** (X02-B8; Q23: the client shows "Inventory is full." for 0x346
  only).
- **Disproved by:** a split refusal on another opcode than `0x300E`; the ground object appearing before `0x3417`; `0x3013
  {0x2C1}`; a text shown for 0x34A.

### 22. Upgrade, gems, random options, endurance

- **Claims:** Z04 §9 upgrades (all four requests and the roll §9.4), §10 gem sockets, §11 random options, §12
  endurance charge; Z05 §8; Z17 §4 costume weapon charges; `docs/knowledge/D03.md` checks 1, 2, 9.
- **Setup:** at an upgrade NPC: `&makeitem` a weapon, 20 upgrade stones of its tier, left / right protection
  stones, `&getmoney`. Note the weapon's `tItemOptions` rows.
- **Steps:** (1) upgrade until one success, one failure and (without protection) one downgrade or break are
  recorded. (2) one upgrade with left, right and middle stones. (3) boundary: an upgrade at the item's limit
  (`&makeitem … -u<max>`), and one with less money than the fee. (4) add a socket, add a gem, remove it.
  (5) change random options with an item; recover them. (6) charge a costume weapon's endurance.
- **Prediction:** (1) C→Z `0x3017 {equip, raw, raw_left, raw_right, gift_money, raw_middle}` → D `0x3447` with
  `change` ∈ {+1, +2, 0, −1, 100} and `destroyed` = 1 only with 100 (Z04 §9.1) → `0x3448` → C `0x3018 {err}`
  and `0x3001` for the weapon and every stone cell (each stone loses one). (3) at the limit `0x3018 {0x8CA}`,
  too little money `{0x8CB}`, both **without** a DB request. (4) `0x3044` → D `0x349A` → C `0x3045`; `0x3040` → D `0x3496` → C `0x3041`; `0x3042` → D `0x3498` → C `0x3043`
  (requests: Z04 §10; each DB answer is the request opcode + 1, Z05 §8). (5) `0x3053` → D `0x34B3` → C `0x3054`;
  recover `0x306B` → D `0x34CD` → C `0x306C`; `tItemOptions` types 503–519 change (D03 check 2). (6) `0x3035` →
  D `0x348D` (shield: `0x3064` → `0x34C6`) → C `0x3036`, `0x3037` (Z04 §12).
- **Disproved by:** a DB request on the two refusals of step 3; a `change` value outside the five; a stone
  cell that keeps its lot.

### 23. Quest: accept, kill, finish, give up; class change

- **Claims:** Z15 §3–§7 (script interpreter, diary, DONE round trip, codes), §5.8 worked trace; Z08 quest parts;
  D04 §1; `docs/knowledge/Z15.md`; Z07 class change (`0x1056`–`0x105A`, `0x305E`–`0x3060`).
- **Setup:** a new level-1 character (the first Roumen kill quest with an item reward), or S3 to put a chosen
  quest at its last step.
- **Steps:** (1) click the quest NPC, read the dialogue, accept. (2) kill the quest mobs one by one; pick up a
  quest drop if the quest has one. (3) relog in the middle. (4) return, choose a reward if offered, finish.
  (5) accept a second quest and give it up. (6) with S4 (level 20, class-change quest done): change class at
  the NPC.
- **Prediction:** (1) NPC click → Z→C `0x4401 NC_QUEST_SCRIPT_CMD_REQ {Cmd 2 SAY}`; each page C→Z `0x4402`;
  accept → D `0x4403 NC_QUEST_DB_SET_INFO_REQ` → `0x4404` → the diary record (Z15 §4, §6.1). (2) per kill one
  `0x440D NC_QUEST_NOTIFY_MOB_KILL_CMD {NumOfActionQuest, …}` for all quests the kill counts for (Z15 §6.2); we
  expect no DB message per kill *(inferred* from README §3.13: the diary is saved by `0x4005` in a full save*)*. (3) the zone save sends `0x4005`; at login the WM replays `0x1021` (doing), `0x10CD`
  (read), `0x10D6` (repeat). (4) as Z15 §5.8: `0x4401` / `0x4402`, Z→D `0x441A {NPCID, nQSC 10, QuestInfo
  (status 2), nMoney, nExp, lock, items}` → `0x441B {…, 0xB41}` → C `0x1033`, exp packets, `0x3001`, `0x4401
  {Cmd 10}`. (5) `0x4407` → D `0x4409` → `0x440A` → `0x4408`. (6) the class-change packets of Z07 (`0x1056`–`0x105A`; the WM cache gets `0x1058`, README §3.13).
- **Disproved by:** a DB write per kill; the reward arriving before `0x441B`; a result code other than 0xB41
  on success.

### 24. Skills, abstates, stat points

- **Claims:** Z03 §2 (assist), §5 skills (cast abort, field skills), §6 abstates (re-check C18: reset
  conditions), §7 revive, §9 learn / empower; Z23 §2 toggle skills, §4 empower; Z25; Z22; Z07 §2 stat points;
  Z12 recompute; D04 §2.
- **Setup:** A level 20+ with free stat and empower points (`&levelup 20` on a fresh character), money; a
  toggle skill and a buff with a movement reset condition (X4 lists the candidates from the misc-data table);
  B in sight for step 6.
- **Steps:** (1) learn a skill at the skill master. (2) put 1 empower point into it; reset empower with the
  item if at hand. (3) add 3 stat points to one stat; remove one with a restat item (else note the refusal).
  (4) start a long cast and move to abort it; cast a ground-target skill. (5) switch a toggle skill on, walk
  through a gate, switch it off. (6) take the buff, then walk / run / attack: one action per buff, noting which
  removes it. (7) get poisoned or burned by a mob (DOT). (8) die; B revives A with a revive skill; A accepts.
- **Prediction:** (1) `0x4801` → D → `0x4802` → C `0x4804` (Z03 §9). (2) `0x4811` → D `0x4812` → answer (Z23
  §4). (3) per point C→Z `0x105C {stat}` → D `0x10D1 {nMaxStat, nFreeStat[5] (target), nLockIndex, nItemNum 0}`
  → `0x10D2 {…, 0xAC1}` → C `0x105F {stat}`; the dedicated `0x105D` is never sent; a fourth point with none left
  → `0x1061 {0xAC2}` without a DB request (Z07 §2.2, §2.4). (4) abort C→Z `0x2444` → `0x2445`;
  field skill `0x2441` → `0x2450` / sight `0x2451`. (5) `0x245C NC_BAT_TOGGLESKILL_ON_CMD`; the link saves the
  abstate (`0x4007`) and the skill is **off** on the new map (`0x245D`, Z23 §2.4). (6) the abstate goes
  (`0x2428` / sight `0x1C18`) on exactly the action its `mdas_ResetCondition` names and on no other (C18).
  (7) `0x243C NC_BAT_DOTDAMAGE_CMD` per tick, `0x240E`. (8) dead player `0x4829` (empty; accept dialog), answer C→Z `0x482A`, sight `0x481F`; a refusal
  makes the zone send `0x482B`, which the client ignores (Z03 §7.3, Z03-B3).
- **Disproved by:** `0x105D` on the wire; a DB request for the refused fourth point; a buff that survives its
  reset action or falls to another one; a toggle skill still on after the link.

### 25. Pet

- **Claims:** Z13 §5–§6 (summon state machine, naming, tendency, re-summon), Z07 §9, D03 §13 (pet procedures,
  no source: check 10); re-checks P1 (`0xD411` on destroy) and Q11 (tendency, no animation).
- **Setup:** `&makeitem` a pet item (class 36); a gathering spot nearby; A is GM (`&getpetinfo`).
- **Steps:** (1) use the pet item (first summon); name the pet. (2) `&getpetinfo`; play an emote; gather once;
  `&getpetinfo` again. (3) walk through a gate to another zone with the pet out. (4) try to destroy the pet
  item while the pet is out. (5) use the item again (unsummon); relog; summon again.
- **Prediction:** (1) cast, then Z→D `0xD40D NC_PET_CREATE_DB_REQ` → `0xD40E` (RegNum) → `0xD40B` → `0xD40C`,
  sight `0x1C1C`; naming prompt `0xD405` → C `0xD407` → D `0xD403` → `0xD404` (Z13 §5.2, §5.5). (2) the two
  `0x2011` answers differ in stress / mind by the `TendencyModifyData` amounts for `PFC_S_DANCE` and
  `PFC_S_GATHER`; **no pet packet** is sent by the emote or the gather (Q11). (3) ZA→W `0x4033 {nCharNo,
  bDoResummon 1, xResummonCode = charNo + 0x1BEC48797BAFC8B0, nSummonSlot, nId, nRegNum}`; ZB gets `0xD412`, and
  after `0x1803` sends D `0xD40B` → `0xD40C`, no name prompt (Z13 §5.8; the captures hold `bDoResummon 0`
  only). (4) `0xD411 NC_PET_USE_ITEM_FAIL_ACK`, no `0x346A` (P1). (5) second summon: `0xD40B` only, no `0xD40D`.
- **Disproved by:** an animation packet tied to step 2; `0xD40D` on a re-summon; an item-break request in
  step 4.

### 26. Mounts and minimon

- **Claims:** Z13 §7–§9, Z07 §4, §8; Z02 §9. The captures hold one ride (Wooden Horse) without feeding.
- **Steps:** (1) ride on, wait for the hunger message, feed, ride off. (2) get hit by a mob while mounted.
  (3) equip a minimon (`0x3050`), switch the normal and the charged auto-use slots on and off; let HP drop below
  the threshold so that it uses a potion.
- **Prediction:** (1) `0xCC01` / `0x203F`, sight `0x2040`; `0x2046 NC_ACT_RIDE_HUNGRY_CMD`; `0x2044` feed;
  `0x2042` / sight `0x2043` (Z13 §7). (2) the dismount rule of Z13 §7 (`0x2041` on a refused ride). (3) C→Z
  `0x1124` / `0x1126` / `0x1128` / `0x112A` with their answers; the automatic use sends `0x112C` and the normal
  item-use packets (Z07 §4.1).
- **Disproved by:** an answer opcode other than the pair Z07 §4.1 gives for each request.

### 27. Wing stone and silver wing

- **Claims:** Z26 (all 20 sections: no silver wing in any capture); Z01 §7.2 wing save / fly (re-checks Q3,
  Q4, bug X02-B7); Z02 §6.6 server menu.
- **Setup:** `&makeitem` a sparrow wing, wing stones, a silver wing (item 2504 per Z26 §2).
- **Steps:** (1) save a location with the wing (`0x1814`); fly to it from another map (`0x1816`). (2) use the
  silver wing, choose "Save location". (3) go to another map; use it, choose "Fly", stand still to the cast
  end. (4) use it and cancel; use it, choose "Fly" and move during the cast. (5) use it on a map that forbids
  recall (a KQ or instance map, if reachable).
- **Prediction:** (1) `0x1814` → `0x1815` with 0x1141 … 0x1146 (Q3); `0x1816` → `0x1817`, cast, then `0x301A
  NC_ITEM_USECOMPLETE_CMD` (no body) and the map link (Q4). (2) `0x3015` → **no** `0x3016` yet → `0x3C01` menu;
  `0x3C02 {reply}` → D `0x3449 ITEMCHANGE_REQ`, C `0x3016 {0x700}`. (3) menu, then at the next routine tick the
  cool-down `0x4821`, at cast end `0x301A`, `0x3016 {0x700}`, then `0x1809` (same zone) or W `0x180D`; no
  `0x3029` to others (Z26 §2). (4) cancel → `0x3016 {0x700}`; moving during the cast: C→Z `0x3019 NC_ITEM_USEABORT_CMD`
  (Z04 §6.2) and the cast ends without `0x301A` and without a link (Z26 §3.2, §5.1). (5) `0x3016 {0x70F}` with `0x181D` and a `0x2011` notice.
- **Disproved by:** a `0x3016` straight after `0x3015`; a `0x3029` broadcast; a link without `0x301A`.

### 28. Mini-house

- **Claims:** Z07 §6 (60 uncaptured opcodes), Z13 §1–§3, Z05 §9.5 (re-check V3), D03 §8, Z02 §7 tents.
- **Setup:** A owns a mini-house item (`&makeitem`) and furniture; B next to A. For V3 the creation must fail:
  setup S5.
- **Steps:** (1) A pitches the tent (`0x2027`), folds it. (2) A activates the house (`0x8C01`), B sees it.
  (3) B visits from within 100 units, and once from further away. (4) A places a piece of furniture, moves it,
  removes it; uses a furniture emote. (5) A adds a portal, deletes it. (6) A changes the house settings, B gets
  thrown out; A closes the house. (7) with S5: A activates the house again.
- **Prediction:** (2) `0x8C01` → D `0x3467 NC_ITEMDB_CREATEMUSHROOM_REQ` → `0x3468` → build packets, sight
  `0x1C13` / `0x1C14` (Z13 §1). (3) `0x8C10` → the link into the house map (README §3.29); from too far: the
  refusal code of Z07 §6.5, no link. (4) `0x8C23` / `0x8C20` / `0x8C27` families with `0x8C21` to the visitors.
  (5) D dept 35 portal add / delete, answers `0x8C5A` family (Z07 §6.12). (7) D answers `0x3469`; **the client
  gets no packet at all** (V3).
- **Disproved by:** any client packet after `0x3469`; a visit accepted from beyond 100 units.

### 29. Wedding

- **Claims:** Z02 §10, Z07 §5 (status values with names of ours: re-check V13, not re-checked in code), Z13
  §4, D02 §11; Z11 §6.1 GM wedding commands.
- **Setup:** A and B, opposite gender, the wedding items of Z02 §10 (`&makeitem`); or the GM route:
  `&propose <B> <word>`, `&reserve`, `&enterready`, `&enter`, `&wedding` (Z11 §6.1) which run the same handlers.
- **Steps:** (1) A proposes to B; B refuses; again; B accepts. (2) reserve the hall; both enter; hold the
  ceremony with one guest if a third client exists. (3) relog both; A asks for partner info (`0x1093`) with B
  online on another zone, then with B offline. (4) A summons B (partner summon). (5) divorce by agreement:
  request, cancel, request, accept. (6) marry again (S6 resets the waiting time) and divorce by force.
- **Prediction:** (1) A→Z `0x204F NC_ACT_WEDDING_PROPOSEREQ_REQ` → Z→B `0x2050` → B→Z `0x2051` → Z→A `0x2052` (Z02 §10); on
  acceptance Z→D `0x1083` → `0x1084`;
  reload `0x1080` → `0x1082 NC_CHAR_WEDDINGDATA_CMD`; ring `0x10AB` to reload the partner on another zone.
  (2) `0x2053` → `0x2054`, G `0x065D`; entrance ring `0x2055`; `0x1091` → `0x1092`; G `0x065E`. (3) partner
  here or by ring `0x1095`; offline → D `0x1093` → Z `0x1094`, which the 2016 client has **no handler** for
  (README §3.29). (4) ring `0x10AA`. (5), (6) `0x1089`…`0x1090`, `0x205B`…`0x205E` (Z07 §5.2). After every step
  note `tMarriage` (S6 gives the SELECT): its `Main` / `Sub` values are what V13 needs named.
- **Disproved by:** a status value outside Z07 §5.1's table; a client reaction to `0x1094`.

### 30. Kingdom quest

- **Claims:** W04 §6 (schedule, lists, join, start), Z16 §2–§3 (element, entrance, reward; bugs Z16-B2, B4), Z09
  Lua layer (§14–§17, §24–§25: no scripted map in any capture), D04 §3 reward, Z15 Lua quest functions.
- **Setup:** X5 moves one `KingdomQuest.shn` row to start a few minutes after the server start with a minimum
  of 1–2 players. A and B on different zones. Shorter variant without the WM: `&kingdomquest <map> <script>`
  (Z11 §8.4: runs the script film only, no KQ element, no reward).
- **Steps:** (1) both open the KQ list; A joins, cancels, joins; B joins. (2) wait for the start; accept the
  entry prompt. (3) play to the end (or `&killallmob` as GM); note every script message and door. (4) collect
  the reward; get moved out. (5) second run: B is voted out (needs a third joiner) or leaves by logout.
- **Prediction:** WM→all Z `0x580D {PROTO_KQ_INFO}`; `0x580E {hquest, 0x981}` from the zone hosting the **last**
  listed map only (Z16-B2); C→W `0x581B` → list diffs `0x581C`…`0x581F`; `0x5805` → `0x5806`; cancel `0x5807` →
  all Z `0x583B`; countdown notice `0x580B`, `0x5825` each second for 10 s; W→all Z `0x580F {info, joiners}`;
  every zone links its own joiners at 0, 2, 5, 7, 10 s (G `0x0441`); C→Z `0x581A` links without a joiner check;
  during play `0x2079` script messages, `0x2082` / `0x2083` cinematics, mob and door packets (Z09 §14–§17); end
  Z→W `0x5810` → all Z `0x5811`; Z→D `0x5815 {fame, cen, item list}` → `0x5816` / `0x5817` (README §3.23).
- **Disproved by:** a `0x580E` from a zone that does not host the last map; a joiner on another zone who is not
  linked; a reward before `0x5816`.

### 31. Instance dungeon

- **Claims:** Z14 §1–§2, Z08 §5, W04 §13, Z09 instance scripts; bugs Z14-B8.
- **Setup:** A and B in a party at an instance gate (`&linkto`); a second gate hosted by another zone and a
  level-select gate (ModeIDGate) if the map list has them (X2 lists both).
- **Steps:** (1) enter through the gate; B follows. (2) both leave; wait 20 s; then A (leader) answers the
  "delete now" menu. (3) enter the level-select gate, choose a level. (4) dissolve the party while an instance
  exists.
- **Prediction:** (1) NPC menu → `so_LinkTo` (README §3.11); gate on another zone: ring `0xA404` first.
  (2) Z→W `0xA401` → members `0x0810 NC_MISC_RESTMINUTE_CMD {1, 300}`, all Z `0xA402`; "delete now" → ring
  `0x10B1`; players back → Z→W `0xA403` → members `0x0810 {1, 0}`. (3) Z→W `0xA408` → dest Z `0xA40A` → W
  `0xA40B` → origin `0xA409`; then `0xA40E` → `0xA410` → `0xA411` → `0xA40F` → link; client `0x182C
  NC_MAP_INDUN_LEVEL_VIEW_CMD`. (4) all Z `0x381F`: the instance is deleted on every zone (README §3.24).
- **Disproved by:** `0x0810` with other values than `{1, 300}` / `{1, 0}`; an instance that survives step 4.

### 32. GM command session

- **Claims:** Z11 (56 medium sections; only `&levelup` and `&linkto` are captured); Z01 §10 ring messages;
  re-checks C4 (`&captivate`), V25 (`&killallmob`), Z11-B15, B17, B31, B32.
- **Setup:** A = GM level 100 on zone 0; B on another zone; a quest with a kill count active on A (scenario 23
  step 1).
- **Steps, one command per line, 5 s apart:** `&pfind <B>`; `&psummon <B>`; `&distribute`; `&fieldbonus`;
  `&itembonus x 2000`; `&expbonus A 2000`; `&mobbreed <questMob> 3 10 n 5`; `&killallmob`; `&makeitem <item>`;
  `&cleariv`; `&getmoney 1000`; `&getmoney -1`; `&fullpoint`; `&immortal` (twice); `&captivate 1`, wait 10 s,
  `&captivate`; `&silence <B>` then B chats; `&HP`, `&SP`, `&gmtestmode` (arguments: Z11 §8.5); a GM chat colour change;
  `&speed 2000`, walk; `&kickout <B>` with B on A's zone, then with B on another zone.
- **Prediction:** `&pfind`: ring `0x1068` → `0x1069`, `0x2011` with the place, then A's map change to B.
  `&psummon`: ring `0x106A`, B's map change. `&expbonus A`: ring `0x1810` to every zone, **no effect on EXP**
  (Z11-B15); `&itembonus x`: local only, no ring. `&killallmob`: kill packets per mob with A as killer, drops,
  EXP and `0x440D` quest counts as for normal kills (V25, *(inferred)* until seen). `&getmoney -1`: money grows
  by 2³² − 1 (B31; D `0x3438`, `0x1033`), and the `0x300A` repeats the last pick message (B32). `&captivate 1`:
  `0x2011`, then A moves by mob AI without client input (C4). `&silence`: only the answer text; B's chat still
  arrives (B17). Chat colour: W `0x083D`. `&kickout` same zone: Z→W `0x0C1A {userNo, wmHandle, 0x68B}`, B `0x0C17
  {0x68B}`; other zone: ring `0x1068`, B is **not** kicked (Z11-B6).
- **Disproved by:** an EXP change after `&expbonus`; B silenced; B kicked across zones; no `0x440D` after
  `&killallmob` (then V25's "as for a kill" is wrong for quests).

### 33. Prison

- **Claims:** W04 §9, Z08 §12 (re-check V17), D04 §7, Z01 `EldPri` login; bugs W04-B24, B25, X01-B4.
- **Setup:** the GM request `0x7C01` needs the client's GM prison command if the 2016 client has one (C01), else
  the test client of scenario 41; the map-login path needs only S7 (prison minutes in the database).
- **Steps:** (1) S7 on B, B logs in. (2) B waits 3+ minutes; asks for the remaining time. (3) A changes the
  time, then releases B. (4) A imprisons B online (`0x7C01`), then an offline character by name.
- **Prediction:** (1) B's map login lands in `EldPri`; Z→C `0x7C05 {minutes·60}`; C→W `0x7C06` → D `0x7C0E` → W
  `0x7C0F` → C `0x7C07`. (2) W→D `0x7C0D` every 3 minutes; `0x7C04` answers with **milliseconds read as
  seconds** (W04-B24). (3) `0x7C09` → D `0x7C10` → W `0x7C11` → prisoner `0x7C03` or release, GM `0x7C0A`; the
  minutes and reason of the request are never copied (W04-B25); at 0: C `0x7C05 {0x0DA8}`, Z `0x7C12`.
  (4) W→B's Z `0x7C13` → Z→W `0x7C14 {…, err 0xDC0}` (0x178 bytes) → D `0x7C0B` → W `0x7C0C` → GM `0x7C02`;
  offline: D `0x7C0B` directly (README §3.27).
- **Disproved by:** a remaining time in step 2 that matches the wall clock; `0x7C14` shorter than 0x178 bytes.

### 34. Premium inventory, charged buffs

- **Claims:** Z04 §8, Z05 §7.4, D03 §5.4 and §9 (checks 5 and 13), W04 §11, Z08, Z24; bug D03-B10.
- **Setup:** S8 inserts charged-item rows for the test account (3 rows; then 600 rows for B10).
- **Steps:** (1) open the premium inventory; withdraw one item; use it if it is a buff item. (2) change map.
  (3) relog. (4) with 600 rows: open and page through the list.
- **Prediction:** (1) `0x3020` → D `0x3463` → `0x3464` → `0x3021`; `0x3022` → D `0x3465` → `0x3466` → `0x3023`,
  G `0x04BE`; the buff: Z→D and Z→W `0x9001 NC_CHARGED_SETBUFF_CMD`. (2) W→new Z `0x1032` with the buff. (3) the
  buff is in the login blocks (`0x101B` / `0x1032`). (4) at most 511 rows arrive (D03-B10).
- **Disproved by:** all 600 rows arriving; `0x9001` to one of the two receivers only.

### 35. Dice table, gamble house, card collection

- **Claims:** Z06 §3–§4 (re-checks V10, L6), D03 §10–§12 (check 9: procedures only in the 2017 backup), W04
  §15, Z07 §7, Z28; Z11 §6.7.
- **Setup:** a mini-house with a TaiSai table (scenario 28) or the gamble house map; coins (S9 or the exchange
  NPC); a card item (`&makeitem`). GM: `&ts_DiceFix 111` fixes the next throw.
- **Steps:** (1) join the table, bet, win once (`&ts_DiceFix`) and lose once. (2) bet, then click logout while
  the table is in the rolling state. (3) gamble house: exchange coins, play one slot game, leave. (4) register
  a card, bookmark it, claim a collection reward, claim it again.
- **Prediction:** (1) dept 43 requests and their DB round trips (Z06 §3); the 2016 zone has no handler for
  the manual roll `0xAC20` (V10): a table in manual mode never rolls on request. (2) the zone's logout is
  held back: `0x0C31` and the socket close come about 50 ticks later than in the idle capture (L6). (3) dept
  47 (Z06 §4), `0x10DC` / `0x10DD` coin info, D `usp_Gamble_addCoin` (check 8). (4) dept 49 (Z07 §7); the
  second claim → `0x2BA9`, no second item (check 9).
- **Disproved by:** a logout in step 2 with the idle timing; a second reward item.

### 36. Block list, reports, options, megaphone

- **Claims:** W04 §8 (options: `0x7001` family), §10 reports, §14 block list, §17.2 / §17.4 spam report and
  chat ban; D04 §5, §10; D01 §4; Z02 §9 megaphone.
- **Steps:** (1) A blocks B; B whispers A; A unblocks. (2) A reports B (each report kind the client offers).
  (3) A changes game options, key bindings and shortcuts, then relogs. (4) A uses a megaphone item. (5) A
  reports B as a gold spammer.
- **Prediction:** (1) dept 42 → D → W → C; B's whisper still reaches A's client (`0x200D`), which drops it
  itself (README §3.16). (2) C→W `0x8001` / `0x8003` / `0x8005` → AL `0x8007` / `0x8009` / `0x800B` → W
  `0x8008` / `0x800A` / `0x800C` → C `0x8002` / `0x8004` / `0x8006`. (3) nothing at the change; in the logout
  tick `0x7011`, `0x7015`, `0x7016`, `0x703B`, no answers (captured once); the next login pushes the saved
  values. (4) `0x204B` → `0x204C`, item use, the roar to the map (Z02 §9). (5) `0x085F` → `0x0860` (W04 §17.4).
- **Disproved by:** the WM dropping the blocked whisper; an answer to an option save.

### 37. Login side: idle heartbeat, refusals, character delete

- **Claims:** L01 §1.6 (hand-rated: the Login heartbeat never fired in a capture), L00 / L01 refusal codes,
  D01 §3–§4, W01 §4 (delete, rename), W05 §4.5; D02 §3.
- **Setup:** S10 (blocked account), S11 (account not login-able), X6 (world closed / full in the server config).
- **Steps:** (1) start the client, stay on the login screen 70 s without typing. (2) log in, stay on the world
  list 70 s. (3) log in with the blocked account; with the not-login-able account. (4) select the closed world.
  (5) delete a character (wrong confirmation first if the client asks one), create one with the same name.
  (6) stay 4 minutes on the character list.
- **Prediction:** (1) Login → C `0x0804` after 30 s without a received packet, C → `0x0805`; no close
  (L01 §1.6). (2) the client's own `0x0C1B` poll keeps the link alive: no `0x0804`. (3) `0x0C09 {0x47}` "The ID
  has been blocked."; `{0x48}` "The World Servers are down for maintenance."; AL `0x0720` / `0xC802` for both
  (README §3.15). (4) the world-select refusal of L01 with the world's status byte. (5) W ↔ D delete, G
  `0x0412` twice (W and D), `0xC805`; create: `0x0411`, `0xC804`. (6) WM heartbeat every 30 s; no close at
  30 + 180 s as long as the client answers (W05 §4.5).
- **Disproved by:** a close in step 1 or 6 while `0x0805` is answered; another code than 0x47 / 0x48.

### 38. Session loss, kicks, back to character select

- **Claims:** Z01 §8 (logout, kick, socket loss; re-checks L5, L6), W01 §5 and §7.3 (`0x0C31`, W8), W05 §4.5,
  Z09 §1.5, README §3.12 b, c, e; re-check E41 (money is saved only as deltas); bug X01-B3.
- **Setup:** A in game with a known money value; a tool that closes one TCP connection of the client (TCPView
  "Close Connection" or a firewall rule on the zone port only).
- **Steps:** (1) return to character select (not world list), select the same character again. (2) quit the
  game from inside. (3) close only the **zone** connection of the client; note what the client shows; log in
  again within 10 s. (4) kill the client process; log in again. (5) pick up 100 money, wait for `0x3439`, then
  kill the **zone process** (no clean stop); restart, log in, read the money. (6) `&getmoney 500`, then the
  same kill within a second.
- **Prediction:** (1) `0x0C18 {1}` to W and Z; the WM runs the character logout but keeps the session; the
  zone saves (dept 16), sends W `0x0C31 {…, wmHandle, charNo}`; the next `0x1001` is accepted only after it
  (W8). (2) as the captured logout without the token steps. (3) the zone's socket-close path sends **no**
  `0x0C31` (the flag is 0, L5); the WM session lives on; a new login of the account kicks it (`0x0C17 {0x683}`),
  and the new session has `playingCharNo = −1`, so `0x1001` is accepted. If instead the client returns to the
  character list on the same WM session, `0x1001` is refused with `0x1002 {0x145}`. (4) both sockets close: WM
  `Client_OnClosed` (AL `0x0722`, `0xC803`, zones `0x0C19`), zone save with reason 7. (5) the money is there:
  the pick-up was committed by `0x3438` → `0x3439`. (6) either all 500 or none, never a partial value; nothing
  else of the last 10 minutes is saved (auto save 600 s).
- **Disproved by:** a `0x0C31` in step 3; a money value in step 5 or 6 that is neither the committed sum nor
  the old value.

### 39. Combat extras: death penalty, PK, revive item, knock-back

- **Claims:** Z03 §7–§8 (`0x2411` exp loss, revive choices), Z07 §3.1–§3.2, Z12, Z25 (knock-back / reinforce
  moves), Z09 PK fields and the world kill announcement, W03 §3.2–§3.4 guild war kills, W04 §3.
- **Setup:** A level 20+ (exp loss applies), a revive item (`&makeitem`), B; a PK field map (X2) or a guild war
  between two test guilds (scenario 18 twice).
- **Steps:** (1) die to a mob with the revive item: use it. (2) die again: revive in town. (3) on the PK field:
  B kills A. (4) declare a guild war, B kills A outside the PK field. (5) kill a mob with a knock-back skill
  (`&learnskill`), and get knocked back by a mob. (6) kill a boss that is announced (if one is in reach).
- **Prediction:** (1) `0x2411 NC_BAT_EXPLOST_CMD`; `0x3039 NC_ITEM_REVIVEITEMUSE_CMD` and the revive on the
  spot (Z04 §12, Z07 §3.1); without the item `0x303A`. (2) `0x104E` → `0x104F NC_CHAR_REVIVESAME_CMD` or the map change (captured for
  the other-map case). (3) Z→W `0x244A` → announcement; `0x244B` to the client (W04 §3). (4) WM tick `0x7443` /
  `0x7444` to all Z at start / end; kill Z→W `0x7445` → both guilds' members `0x742A` (no 2016 client handler).
  (5) the forced move `0x2069 NC_ACT_REINFORCERELOC_CMD` to sight and `0x204A NC_ACT_REINFORCE_STOP_CMD {x, y}` to
  the moved player (Z09 §9.3, Z25). (6) Z→W `0x2458` → clients
  `0x2459`.
- **Disproved by:** an exp loss below the level Z03 §8 gives; a client reaction to `0x742A`.

### 40. Gathering, production, item emotes, way-finding gate, tutorial, attendance

- **Claims:** Z02 §8, §9, §11, §12; Z07 §3.5–§3.7, §11; Z17 §3–§4 item actions; W04 §17.5–§17.6 attendance and
  NPC schedule; Z09 §5.9 scheduled NPCs; Z01 tutorial (bug X02-B5).
- **Steps:** (1) gather at a node: finish once, cancel once by moving. (2) produce an item from the gathered
  material: finish once, abort once. (3) use a premium emote item (action-item box). (4) equip an item with an
  `ItemAction` row (X7 lists some) and kill a mob. (5) use the auto way-finding to a gate and let it pass the
  gate. (6) a new character: play the tutorial steps, skip one. (7) first login of the day: attendance window,
  claim. (8) toggle auto pick-up.
- **Prediction:** (1) `0x202D` → `0x202E`, sight `0x202F`; `0x2032` → `0x2033`, sight `0x2034`; cancel `0x2030`
  / sight `0x2031` (Z02 §8). (2) `0x2035` → cast, sight `0x2038`; `0x203B`; Z→D `0x3457` → `0x3458`, mastery
  `0x481D`; abort `0x2039` / `0x203A` (Z07 §11). (3) `0x2067` → `0x2068` (Z17 §4.5). (4) the action's packets
  (`0x206F` heal effect, cool-down `0x10D0` at a save; Z17 §3.4.1). (5) `0x2070` → `0x2071` (Z02 §11). (6)
  `0x1116` / `0x1117`, saves `0x1118` → `0x1119`, item `0x1112` → `0x1113` (Z07 §3.7; W01 for the WM side). (7) the attendance
  request is sent once per WM session (first map login, W7), `0x10ED`…`0x10F6`. (8) `0x10BC {bEnable}` → W
  `0x10C1`.
- **Disproved by:** a second attendance list after a map change; a gather that completes without `0x2032`.

### 44. Holy promise (mentor and pupil)

- **Claims:** W04 §12 (21 KB, all offsets ours), D04 §8, Z08 §9, Z30 §6.1; bugs W04-B34, Z08-B14, X02-B11.
- **Setup:** A high level (mentor), B a new low-level character; note both `tCharacter.nMoney`.
- **Steps:** (1) B (pupil) asks A to be its master; A refuses; again; A accepts. (2) B levels up twice; B buys an item
  for cen at an NPC. (3) A opens the mentor window, collects the cen reward, withdraws it. (4) both relog.
  (5) B deletes the mentor; asks again at once.
- **Prediction:** (1) C→W `0x9401 NC_HOLY_PROMISE_SET_UP_REQ` → requester `0x9403
  NC_HOLY_PROMISE_SET_UP_CONFIRM_ING {UpCharID}` ("You've asked %s to be your master."), target the prompt
  `0x9404`, target→W `0x9405 {CharID, UpCharID, bAccept}`; a target playing the mini-house dice game drops the
  prompt and sends no `0x9405`; refusals `0x9402` (W04 §12.3) → D `0x941E` → W `0x941F` → both `0x9415
  NC_HOLY_PROMISE_ADD_CMD`. (2) Z→W `0x1074` → mentor `0x9419`
  level; the purchase credits price / 10 to the mentor's promise money (D03 check 13). (3) C→Z `0x943C` → D
  `0x943E` → Z `0x943F` → C `0x943D`; withdraw `0x9440` → D `0x9442` → Z `0x9443` → C `0x9441`, money `0x1033`
  (README §3.29). (4) `0x9416` / `0x9417` presence. (5) `0x9406` → D `0x9420` → `0x9421` → `0x9407`, `0x9418`;
  the new request is refused by the rejoin date (W04 §12.1: the dates are kept, W04-B34).
- **Disproved by:** a credit other than price / 10; a second promise accepted inside the rejoin time.

### 41. Test client: crafted client packets

These need a scripted client (framing and XOR-499 cipher of `docs/protocol/README.md`; a replay of a captured
login plus one crafted packet is enough). One connection per case: several end in a disconnect.

| # | Claim | Send | Prediction | Disproved by |
|---|---|---|---|---|
| T1 | E23, X02-B10 (W04 §8.2) | to the WM, in game: `0x7001` (no body); new session: `0x7002` | the WM closes the client connection, no answer | any answer, or the session staying open |
| T2 | E18 (W03 §5) | `0x980D` from a character with no guild and no academy; then from one with an academy | `0x980E` with zeros; then the list | a close in either case (a close is predicted only with guild **and** academy set) |
| T3 | E12 (W02 §2.1) | `0x3802 {name}` on the WM link after `0x0C0F`, before a character is selected | connection closed, no `0x3807` | `0x3807` |
| T4 | Q5, Z01-B6 | to the zone: `0x0812` without item 0x9C9 in inventory cell 0; then with it (`&makeitem`, move to cell 0) | first: no packet to anyone; second: Z→D `0x0812` with the appended `buylot` part, D echoes 0x5a bytes, the item's lot in zone memory + 1 per round trip (visible at the next stack operation: disconnect `0x68C`, I3, *(inferred)*) | an answer without the item |
| T5 | V5 (Z04 §4.2) | `0x300D` with a source cell in box 2 (reward inventory) | no packet; the zone log gets the assert "Invalid Item from box" | a `0x300E` or a DB request |
| T6 | Z26 §5.5 | `0x304E NC_ITEM_USE_ACTIVESKILL_REQ` on the silver wing's cell | blast and link at once, then a skill cast (no menu) | the menu `0x3C01` |
| T7 | E30, X02-B11 | A sends `0x5401` naming B in the instant B's client process is killed (script both) | sometimes A is disconnected (the handler returns B's failed send) | never in 20 tries: the window does not exist in practice |
| T8 | Z16-B4 | `0x581A` during a KQ start from a character that did not join | linked to KQ map 0 | a refusal |
| T9 | Q3, Z01-B3 | `0x1814` with no wing in the inventory | silence | any `0x1815` |
| T10 | Z07 §2.2 | `0x105C {5}` (stat index out of range); `0x105C {0}` with the stat already at the maximum | `0x1061 {0xAC3}`; then `0x1067 {0xAC2}` (**DEC** opcode on an INC request, original bug) | `0x1061` in the second case |
| T11 | Z04 §9.1 boundaries | `0x3017` with `equip = 0xFF`; with `raw` = an empty cell; with `gift_money` = money + 1 | `0x3018 {0x8C8}`, `{0x8C9}`, `{0x8CB}`, no DB request | a DB request |
| T12 | W04-B1 | `0x2010` notice from a level-100 GM with a 140-byte text (**crashes the WM**: last test of a session) | WM stack overflow above 131 bytes | a clean `0x2011` |
| T13 | W04 §17.3 | `0x0840` loading-failure report | W→D `0x0841`, no answer | an answer |
| T14 | X02-B6 (T10 of §3.4.1) | none (server-internal); listed for completeness: needs a tournament observer, scenario 43 | – | – |

### 42. Races: drop menu, two money pick-ups, link with a dead WM session

- **Claims:** re-checks E37 / V2 (X02-B9, `ii_DropLot` is latent), I4 (pending flag is one byte), W4 (X02-B3),
  I3 (`0x68C` after a move).
- **Steps and predictions:**
  1. **Stack grows while the drop menu is open (E37).** A holds a full-stack item that asks for a drop
     confirmation (an item with the drop warning; X7 lists them), lot 5; five more of it lie on the ground
     (dropped before from a second stack). Drag the stack out (`0x3007`, lot 5), leave the confirmation open,
     pick up the ground stack (if the client lets you; else B trades or a quest gives one more), then confirm.
     Prediction: `sp_ItemDropOK` sees `req.lot < cell.lot` → Z→D `0x3419 NC_ITEMDB_DROPLOT_REQ` and a ground
     object of lot 5 **before** the answer, then `0x341A` → `0x3008 {0x301}`. Disproved by: `0x3416` (then the
     menu blocks the pick-up and the branch stays dead), or the pick-up refused while the menu is open (note
     the code).
  2. **Two money pick-ups in one tick (I4).** Kill several mobs on one spot (`&mobbreed` + `&killallmob`),
     auto pick-up on (`0x10BC {1}`). Prediction: two `0x3438` requests in flight at once on the 9411 link (the
     second sent before the first `0x3439`), both answered, final money = sum. Disproved by: the second pick
     refused or delayed until the first answer (then the callers test the flag, and I4's "open" closes as
     "tested by the callers").
  3. **Zone change with the WM session gone (W4).** A walks through a gate at the moment its WM connection
     is closed with the connection tool of scenario 38. Prediction: ZA sends `0x180B`, the save, `0x180D`; the
     WM returns nothing; the client stays connected to ZA, unable to act, until it is closed. Disproved by: a
     `0x180E`, or a zone-side timeout that frees the player.
  4. **Lot mismatch after a move (I3).** Needs S12 (change a stack's `nLot` in `tItem` while the character is
     online). Move that stack to another cell. Prediction: C `0x300C {0x241}` first, then the disconnect `Z→W
     0x0C1A {…, 0x68C}`, client `0x0C17 {0x68C}`. Disproved by: a refused move, or no disconnect.

### 43. OPTool listener (test tool)

- **Claims:** W04 §4 (OPTool requests), §16 GM events; `login-server.md` §5.4; Z01 §3.3; D01 §2; D05 §5; Z16 §6
  tournament control; Z08 §13.
- **Setup:** a script that connects to each process's OPTool port (`ServerInfo.txt`) with the server-to-server
  handshake of S02 and sends one request. No original OPTool binary is in the repository.
- **Steps and prediction:** (1) dept 10 status and user-count requests to Login, WM, a zone, the DataServers:
  the answers of the cited sections. (2) `0x2829 NC_OPTOOL_KICK_USER_REQ {userNo}` at the WM with A in game:
  every Z `0x0C16`, A `0x0C17 {0x068F}`, OPTool `0x282A` (README §3.28). (3) `0x2827` find. (4) GM event add
  `0xD001`…: all Z `0xD00B`; delete while active: `0xD00C`, the event **keeps running** in the zones (W04-B50).
  (5) OPTool notice `0x2010` → every client `0x2011`. (6) KQ and tournament controls `0x2811`… (W04 §4.2,
  §4.4): the only way to reach the guild tournament (W03 §8, Z16 §6) on a test server without waiting for its
  schedule.
- **Disproved by:** a kick that reaches the WM client but no zone; an event withdrawn by the delete.

## 4. Boundary values (run inside the scenario named)

| Check our docs describe | Value to try | Scenario | Expected |
|---|---|---|---|
| stat index ≤ 4 (Z07 §2.2) | 5 | 41 T10 | `0x1061 {0xAC3}` |
| free points left | add with 0 left | 24 | `0x1061 {0xAC2}`, no DB request |
| upgrade at the limit / fee (Z04 §9.1) | `-u<max>`; money = fee − 1 (S2) | 22 | `0x3018 {0x8CA}` / `{0x8CB}` |
| `&getmoney` argument (Z11-B31) | −1 | 32 | money + 2³² − 1; with money near the cap (S2): note the cap behaviour, Z11 §7.4 |
| `&levelup` over the level limit (Z11-B30) | `&levelup 200` on a level-100 test character | 32 | every level applied, no limit; note the first packet that breaks the client |
| `&mobbreed` ranges (`num` 1–64, `count` ≤ 250) | `num` 0, 65; `count` 251 | 32 | the range handling of Z11 §4.2 (refused or clamped: note which) |
| `&dimension` (no range test, V24) | −1, 70000 | 14 | accepted; A leaves sight |
| shout level (`shoutlevel` of `0x0830`) | a level-1 character shouts | 14 | refused per Z02 §3.2 |
| party size (W02 §2.1) | invite with the party full (needs 5+ clients) | 15 | `0x3807` refusal; skip if clients are missing |
| guild create level 20 (W03 §2.2) | level 19, then 20 | 18 | refusal code of W03 §2.2, then success |
| booth money (Z06 §2.5) | buyer money = price − 1 (S2) | 20 | `0x680E` money code, no DB request |
| inventory full | unequip, pick up, quest reward, `&makeitem` with 0 free cells | 21, 23, 32 | `0x3013 {0x2C2}`; `0x300A {0x346}` "Inventory is full."; the DONE request is not sent (Z15 §5.1); silence |
| pick-up over the stack limit | sum of lots = limit + 1 | 21 | `0x300A {0x34A}`, no text |
| mini-house visit distance | 101 units | 28 | refused |
| notice length (W04-B1) | 131 and 132 bytes | 41 T12 | 131 delivered; 132 corrupts the WM stack |
| premium list size (D03-B10) | 511 and 512 rows (S8) | 34 | 511 arrive |
| expired item | an item past its end time (S13) at login and at use | 21 | the expiry path of Z24 |
| money near the cap | `nMoney` = cap − 10 (S2), then pick up 100 | 21 | the cap rule of Z04 §3.3 |
| character in a deleted state | S14, then the character list | 37 | not in the character list (D02 §3) *(inferred)* |

## 5. What the scenarios do not reach

- **Sections with no opcode (678 of the 1 882):** data tables, formulas, loaders, internal classes (most of Z09,
  Z10, Z12, Z19–Z22, Z24, Z27–Z29, S02). A capture raises them only through an effect: a damage or stat number
  (Z12, Z20, Z21: note the character window before and after each equip in 21 and 22), a drop rate (X1), a
  table value (X1–X7). The rest is second reading, as `confidence.md` §2 says per row.
- **Link records only (14 sections):** GameLog and AccountLog records and the dept-16 saves appear in every
  scenario when the server links are recorded; D05 and D01 §4 are checked against all of them at once.
- **Opcodes no scenario names** (`X02-scen.py left`): `0x0C1D` / `0x0C1E` / `0x0C20` (Netmarble / Outspark login:
  no first sender in the 2016 client, E4), `0x0820`, `0x0823`–`0x0825`, `0x0832`, `0x0837`–`0x083A` (event and
  repair messages of other regions' services, no trigger found in the 2016 binaries). One section is left with
  only these.
- **Guild tournament** (W03 §8, Z16 §6): reachable only through its schedule or the OPTool controls
  (scenario 43 step 6, or `&startGT` of Z11 §6.3 on one zone).
- **Not re-checked claims that stay code-only:** W03 §2.5 helpers, W04 §8.3, §12.3, Z04 §13.2, D02 §2
  (`confidence.md` §3.5); the *(db-backup)* rows of D01 / D02 are DB experiments (part 9).

## 6. Database setups and table experiments these scenarios need (written in X02 part 9)

Names in this table are as our documents give them; part 9 verifies each against the backups (`bak.py`) and the
binaries' `{CALL …}` strings before writing SQL, and adds save / restore statements and which process must be
stopped.

| ID | Used by | State to create | Starting point |
|---|---|---|---|
| S1 | all GM steps | character admin level 100 | `tCharacter.nAdminLevel` (Z11 §1.4, D02 §4.1) |
| S2 | 20, 21, 22, §4 | character money to a chosen value (0, fee − 1, cap − 10) | `tCharacter.nMoney`, character logged out (E41) |
| S3 | 23 | a quest at its last step | quest tables of D04 §1 |
| S4 | 23 | level 20 with the class-change precondition | D02 §4, D04 §1 |
| S5 | 28 | mini-house creation fails at the DB | the procedure behind `0x3467` (D03 §8) |
| S6 | 29 | wedding state: read `tMarriage`; reset the waiting time | D02 §11 |
| S7 | 33 | prison minutes for a character | D04 §7 |
| S8 | 34 | charged-item rows for an account (3, 511, 512, 600) | `Account.dbo.tChargeItem` (D03 §5.4) |
| S9 | 35 | gamble coins | D03 §11 |
| S10 | 37 | blocked account (`bIsBlock`) | `tUser` (D01 §3) |
| S11 | 37 | account not login-able (`bIsLoginAble` of its `tUserAuth` row) | D01 §3 |
| S12 | 42 | change a stack's lot while the owner is online | `tItem` (D03 knowledge) |
| S13 | §4 | an item past its end time | `tItem` / `tItemOptions` (D03 §1.3) |
| S14 | §4 | a character flagged deleted | D02 §3 |
| X1 | 39, §5 | drop experiments: limited drop `Num` runs out (V22, Z09-B20); Hunter voucher 1500 vs `SNS_DropUp` 1100 (V19) | `ChargedEffect.shn`, the drop tables of Z09 §11 |
| X2 | 15, 31, 39 | list party-release maps, instance gates, PK fields | `MapInfo.shn` / field tables (Z09), read only |
| X3 | 21 | an item whose stack limit can be exceeded by a pick-up | `ItemInfo.shn` |
| X4 | 24 | buffs with a walk / run / attack reset condition | the misc-data abstate table (C18), read only |
| X5 | 30 | a kingdom quest that starts minutes after boot with 1–2 players | `KingdomQuest.shn` (W04 §6.2) |
| X6 | 37 | a world closed / full | `9Data/ServerInfo` and the Login config (L01) |
| X7 | 40, 42 | items with an `ItemAction` row; items with a drop warning | `ItemAction*.shn`, `ItemInfo.shn`, read only |

## 7. Reach per document

Counted by `docs/plan/status/X02-scen.py cover` over the sections rated medium or low. "Reached" = names an
uncaptured opcode of at least one scenario; "link records only" = only GameLog / AccountLog / save opcodes
(§5); the last column gives the scenarios that reach most sections of the document.

<!-- COVER:begin -->
| Document | Medium / low sections | No opcode | Opcodes all captured | Reached by a scenario | Link records only | Not reached | Scenarios (sections) |
|---|---|---|---|---|---|---|---|
| L00 | 11 | 2 | 1 | 8 | 0 | 0 | 37 (8), 43 (1) |
| L01 | 18 | 8 | 0 | 10 | 0 | 0 | 37 (9), 43 (3) |
| W01 | 25 | 2 | 1 | 22 | 0 | 0 | 37 (19), 38 (7), 40 (6), 34 (5), 43 (4) |
| W02 | 37 | 1 | 0 | 36 | 0 | 0 | 16 (21), 15 (20), 41 (3), 17 (1), 37 (1) |
| W03 | 55 | 2 | 1 | 52 | 0 | 0 | 18 (49), 19 (21), 37 (20), 43 (2), 41 (2) |
| W04 | 51 | 1 | 0 | 50 | 0 | 0 | 43 (12), 17 (10), 37 (8), 30 (8), 36 (8) |
| W05 | 28 | 9 | 6 | 13 | 0 | 0 | 37 (8), 38 (3), 30 (3), 40 (3), 23 (2) |
| Z01 | 25 | 7 | 1 | 17 | 0 | 0 | 37 (10), 27 (7), 38 (5), 31 (4), 41 (4) |
| Z02 | 29 | 3 | 2 | 24 | 0 | 0 | 14 (12), 40 (7), 36 (6), 21 (4), 30 (4) |
| Z03 | 41 | 17 | 3 | 21 | 0 | 0 | 24 (17), 39 (5), 32 (3), 14 (1), 19 (1) |
| Z04 | 55 | 5 | 2 | 48 | 0 | 0 | 21 (24), 22 (12), 34 (4), 30 (4), 18 (3) |
| Z05 | 52 | 5 | 1 | 46 | 0 | 0 | 21 (29), 22 (8), 18 (7), 28 (7), 19 (5) |
| Z06 | 23 | 2 | 0 | 21 | 0 | 0 | 20 (11), 35 (11), 21 (3), 43 (3) |
| Z07 | 42 | 4 | 0 | 38 | 0 | 0 | 28 (13), 24 (8), 37 (6), 40 (5), 29 (5) |
| Z08 | 24 | 2 | 0 | 22 | 0 | 0 | 15 (5), 23 (5), 16 (3), 17 (3), 18 (3) |
| Z09 | 220 | 113 | 10 | 95 | 2 | 0 | 30 (36), 14 (23), 24 (16), 18 (11), 39 (10) |
| Z10 | 31 | 29 | 1 | 1 | 0 | 0 | 37 (1) |
| Z11 | 58 | 22 | 4 | 32 | 0 | 0 | 32 (10), 24 (9), 30 (8), 14 (5), 21 (5) |
| Z12 | 35 | 15 | 8 | 12 | 0 | 0 | 24 (7), 27 (4), 37 (4), 34 (2), 29 (1) |
| Z13 | 69 | 8 | 3 | 57 | 1 | 0 | 28 (17), 26 (15), 25 (14), 29 (11), 21 (8) |
| Z14 | 24 | 7 | 0 | 17 | 0 | 0 | 31 (8), 19 (5), 16 (4), 23 (3), 18 (2) |
| Z15 | 46 | 16 | 0 | 30 | 0 | 0 | 23 (30), 21 (3), 32 (2), 37 (2), 27 (1) |
| Z16 | 43 | 6 | 1 | 36 | 0 | 0 | 18 (22), 30 (13), 36 (2), 27 (2), 41 (2) |
| Z17 | 31 | 18 | 2 | 11 | 0 | 0 | 22 (6), 40 (5), 21 (3), 39 (2), 26 (1) |
| Z18 | 39 | 15 | 0 | 24 | 0 | 0 | 14 (6), 24 (6), 37 (5), 39 (5), 17 (5) |
| Z19 | 17 | 17 | 0 | 0 | 0 | 0 |  |
| Z20 | 20 | 19 | 0 | 1 | 0 | 0 | 24 (1) |
| Z21 | 27 | 20 | 0 | 7 | 0 | 0 | 24 (4), 21 (3), 37 (2), 40 (1), 39 (1) |
| Z22 | 50 | 29 | 1 | 20 | 0 | 0 | 24 (18), 14 (6), 39 (2) |
| Z23 | 34 | 15 | 5 | 14 | 0 | 0 | 24 (12), 34 (2), 27 (1), 41 (1), 40 (1) |
| Z24 | 32 | 22 | 0 | 10 | 0 | 0 | 21 (7), 34 (4), 27 (3), 40 (1) |
| Z25 | 30 | 12 | 4 | 14 | 0 | 0 | 24 (14), 14 (5), 39 (2), 27 (1), 41 (1) |
| Z26 | 20 | 3 | 6 | 11 | 0 | 0 | 27 (9), 21 (6), 41 (4), 20 (1), 24 (1) |
| Z27 | 31 | 30 | 0 | 1 | 0 | 0 | 21 (1) |
| Z28 | 24 | 18 | 0 | 6 | 0 | 0 | 35 (6), 21 (1) |
| Z29 | 11 | 11 | 0 | 0 | 0 | 0 |  |
| Z30 | 13 | 2 | 0 | 11 | 0 | 0 | 21 (5), 37 (4), 44 (2), 19 (2), 27 (2) |
| D01 | 17 | 4 | 1 | 10 | 2 | 0 | 37 (10), 43 (2), 38 (2), 40 (1), 36 (1) |
| D02 | 25 | 4 | 3 | 18 | 0 | 0 | 37 (9), 40 (6), 24 (6), 23 (5), 29 (5) |
| D03 | 45 | 7 | 0 | 37 | 1 | 0 | 21 (20), 22 (6), 34 (5), 23 (5), 28 (5) |
| D04 | 25 | 1 | 0 | 24 | 0 | 0 | 18 (9), 19 (6), 17 (5), 39 (4), 36 (4) |
| D05 | 25 | 6 | 1 | 11 | 7 | 0 | 37 (4), 29 (2), 39 (2), 43 (2), 30 (1) |
| D06 | 49 | 19 | 3 | 26 | 0 | 1 | 37 (11), 18 (4), 21 (3), 28 (3), 36 (3) |
| D07 | 15 | 4 | 0 | 11 | 0 | 0 | 19 (9), 18 (3), 21 (1) |
| S02 | 32 | 28 | 0 | 4 | 0 | 0 | 32 (3), 14 (1), 37 (1) |
| knowledge L01 | 2 | 0 | 0 | 2 | 0 | 0 | 37 (2), 43 (1) |
| knowledge W01 | 2 | 0 | 0 | 2 | 0 | 0 | 40 (1), 21 (1), 36 (1), 37 (1), 38 (1) |
| knowledge W02 | 2 | 1 | 0 | 1 | 0 | 0 | 15 (1), 16 (1), 17 (1), 37 (1) |
| knowledge W03 | 2 | 0 | 0 | 2 | 0 | 0 | 18 (2), 19 (1), 37 (1) |
| knowledge W04 | 2 | 0 | 0 | 2 | 0 | 0 | 30 (2), 36 (2), 40 (2), 31 (1) |
| knowledge W05 | 2 | 0 | 0 | 2 | 0 | 0 | 19 (1), 24 (1), 37 (1), 38 (1), 40 (1) |
| knowledge Z01 | 7 | 4 | 1 | 2 | 0 | 0 | 36 (2), 19 (1), 29 (1), 27 (1), 32 (1) |
| knowledge Z02 | 3 | 0 | 1 | 2 | 0 | 0 | 14 (2), 26 (1), 28 (1), 21 (1), 36 (1) |
| knowledge Z03 | 1 | 0 | 0 | 1 | 0 | 0 | 14 (1), 24 (1) |
| knowledge Z04 | 5 | 3 | 0 | 2 | 0 | 0 | 21 (2), 24 (1), 32 (1), 36 (1), 39 (1) |
| knowledge Z05 | 3 | 0 | 0 | 3 | 0 | 0 | 21 (3), 15 (1), 17 (1), 18 (1), 20 (1) |
| knowledge Z06 | 3 | 1 | 1 | 1 | 0 | 0 | 20 (1), 21 (1), 35 (1), 43 (1) |
| knowledge Z07 | 3 | 0 | 0 | 3 | 0 | 0 | 37 (2), 24 (1), 29 (1), 40 (1), 39 (1) |
| knowledge Z08 | 2 | 0 | 0 | 2 | 0 | 0 | 15 (2), 16 (2), 31 (1), 17 (1), 18 (1) |
| knowledge Z09 | 3 | 0 | 0 | 3 | 0 | 0 | 23 (2), 24 (2), 30 (2), 18 (1), 21 (1) |
| knowledge Z10 | 5 | 5 | 0 | 0 | 0 | 0 |  |
| knowledge Z11 | 4 | 1 | 2 | 1 | 0 | 0 | 21 (1), 24 (1), 25 (1), 29 (1), 30 (1) |
| knowledge Z12 | 4 | 1 | 0 | 3 | 0 | 0 | 36 (2), 24 (2), 27 (1), 37 (1) |
| knowledge Z13 | 9 | 0 | 1 | 8 | 0 | 0 | 29 (4), 26 (2), 22 (2), 32 (1), 24 (1) |
| knowledge Z14 | 1 | 0 | 0 | 1 | 0 | 0 | 15 (1), 16 (1), 18 (1), 19 (1), 23 (1) |
| knowledge Z15 | 3 | 0 | 1 | 2 | 0 | 0 | 23 (2) |
| knowledge Z16 | 3 | 1 | 0 | 2 | 0 | 0 | 18 (2), 30 (1) |
| knowledge Z17 | 5 | 1 | 1 | 3 | 0 | 0 | 22 (2), 40 (2), 21 (1) |
| knowledge Z18 | 1 | 0 | 0 | 1 | 0 | 0 | 14 (1), 27 (1), 37 (1), 41 (1) |
| knowledge Z19 | 1 | 1 | 0 | 0 | 0 | 0 |  |
| knowledge Z20 | 3 | 3 | 0 | 0 | 0 | 0 |  |
| knowledge Z21 | 5 | 4 | 0 | 1 | 0 | 0 | 24 (1), 40 (1) |
| knowledge Z22 | 5 | 5 | 0 | 0 | 0 | 0 |  |
| knowledge Z23 | 5 | 2 | 0 | 3 | 0 | 0 | 34 (2), 24 (1) |
| knowledge Z24 | 4 | 2 | 0 | 2 | 0 | 0 | 34 (2), 21 (1), 40 (1) |
| knowledge Z25 | 3 | 1 | 0 | 2 | 0 | 0 | 24 (2) |
| knowledge Z26 | 4 | 0 | 1 | 3 | 0 | 0 | 21 (2), 27 (2), 41 (2), 20 (1) |
| knowledge Z27 | 2 | 1 | 0 | 1 | 0 | 0 | 21 (1) |
| knowledge Z28 | 6 | 5 | 0 | 1 | 0 | 0 | 35 (1) |
| knowledge Z29 | 5 | 5 | 0 | 0 | 0 | 0 |  |
| knowledge Z30 | 2 | 0 | 0 | 2 | 0 | 0 | 37 (2), 27 (1), 21 (1), 44 (1) |
| knowledge D01 | 3 | 0 | 0 | 2 | 1 | 0 | 37 (2), 43 (2), 36 (1), 38 (1) |
| knowledge D02 | 3 | 1 | 0 | 2 | 0 | 0 | 37 (2), 38 (1) |
| knowledge D03 | 3 | 1 | 0 | 2 | 0 | 0 | 20 (2), 23 (2), 35 (2), 17 (1), 21 (1) |
| knowledge D04 | 4 | 1 | 0 | 3 | 0 | 0 | 19 (2), 18 (1), 36 (1), 37 (1), 30 (1) |
| knowledge D05 | 4 | 2 | 0 | 2 | 0 | 0 | 37 (1), 43 (1) |
| knowledge D06 | 8 | 5 | 0 | 3 | 0 | 0 | 37 (3), 18 (1), 19 (1), 23 (1), 24 (1) |
| knowledge D07 | 2 | 0 | 0 | 2 | 0 | 0 | 19 (2) |
| knowledge S01 | 21 | 8 | 0 | 13 | 0 | 0 | 37 (7), 39 (6), 32 (5), 35 (5), 17 (4) |
| knowledge S02 | 5 | 4 | 0 | 1 | 0 | 0 | 32 (1) |
| knowledge C01 | 11 | 2 | 0 | 9 | 0 | 0 | 37 (7), 30 (3), 40 (3), 41 (2), 18 (2) |
| knowledge C02 | 11 | 4 | 1 | 6 | 0 | 0 | 37 (6), 21 (4), 35 (4), 19 (4), 18 (3) |
| knowledge P01 | 6 | 2 | 0 | 4 | 0 | 0 | 37 (4) |
| knowledge P03 | 5 | 1 | 2 | 2 | 0 | 0 | 37 (2) |
| knowledge X01 | 4 | 2 | 0 | 2 | 0 | 0 | 43 (2), 44 (2), 23 (1), 30 (1), 40 (1) |
| knowledge X02 | 1 | 0 | 0 | 1 | 0 | 0 | 14 (1), 15 (1), 17 (1), 18 (1), 19 (1) |
| knowledge X03 | 15 | 8 | 3 | 4 | 0 | 0 | 37 (4) |
| **Total** | 1882 | 678 | 86 | 1103 | 14 | 1 | |
<!-- COVER:end -->
