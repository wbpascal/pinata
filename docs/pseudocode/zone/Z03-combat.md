# Zone server: combat, skills, abnormal states, damage, death, experience (Z03)

Source: `Files/Server/2016/w00_Zone00/5ZoneServer2.exe`, export `re-data/exports/zone`. Each block cites the
function it was reconstructed from (`@ FUN_xxxxxxxx`); view one with
`python3 -I tools/protocol-re/clean.py re-data/exports/zone tools/protocol-re/names/zone <addr>`.
Function names are the original profiler strings (Z01 names file) unless marked *(ours)*; Z03's additions are in
`tools/protocol-re/names/zone/Z03.json`. Opcode names are the official ones (`docs/protocol/opcodes.json`,
mostly *(pdb2017)*). Packet layouts: [`../../protocol/packets-zone.md`](../../protocol/packets-zone.md) and
[`../../protocol/annotations/Z03.json`](../../protocol/annotations/Z03.json). Core facts (objects, handles, broadcast,
send primitives, player modes, `g_Now` in tenths of a second) are in [`Z01-core.md`](Z01-core.md),
[`Z02-actions.md`](Z02-actions.md) §1 and `docs/knowledge/Z01.md` / `Z02.md`; this file does not repeat them.
Facts for other items: `docs/knowledge/Z03.md`.

The damage formulas are x87 code that the decompiler drops. They were read from the disassembly
(`objdump -d` over the exe); the terms are labelled with the server's own debug-log strings (the functions write
every term to a log file when a debug switch `DAT_0074d3ed` / `DAT_14d44a34` is on).

---

## 1. Conventions used in this file

```pseudo
handler(p = ShinePlayer, pkt, len, hnd)       # Z02 §1: pkt points at the opcode, payload offset N = pkt + 2 + N
tgt(p)  = p.target.obj (+0x7fc8) or, if null, p.target2 (+0x7fcc)      # "current target", used by every attack path
rand1000() = FUN_0063cb10(&g_Rng (DAT_150ba418), 1000) & 0xffff        # uniform 0..999
```

- **Mode masks:** `0x7E` = modes {1…6}, `0x04` = mode 2 only (combat stand). All attack and skill requests need
  mode 2; the client switches to combat stance first (Z02 `NC_ACT_CHANGEMODE_REQ`).
- **Abnormal state index** = `AbState.shn` column `AbStataIndex` (0…791, 792 = `0x318` = "none"). The states the
  combat code tests by number:

| Index | InxName | Role in the code |
|---|---|---|
| 291 `0x123` | StaImmortal | login / map-change protection: cannot attack or be attacked, cannot cast (0xFC1 / 0xFC2) |
| 499 `0x1f3` | StaAdlFLoussierIMT | same checks as StaImmortal (a second immortality state) |
| 199 `0xc7` | StaMobInvisible | target cannot be "seen": sub-layer visibility test fails |
| 392 `0x188` | StaCannotChangeTarget | TARGETTING_REQ ignored |
| 394 `0x18a` | StaSoulFree | skills with `DemandSoul` need no collected souls |
| 365 `0x16d` | StaMonkeyDefense | every hit does exactly 1 damage |
| 307 `0x133` | StaCommonStun02 | applied by a critical hit (§4.5) |
| 345 `0x159` | StaRestExp | survives death (re-applied with its rest time) |
| 326 `0x146` | StaEthereal | bearer cannot cast (0xFC0) |
| 201 / 202 | StaACMode / StaMRMode | physical / magical damage heals the bearer instead (§7) |
| 295 `0x127` | StaWeddingSub02 | survives death (re-applied) |

- **Player vtable slots used here** (byte offsets; names from profiler strings, otherwise *(ours)*):

| Slot | Function | Meaning |
|---|---|---|
| 0x28 | `IsDead` FUN_005557a0 *(ours)* | `+0x1d7c` flag set, or HP == 0 |
| 0x3e4 | `HasAbstate(idx)` FUN_00555a20 *(ours)* | the state is in the list and has ≥ 1 s left |
| 0x3ec | remaining time of an abstate | used with StaImmortal |
| 0x428 | battle statistics block | +4 kills-exp, +8 damage dealt/taken, +0x14 criticals, +0x18 hits taken, +0x1c deaths×50, +0x20/+0x24 PvP deaths/kills, +0x28 PvP rating |
| 0x430 | `GetParam()` FUN_00555720 | `this + 0xfc0`, the stat matrix (§4.1) |
| 0x484 | GetMode | Z01 |
| 0x4d0 | object type | Z01 §2 |
| 0x4d8 | level (clamped 1…150) FUN_005598a0 | |
| 0x4e8 / 0x4ec | HP (+0x7f67) / SP (+0x7f6b) | |
| 0x4f0 / 0x4f4 | MaxHP (+0xea8) / MaxSP (+0xeac) | recomputed, current value clamped |
| 0xd90 / 0xd94 | LP (+0x2ab20) / MaxLP (+0x2ab24) | "light points", third resource *(pdb2017: `targetlp`)* |
| 0x508 | `AttackSpeed()` FUN_005598d0 *(ours)* | `weaponSpeed (+0x29288, u16) * param[0xa18] / 1000` ms per swing |
| 0x510 | attack range against a target | weapon range |
| 0x52c | abnormal-state container (`this + 0x1cc`) | element list at container+0xcb0 = `this+0xe7c` |
| 0x550 | party number (+0x7fb9, −1 none) | |
| 0x5bc / 0x5c0 | `so_KilledBy` / `so_DamagedBy` | §7 |
| 0x638 / 0x63c | set abstate (with / without resist check) | §6 |
| 0x650 | reset abstate | §6 |
| 0x6cc | body size (player 50; mob `MobInfo.Size * 50 / 1000`) | added to every range check |
| 0x708 | mob id (0xFFFF for players) | |
| 0x70c | mob data row (null for players) | `MobInfo +0x63` = type |
| 0x72c | `so_mobile_IsEnemy(o)` | §3.3 |
| 0x7e8 | `hpchangeorder`: `++(u16 +0x1d78)` | sequence number in every HP-changing packet |
| 0x828 | guild number (+0x2a31c) | |
| 0x89c | "is a mob-like object" *(inferred from use: true → `vt[0x9b0]` gives the owner)* | |
| 0x8d0 | `CancelOnAction` | Z02 §1 |
| 0x980 | `so_mobile_ICanDamageTo(o, who)` | §3.3 |
| 0x998 | `so_ply_TargetChange(o)` | §2.4 |
| 0x9b0 | owner/master object of a servant or pet (null otherwise) | packets go to the owner's client |
| 0xa00 | `so_mobile_Broadcast2ndTarget(o, order)` | §2.3 |
| 0xa04 / 0xa0c | current target object (+0x7fc8) / has target | |
| 0xa84 | raid data (null when not in a raid; +4 raid number) | |
| 0xe0c | KQ team enemy test FUN_0055d700 | both in a team KQ (`kq+0x16c`) and teams (`vt 0xe08`) differ, team 2 = neutral |
| 0xed4 | `sp_castabort` | §5.4 |
| 0xed8 | `smo_BashStop` | §3.4 |
| 0xeec | `smo_SwingDamage` | §3.2 |
| 0xf1c / 0xf20 | `smo_SetCaptivate(on)` / IsCaptivated | §6.6 |

---

## 2. Targeting

### 2.1 State

```pseudo
struct TargetObject (p + 0x7fc0):                      # so_ply_TargetChange, FUN_0042ff90
    +0x00 u8   targetType      = target.vt[0x4e0]()    (2 for players)
    +0x02 u16  handle
    +0x04 u32  charNo          = target.vt[0x344]()
    +0x08 ptr  obj                                      # "current target" (p.vt[0xa04])
    +0x0c ptr  obj2                                     # fallback used by tgt(p) when obj is null; set elsewhere (mob side)
    +0x10 i32  = -1
p + 0x2a90c / +0x2a910 : soul owner object / soul count   (smo_SoulManage, §5.6)
```

### 2.2 NC_BAT_TARGETTING_REQ `0x2401` (C→Z) @ FUN_0042ffe0

Payload *(pdb2017 `PROTO_NC_BAT_TARGETTING_REQ`, confirmed)*: `{ u16 target }`.

```pseudo
sp_NC_BAT_TARGETTING_REQ(p, pkt):
    if not (0x7E >> p.mode & 1): return
    if p.IsCaptivated(): return                         # flag +0x1e78 bit 5
    if p.HasAbstate(392 StaCannotChangeTarget): return
    o = g_Objects.som_GetObject(pkt.target);  if o == null: return
    m = o.vt[0x70c]()                                   # MobInfo row, null for players
    if m and m.Type (+0x63) in {12, 13, 24, 27, 29}: return      # untargetable mob types
    # every abnormal state on the TARGET may veto: actor.vt[0x3c]() (only SubAbnormalStateCannotTarget returns true)
    for e in o.abstates:  if SubActor[e.subType].CannotTarget(): p.so_ply_TargetChange(null); return
    if not SameLayer(p, o):                             # FUN_0054aaf0: layer ids (+0x4e,+0x52) equal, or one side has the "all layers" flag +0x56
        p.so_ply_TargetChange(null); return
    p.smo_BashStop(); p.sp_castabort(); scs_Clear(p.cast)
    p.target.Set(pkt.target, o, p)                      # FUN_0042ff90 → to_SendInform
    if p.soulOwner != null and p.soulOwner.handle == pkt.target:
        send p: 0x2453 NC_BAT_SOULCOLLECT_CMD { u16 target, u8 soulnumber = p.soulCount }
```

### 2.3 Target information

```pseudo
TargetObject::to_SendInform(t, p):                      @ FUN_0042b3f0
    if t.obj == null: return
    send p: 0x2402 NC_BAT_TARGETINFO_CMD  order = 0, the target itself
    p.so_mobile_Broadcast2ndTarget(t.obj, 1)            # everyone in sight who targets *p* gets p's new target as order 1
    tt = t.obj.vt[0xa04]()                              # the target's own target
    if tt != null and t.obj.vt[0xa0c]():
        send p: 0x2402  order = 1, tt

0x2402 NC_BAT_TARGETINFO_CMD (0x1e bytes, pdb2017 names, layout confirmed):
    u8 order (0 = my target, 1 = my target's target), u16 targethandle,
    u32 targethp, u32 targetmaxhp, u32 targetsp, u32 targetmaxsp, u32 targetlp, u32 targetmaxlp,
    u8 targetlevel, u16 hpchangeorder (the target's counter, incremented by this read)

so_mobile_Broadcast2ndTarget(me, newTarget, order):     @ FUN_0042b2e0   (order ≥ 2 → nothing)
    AxialListTargetInform over everything in sight:      @ FUN_0042b0b0 (ali_Work)
        for each object r whose current target (r.vt[0xa04]) == me:
            send r: 0x2402 { order, newTarget's values }   # all zero + handle 0xFFFF when me has no target
            r.so_mobile_Broadcast2ndTarget(newTarget, order + 1)     # recursion stops at order 2
```

Client (`FUN_00499fa0`): order 0 fills the target frame, order 1 the "target of target" frame.

### 2.4 Server-side target change

```pseudo
so_ply_TargetChange(p, o):                              @ FUN_004a4680   (vt 0x998)
    if o != null and (o == p.target.obj or o is an untargetable mob type {12,13,24,27,29}): return
    send p: 0x244D NC_BAT_TARGETCHANGE_CMD { u16 target = o ? o.handle : 0xFFFF }
    p.smo_BashStop(); p.sp_castabort(); scs_Clear(p.cast)
    if o == null: p.target.Clear() (FUN_0042abd0) else p.target.Set(o.handle, o, p)
```

Called with `null` when the target dies or leaves (`so_ply_Send2WhoTargetMe` @ FUN_00568ee0, run over everyone in sight
by `so_KilledBy`), and by skills/abstates that force a target (taunts).

### 2.5 NC_BAT_UNTARGET_REQ `0x2408` (C→Z) @ FUN_0042b6a0

No payload.

```pseudo
    if not (0x7E >> p.mode & 1): return
    p.target.obj = null; p.target.targetType = 0
    p.so_mobile_Broadcast2ndTarget(null, 1)             # the players targeting p get an empty order-1 TARGETINFO
```

The attack in progress is **not** stopped here; the next swing tick finds no target and stops it (§3.1).

### 2.6 NC_BAT_ASSIST_REQ `0x243E` (C→Z) @ FUN_0042b7a0

Payload *(pdb2017, confirmed)*: `{ u16 tanker }`.

```pseudo
    if not (0x7E >> p.mode & 1): return
    o = som_GetObject(pkt.tanker); if o == null: return
    send p: 0x243F NC_BAT_ASSIST_ACK { u16 target = o.vt[0x754]() }
        # player: handle of tgt(o) or 0xFFFF (FUN_0055adc0); mob: its target selector's current target
```

The server does not change p's target; the client (`FUN_0049a2b0`) sends a TARGETTING_REQ for the answer.

---

## 3. Basic attack ("bash" / swing)

### 3.1 NC_BAT_BASHSTART_CMD `0x242B` (C→Z) @ FUN_00430fa0

No payload read (the target is the server-side current target).

```pseudo
sp_NC_BAT_BASHSTART_CMD(p):
    if p.mode != 2: return
    p.CancelOnAction(); nadt_Clear(p.hitQueue (+0x173d0))            # pending delayed hits are dropped
    if p.field == null or p.flags1e78 & 0x04 (Fear):  p.smo_BashStop(); return
    if p.HasAbstate(291) or p.HasAbstate(499):         p.smo_BashStop(); return
    t = tgt(p)
    stop = (t == null) or not LayerMatch(p.layer, t.layer)           # FUN_00427e50: equal or one side −1
        or not CanSee(p, t)                # FUN_0049acb0: t has StaMobInvisible → false, else g_SubLayerCanSee[p.sub][t.sub]
        or not SameLayer(p, t)             # FUN_0054aaf0
        or not g_MobData.Attackable(t.mobId, 2)                     # FUN_006424c0(&DAT_14d44a38, id, 2)
        or FindBlockLocate(p → t.pos, 10000) != t.pos                # a wall cell lies on the straight line (FUN_0049df00 test)
    if stop: p.smo_BashStop(); return
    if g_Now < p.nextSwingAllowed (+0x5cc0):  p.smo_BashStop(); return           # attack-speed limiter, set in §3.2
    p.lastSwingRequest (+0x5cc4) = g_Now
    for e in p.abstates: aeo_Attack(e)                               # states that end "on attack" (hide, …)

    # may this target be hit?
    owner = FUN_00409840(t)                                          # the player behind t (t itself, or a pet/servant's master), null for mobs
    if owner == null:
        ok = t.so_mob_CanBeAttackedByPlayer(p)                       # mobs: not (p.vt[0xe60](t) == 1)
    else if p.field.freePK (+0x54):            ok = true             # free-PK map
    else if p.field.kq (+0x10) and kq.type (+0x3a) == 4:
        ok = p.so_mobile_ICanDamageTo(t, …)                          # §3.3
    else if p.field.row.IsPartyBattle (+0x69):                       # World/Field.txt FieldList column
        if p.party == −1 or p.party != t.party: ok = true
        else: refuse()                                               # same party
    else if p.IsCaptivated() or owner.IsCaptivated(): ok = true      # a captivated side may be hit (§6.6)
    else if p.KQTeamEnemy(t):                         ok = true      # vt 0xe0c
    else if GuildWar(p.guild, t.guild):               ok = true      # FUN_005ccdf0(&g_GuildWars DAT_13296e08, …) ≠ 0
    else if field.fm_GuildTournamentEnemy(p.guild, t.guild): ok = true
    else: refuse()
    if not ok: p.smo_BashStop(); return
    refuse():                                                        # attacking a player who is not a legal enemy
        ShinePlayer::sp_GuildWarRequest(p.guild, t.guild)            # static; starts the guild-war declaration flow (Z08/W-side)
        p.smo_BashStop(); return

    p.attackFlags (+0x2928c) |= 0x04                                 # "bashing"
    p.swingCount (+0x1e88, u16) = 0
    if p.action (+0x2a784) is not running (state ∉ {2, 3}):
        p.comboStep (+0x29280) = 0
        p.attackFlags |= 0x01;  if not WeaponChargeOk(p) (FUN_00562160): p.attackFlags &= ~0x01
        ts_Set(p.action, sp_Schedule_SwingStart, 0, state = 2, delayMs = 0)      # FUN_0042ab50, fires on the next tick
```

`p.action` (`+0x2a784`) is the player's one-shot `TimeScheduler` *(Z02: "action-state timer")*:
`{ +0 fireAt (g_Now), +4 callback, +8 arg, +0xc state, +0x10 checker }`; state 2 = swing start pending, 3 = between
swings, 4 = used by gathering (Z02). `ts_TimerCheck` @ FUN_005696f0 runs it from `ShinePlayer::so_Routine`.

### 3.2 The swing cycle

```pseudo
sp_Schedule_SwingStart(p):                               @ FUN_00430bc0   (timer callback)
    p.multiHitIdx (+0x2a908) = 0
    t = tgt(p)
    if not p.so_mobile_ICanDamageTo(t, …)  or  p.param.flags (+0xcce) & 4            # "cannot attack" abstate bit
       or p.weapon (+0x2a7f8 → +10) == 0 or p.weapon2 (+0x2a7fc → +10) == 0
       or not p.charClass (+0xfbc).vt[0x50](t)                                       # class/weapon may attack this target
       or t.IsClosing() or t.IsDead():
        p.smo_BashStop(); return
    reach = (t.BodySize() + p.attackRange (+0x29284)) * 10 / 8                       # 25 % tolerance
    if dist²(p, t) > reach²:  p.smo_BashStop(); return
    if FindBlockLocate(p → t.pos) != t.pos:  p.smo_BashStop(); return
    p.attackSequence (+0x1e80, u8) += 1
    if not (p.attackFlags & 4): return
    smo_SwingStart(p, t)                                                             # broadcast 0x2447
    p.flightMs (+0x2a7c4, u16) = (charClass.vt[0x48]() == 11) ? dist(p, t) * 1000 / 200 : 0   # ranged class: projectile time
    w = p.costumeWeapon item (+0x2a7cc → item row)                                   # multi-hit weapons
    if w == null or w.row.id == 0xFFFF:
        nadt_PushBack(p.hitQueue, HitNotRevision(p) + p.AttackSpeed() / 2, p.flightMs, t, p.attackSequence)
    else:
        for i in 0..2:  ms = p.AttackSpeed() * w.row.hitTime[i] (u16 at +0x12 + 2i) / 1000;  if ms < 1: break
            nadt_PushBack(p.hitQueue, HitNotRevision(p) + ms, p.flightMs, t, p.attackSequence)
        (hitTime[0] == 0 → smo_BashStop)
    p.multiHitIdx = 1
    ts_Set(p.action, sp_Schedule_SwingStart, 0, state = 3, p.AttackSpeed() + HitNotRevision(p))   # next swing

HitNotRevision(p) = (p.swingCount == 1) ? −150 : 0       @ FUN_0042f850   # the first swing lands 150 ms early

smo_SwingStart(p, t):                                    @ FUN_0042f3f0
    broadcast to sight (incl. p): 0x2447 NC_BAT_SWING_START_CMD
        { u16 attacker, u16 defender, u8 actioncode = p.swingAnim (+0x1d70).vt[4](),
          u16 attackspeed = p.vt[0x50c](), u8 damageindex = ++p.swingCount (low byte), u8 attacksequence = p.attackSequence }
    p.swingAnim.vt[0](charClass ? charClass.vt[0x48]() : 0)      # advance the animation cycle

nadt_PushBack(q, delayMs, flightMs, target, seq):        @ FUN_005772a0
    q.push { fireAt = g_Now + (delayMs + flightMs) * 10 / 1000, flight = flightMs * 10 / 1000, target, seq }

NormalAttackDamageTick::nadt_Routine(q, p):              @ FUN_00577520   (every player tick)
    e = q.front; if g_Now < e.fireAt: return
    q.pop()
    if e.target and not e.target.IsClosing() and not e.target.IsDead():
        reach = (p.vt[0x510](e.target) + e.target.BodySize()) * 1200 / 1000          # 20 % tolerance
        if dist²(p, e.target) > reach²: p.smo_BashStop()
        else: p.damageSeq (+0x1e81) = e.seq;  sp_Schedule_SwingDamage(p)

sp_Schedule_SwingDamage(p):                              @ FUN_0042f550
    t = tgt(p);  first = (p.multiHitIdx == 1)
    if t == null or not p.so_mobile_IsEnemy(t) or t.IsDead() or t has StaImmortal / StaAdlFLoussierIMT: p.smo_BashStop(); return
    if dist²(p, t) > ((t.BodySize() + p.attackRange) * 10 / 8)²:                  p.smo_BashStop(); return
    p.nextSwingAllowed = p.lastSwingRequest + p.AttackSpeed() * 80 / 10000        # 80 % of the swing time, in g_Now units
    if p.attackFlags & 4:
        dead = p.smo_SwingDamage(t, abstate = 0x318 none, strength 0, rate 0, aggro 0)
        if not dead: advance p.multiHitIdx (wraps to 0 after the weapon's last hitTime)
    if first: p.smo_ply_CostumWeaponChargeDecrease(0,0,0); p.smo_ply_CostumShieldChargeDecrease(0,0,0)
```

```pseudo
smo_SwingDamage(a, d, abIdx, abStrength, abRate, aggro) → bool targetDead:      @ FUN_00432f30
    if d == null or a.field == null or d is a pet (type 12): return false
    a.direction = angle(d.pos − a.pos)
    a.vt[0xec8](d.mobId); a.vt[0x588](); d.vt[0x588]()                 # "in battle" marks (battle-state timers)
    ctx = BattleContext{ att = a, def = d, skill = null, rate = 1000, from = a.pos, hitRate2 = 1000 }   # see §4.2
    dmg = a.fixedDamage (+0x1e7c)                                      # > 0: GM "&staticdamage", skips the rolls
    if dmg < 1:
        if roe.HitRate(ctx) * g_HitRateScale (DAT_00870dd8) >= rand1000()       # hit
           and roe.vt[0x2c](ctx) >= rand1000():                                  # not evaded by a "range evasion" action (§4.4)
            dmg = roe.CalcDamage(ctx)                                  # §4.5; sets ctx.critical, ctx.immune
        else if a.param[+0xc30] < 1:                                   # no "minimum damage" stat
            ctx.miss = 1;  d.vt[0x700](a, 1)                           # "attacked but missed" (aggro without damage)
    # splash: the defender's "reflect / spread to attacker" parameter
    if d.param.splashRate (+0xcd2, u16) != 0 and (d.param.splashRange (+0xda8) == 0 or dist(a, d) > splashRange):
        a.vt[0xf5c](splashRate * (ctx.miss ? roe.CalcDamage(ctx) : dmg) / 1000, d)       # NC_BAT_REFLECTIONDAMAGE path (smo_ReflectionDamage)
    dmg = max(dmg * a.vt[0xf3c]() / 1000, 1 if dmg > 0)                # attacker's total damage rate
    # defender's race list (MobInfo "natural enemy" actions): pairs (kind 0x2c rate, kind 0x2d mobId) → dmg = rate * dmg / 1000
    if not d.so_mobile_IsImmortal() (vt 0x1c):  dmg += a.param[+0xc30]   # flat bonus damage
    dmg = d.vt[0xdb4](d.vt[0xbe8](dmg), 0)                             # shields / damage absorption (abstate actors)
    a.vt[0xef0](d, dmg, &ctx)                                          # apply: d.so_DamagedBy / so_KilledBy, aggro, hit lists (§7)
    hpAfter = d.GetHP()
    if rand1000() < abRate and abIdx valid:                            # weapon/skill "on hit" abstate (unused by the plain attack)
        if d.SetAbstate(a, abIdx, abStrength, …): broadcast set (§6.3)
        if aggro > 0: a.vt[0x704](d, aggro)
    for e in a.abstates: SubActor[e.subType].vt[0x40](e)               # "after attack" hook
    a.vt[0xa38](8, d.handle, 0)                                        # script hook kind 8 = attacked
    a.vt[0xbf8](0, d, 1, 0);  a.vt[0xbf8](3, a, ctx.miss, 0)           # item-action triggers (ItemAction.shn: on attack / on miss)
    if not d.vt[0xbec]():                                              # defender not "silent" (no packets)
        send a's client and d's client (or their owners', vt 0x9b0):
            0x2448 NC_BAT_SWING_DAMAGE_CMD (0x10 bytes)
              { u16 attacker, u16 defender, u16 flag, u16 damage, u32 resthp, u16 hpchangeorder,
                u8 damageindex = a.swingCount, u8 attacksequence = a.damageSeq }
              flag bit0 critical, bit1 dead (ctx+0x12), bit2 miss, bit3 shield block (ctx+0x13), bit4 costume-weapon charged
              (a.vt[0xf04]() when a.vt[0xeb4]() == 1), bit6 immune (ctx+0x16), bit7 abstate resisted (ctx+0x14),
              bit8 costume-shield charged (a.vt[0xf08]())
        broadcast to sight except those two:
            0x2449 NC_BAT_SOMEONESWING_DAMAGE_CMD (0xd bytes)
              { u16 attacker, u16 defender, u8 flag (bit0 miss, bit1 weapon charged, bit2 shield charged),
                u32 resthp, u16 hpchangeorder, u8 damageindex, u8 attacksequence = 0 }
    global item actions (vt 0x5d0, ItemAction lists) for a and d: trigger "on normal attack" (kind 3 physical / 2 magical rules)
    map script interrupt 0xac (damage) when the field has one
    return hpAfter == 0
```

Bystanders get no damage number: the client shows it only to the two fighters (the 2017 struct names agree:
`PROTO_NC_BAT_SOMEONESWING_DAMAGE_CMD` has no `damage`).

### 3.3 Who may be hit

```pseudo
ShineMobileObject::so_mobile_ICanDamageTo(a, d):         @ FUN_00434f30   (base test, all attackers)
    return not (a.flags1e78 & 4 Fear)
       and d != null and d != a and CanSee(a, d) and a.field != null
       and d.mode != 3 (dead) and d.mode != 0 and a.mode != 3
       and SameLayer(a, d)
       and g_MobData.Attackable(d.mobId, a is a player ? 2 : 1)
       and d.vt[0x8cc]() != 3

ShinePlayer::so_mobile_ICanDamageTo(p, d):               @ FUN_004361a0   (vt 0x980)
    if not base(p, d): return false
    d = d.owner() or d                                   # pets and servants count as their master
    if d == p: return false
    if d is a player (2) or mover (11):
        if d.vt[0xc70]() == 1: return false              # GM-invincible
        if either side has StaImmortal or StaAdlFLoussierIMT: return false
        if field.kq and kq.type == 4:                    # PvP kingdom quest ("free battle")
            same = (p.party != −1 and p.party == d.party) or same raid
            g1 = p.guild (vt 0x818) or p.academy (0x85c); g2 likewise
            if GuildWar(g1, g2): return true
            if g1 == 0 or g2 == 0 or g1 != g2: return not same
            return false                                 # same guild
        if field.freePK (+0x54) or d.owner captivated or p captivated: return true
        if p.party != −1 and p.party == d.party: return false
        if not field.row.IsPartyBattle (+0x69):
            if same raid: return false
            if p.guild and d.guild and p.guild != d.guild:
                if field.fm_GuildTournamentEnemy(p.guild, d.guild): return true
                if field.row.EnemyGuild (+0x63) and GuildWar(p.guild, d.guild): return true
            return p.KQTeamEnemy(d)
        return true                                      # IsPartyBattle map, different party
    if d is a mob (5), bandit (8) or NPC (4):
        if p.vt[0xe60](d) == 1: return false             # own summon / friendly
        if p.guild and d.guild == p.guild: return false  # guild-owned mobs (tournament flags, gate guards)
        return d.MobRow() != null
    return false

ShinePlayer::so_mobile_IsEnemy(p, d):                    @ FUN_00430570   (vt 0x72c; used when damage lands)
    d = d.owner() or d
    if d is mob-like (vt 0x89c):
        return p.vt[0xe60](d) != 1 and not (guild tournament and same guild) and not p.IsCaptivated()
           and not d.HasAbstate(499)
           and (d.RemainTime(291) == 0 or (d.RemainTime(291) < 3600 → d.ResetAbstate(291), true))
           # a mob hit while it still has < 360 s of StaImmortal loses the protection; ≥ 360 s (eternal) → not an enemy
    if d == p or d.vt[0xc70]() == 1: return false
    if d.owner captivated or p captivated: return true
    if field.freePK or (kq.type == 4 and p.so_mobile_ICanDamageTo(d)): return true
    if field.row.IsPartyBattle: if p.party == −1 or p.party != d.party: return true
    return GuildWar(p.guild, d.guild) or field.fm_GuildTournamentEnemy(p.guild, d.guild)
        or (d is player/mover and p.KQTeamEnemy(d))
```

Summary of the PvP rules *(from the two functions above)*: players can fight each other only (a) on a free-PK
map (`field+0x54`), (b) in a type-4 kingdom quest unless party/raid/guild mates, (c) on an `IsPartyBattle` map against
other parties, (d) during a guild war (`g_GuildWars` DAT_13296e08) on a map with `EnemyGuild` = 1, or a guild tournament
between the two guilds, (e) in a team KQ against the other team, or (f) when one side is captivated (§6.6).

### 3.4 Stopping

```pseudo
NC_BAT_BASHSTOP_CMD 0x2432 (C→Z, no payload)             @ FUN_0042e700
    if p.mode == 2: p.smo_BashStop()

ShinePlayer::smo_BashStop(p):                            @ FUN_0042e840   (vt 0xed8)
    p.bashStopNotify (+0x7f36) = 1                       # next tick: broadcast 0x243D NC_BAT_CEASE_FIRE_CMD { u16 handle } (FUN_00566820)
    sp_CostumWeaponChargeDecrease_ToClient / _ToDB;  sp_CostumShieldChargeDecrease_ToClient / _ToDB   # flush charge use
    p.attackFlags &= ~0x04
    if p.action.state in {2, 3}: clear the timer (state 0); nadt_Clear_PassHitTime(p.hitQueue)   # hits already "in flight" still land
    p.multiHitIdx = 0
```

`ShinePlayer::so_Routine` @ FUN_0056c790 (per player tick) sends the two deferred notifications:

```pseudo
    FUN_00566820(p + 0x7f36, p)                          # 0x243D CEASE_FIRE to sight (incl. p) if flagged
    if p.castResult (+0x7f37, u16) != 0:
        p.so_SendErrorCode(9, 0x34, p.castResult)        # 0x2434 NC_BAT_SKILLBASH_CAST_FAIL_ACK { u16 err }
        p.castResult = 0
```

So a skill request never answers inline: the handler leaves an error code in `+0x7f37` and the tick sends it (§5).

### 3.5 The older "bash" packets

`ShineMobileObject::so_Bash` @ FUN_0042e950 (and the player wrapper `ShinePlayer::so_Bash` @ FUN_0042efb0, which adds
the attacker's own packet) is the same roll (`HitRate` → miss, `vt[0x2c]` → miss, else `CalcDamage`), but applies the
damage itself and uses the 2012-era packets. It is reached from `so_attack` (mob normal attack, Z09) and the `&`
test commands, not from `NC_BAT_BASHSTART_CMD`.

| Opcode | Name | To | Layout |
|---|---|---|---|
| 0x242C | NC_BAT_BASH_HIT_CMD | attacker | `{u16 target, u16 crit:1|damage:15, u8 actioncode:4|abstateResisted:1|immune:1, u32 resthp, u16 attackspeed, u16 hpchangeorder}` |
| 0x242D | NC_BAT_BASH_HITTED_CMD | defender (player) | same with `u16 attacker` |
| 0x242E | NC_BAT_SOMEONEBASH_HIT_CMD | sight | `{u16 attacker, u16 defender, u8 actioncode, u32 resthp, u16 attackspeed, u16 hpchangeorder}` |
| 0x242F | NC_BAT_BASH_MISS_CMD | attacker | `{u16 target, u8 actioncode:4|miss:1|shield:1|immune:1, u16 attackspeed}` |
| 0x2430 | NC_BAT_BASH_MISSED_CMD | defender | `{u16 attacker, u8 actioncode:4|miss:1|shield:1|abstateResisted:1|immune:1, u16 attackspeed}` |
| 0x2431 | NC_BAT_SOMEONEBASH_MISS_CMD | sight | `{u16 attacker, u16 defender, u8 actioncode, u16 attackspeed}` |

---

## 4. Rules of engagement (hit, critical, damage)

### 4.1 The stat matrix

`obj.vt[0x430]()` returns the parameter block (`ShinePlayer + 0xfc0`). It is a matrix of 32-bit integers
`param[layer][stat]`, 51 stats per layer (`layer * 0xcc + stat * 4`), followed by special fields. Layers are sources;
the formulas combine them the same way everywhere:

```pseudo
Total(stat) = (L0 + L1)[stat] * L12 * L10 * L4 * L14 / 10^12  +  L5 + L7 + L9 + L11 + L13        # rates are per mille
```

| Layer | Offset | Debug-log label | Meaning *(inferred from the labels)* |
|---|---|---|---|
| 0 | 0x000 | purechar | character base (level/class table) |
| 1 | 0x0cc | item | equipment |
| 2 | 0x198 | Item (critical) | equipment, rate-type stats |
| 4 | 0x330 | itemattack | equipment rate (×/1000) |
| 5 | 0x3fc | upgrade / "Upgrade Plus" | enhancement bonus (flat) |
| 6 | 0x4c8 | "Upgrade Rate" | enhancement bonus (rate) |
| 7 | 0x594 | – | flat bonus |
| 8 | 0x660 | wpt / WeaponTitle | weapon title (licence) bonus |
| 9 | 0x72c | masteryplus | passive skill flat bonus |
| 10 | 0x7f8 | masteryrate | passive skill rate |
| 11 | 0x8c4 | abstate | abnormal-state flat bonus (`SAA_*PLUS`) |
| 12 | 0x990 | abrate / AbnormalState | abnormal-state rate (`SAA_*RATE`) |
| 13 | 0xa5c | – | flat bonus |
| 14 | 0xb28 | – | rate |
| 15 | 0xbf4 | "Total Rate" | final rate |

| Stat | Offset in layer | Meaning (evidence) |
|---|---|---|
| 0 | 0x00 | STR (`strtotal` in roe_MinWC) |
| 1 | 0x04 | END (added to AC, FUN_004fcbc0) |
| 2 | 0x08 | DEX (added to TH and TB) |
| 5 / 6 | 0x14 / 0x18 | WC min / max (`roe_MinWC` / `roe_MaxWC`) |
| 7 | 0x1c | AC (physical defence) |
| 8 | 0x20 | TH (aim) |
| 9 | 0x24 | TB (evasion) |
| 24 | 0x60 | weapon mastery (`masteryplus` L9, `masteryrate` L10) |
| 26 | 0x68 | shield block rate (L1 + L5) × L12 / 1000 |
| 32 / 33 | 0x80 / 0x84 | critical rate, physical / magical ("CriDamRate" / "MaCriDamRate") |
| 42 | 0xa8 | critical resistance *(inferred: subtracted from the attacker's rate)* |

Special fields after the matrix: `+0xa18` attack-speed rate (L12 stat 34), `+0xc30` flat bonus damage,
`+0xcce` flag byte (bit 1 no shadow-step, bit 2 cannot attack / cannot cast), `+0xcd0` u16 forced hit rate
(0 = normal, > 1000 = always), `+0xcd2` u16 splash rate, `+0xcdc` u16 critical damage bonus (per mille),
`+0xce0` / `+0xcfc` / `+0xd50` HP-loss curves (WC min, WC max, AC by lost-HP per mille, FUN_004c8fe0), `+0xda8` splash range.
MA (magic attack), MR (magic defence), INT and MEN use the same scheme with the stat indices between 3 and 12 not
listed here (not traced).

### 4.2 The context and the four rule sets

```pseudo
struct BattleContext (passed to every roe_* function):
    +0x00 attacker, +0x04 defender, +0x08 skill entry (null = normal attack), +0x0c reserved
    +0x0e u8 actioncode (attacker), +0x0f u8 actioncode (defender view)
    +0x10 u8 critical, +0x11 u8 miss, +0x12 u8 dead, +0x13 u8 shield block, +0x14 u8 abstate resisted, +0x16 u8 immune
    +0x18 ptr attack origin (xy) for back-attack bonus, +0x1c i32 = 1000, +0x20 i32 extra critical rate, +0x24 ptr, +0x28 i32 AP rate (1000)
obj + 0x1e74 → the object's current rule set (a static object with only a vtable):
```

| Class | Used for | CriticalRate | AttackPower | DefendPower | Damage | HitRate |
|---|---|---|---|---|---|---|
| `RulesOfEngagementNormalPY` | physical normal attack | FUN_00501700 | FUN_00506660 | FUN_00501fa0 | FUN_00500a30 | FUN_005011f0 |
| `RulesOfEngagementNormalMA` | magical normal attack (staff/wand) | FUN_00502550 | FUN_005068d0 | FUN_00502c20 | FUN_00500e10 | FUN_005020b0 |
| `RulesOfEngagementPhisycalSkill` | physical skills | FUN_00503200 | FUN_00506b40 | FUN_005032b0 | FUN_00500a30 | FUN_00502d30 |
| `RulesOfEngagementMagicalSkill` | magical skills | FUN_00503910 | FUN_00506ed0 | FUN_00503a50 | FUN_00500e10 | FUN_00503360 |

Vtable: `+4` CriticalRate, `+8` AttackPower, `+0xc` DefendPower, `+0x10` Damage, `+0x14` shield block rate,
`+0x18` HitRate, `+0x1c` `roe_CalcDamage` (shared, FUN_00505c00), `+0x24` back-attack/critical action rate,
`+0x28` shield action rate, `+0x2c` evasion action rate, `+0x38` `roe_IsDamageImmune`.

### 4.3 Hit rate

```pseudo
roe_HitRate(ctx) → per mille:                            @ FUN_005011f0 (NormalPY; NormalMA FUN_005020b0 is identical)
    block = roe.vt[0x14](ctx)                            # FUN_004ff860: (def.param[L1][26] + [L5][26]) * [L12][26] / 1000, + def.vt[0x474]() "FreeStatBonus"
    if block > rand1000():        ctx.shield = 1; return 0            # log: " Shield Success"
    if def has item actions and roe.vt[0x28](ctx) > rand1000():  ctx.shield = 1; return 0     # " Shield Success By GlobalAction"
    f = def.param.forcedHit (+0xcd0)
    if f != 0:  return f > 1000 ? 1000 : f               # forced hit rate on the defender
    TH = Total(DEX) + Total(TH) of the attacker (FUN_004fc700, min 1) + att.vt[0x470]()        # free-stat (aim) bonus
    TB = Total(DEX) + Total(TB) of the defender (FUN_004fc950, min 1) + def.vt[0x470]()
         + (def.vt[0x610]() ? def.param.curve(+0xd88)(0) : 0)
    rate = TH * 850 / TB                                 # log: "<TH> * 850 / <TB>"
    return RangePenalty(ctx, rate)                       # FUN_00500010
RangePenalty(ctx, rate):
    range = ctx.skill ? skill.info.Range (+0xb4) : att.vt[0x510](def)
    return range > 300 ? rate − def.vt[0xa68]() : rate   # ranged attacks: minus the defender's range-evasion stat

roe_HitRate for skills (FUN_00502d30 physical, FUN_00503360 magical):
    same shield and forced-hit steps, then
    asNormal = TH² / TB … scaled by attacker and defender level (log " As Normal ")
    asSkill  = ActiveSkillInfoServer.SkilPyHitRate (+0x23) | SkilMaHitRate (+0x27) combined with the same ratio (log " As Skill ")
    # the magical variant uses Total(stat 8) and Total(stat 9) built from layers 1, 7, 9, 11 only
    return RangePenalty(ctx, …)                          # exact arithmetic not reconstructed, see §11
```

`smo_SwingDamage` multiplies the result by `g_HitRateScale` (double at DAT_00870dd8) before the roll; `so_Bash` does
not.

### 4.4 Item-action rates

Objects with equipment "item actions" (`vt[0x5d0]`, `ItemAction.shn` / `ItemActionCondition.shn` /
`ItemActionEffect.shn`) add conditional rates: `FUN_005d1f30(list, &result, &query{…kind…})` then `FUN_005d0c80` reads
the summed value. `roe.vt[0x2c]` (FUN_005051c0, kind 5 then 3 for both sides) returns `1000 − sum` = the chance that
the hit is **not** evaded; `roe.vt[0x28]` (FUN_00505090, kind 6) the extra shield chance. Z06 owns the tables.

### 4.5 `roe_CalcDamage` @ FUN_00505c00

```pseudo
roe_CalcDamage(roe, ctx) → damage:
    if def.so_mobile_IsImmortal() (vt 0x1c, FUN_0042f780):  return 0
    if def.HasAbstate(365 StaMonkeyDefense): return 1
    if roe.roe_IsDamageImmune(ctx): ctx.immune = 1; return 0
    # 1. critical
    crit = roe.CriticalRate(ctx) + ctx.extraCrit (+0x20)
    if crit > rand1000():
        ctx.critical = 1
        if ctx.skill == null or skill.info.<+4> > 0:  CritStun(ctx)   # FUN_00500070
    else if att has item actions and roe.vt[0x24](ctx) > rand1000(): ctx.critical = 1
    # 2. the defender's item actions may cancel a critical: kind 6 → shield (critical = 0, shield = 1, return 0);
    #    kind 5 → evade (critical = 0, miss = 1, return 0); otherwise trigger its "critically hit" actions
    # 3. attacker's "on critical" item actions
    AP = roe.AttackPower(ctx);  DP = roe.DefendPower(ctx)
    dmg = roe.Damage(ctx, AP, DP)                                    # §4.6
    dmg = att is a player ? dmg / g_HitRateScale : dmg * g_HitRateScale      # DAT_00870dd8 again (PvE balance factor)
    # 4. grade gap: u16 at +0x12 of att.vt[0x498]() vs +0x14 of def.vt[0x498]()
    a = att.grade, d = def.grade
    if a > d: dmg *= (a − d + 1024) / 1024        else if a < d: dmg = dmg * 1024 / (d − a + 1024)
    # 5. critical damage
    if ctx.critical: dmg = dmg * 2 + dmg * att.param.critBonus (+0xcdc) / 1000;  att.stats.criticals += 1
    # 6. back attack: when ctx.origin differs from the defender's position, the angle between the defender's facing
    #    and the direction to the origin indexes World/DamageByAngle.txt (DamageByAngle_Chr DAT_0af0d0f0 for players,
    #    DamageByAngle_Mob DAT_0af0d1a8 otherwise: 0° 1000 ‰ … 180° 1200 ‰) → rate
    dmg = (int) dmg
    dmg = def.vt[0xd34](att, dmg);  dmg = att.vt[0xd2c](def, dmg)    # per-object damage modifiers (mob resist, KQ handicap)
    dmg = LevelGap(att, def, dmg)                                    # FUN_00500180, below
    dmg = max(dmg, 1)
    # 7. abnormal-state actors
    if range > 300: for e in def.abstates: SubActor.vt[0x28](e, &dmg)       # ranged-damage reducers
    for e in def.abstates: SubActor.vt[0x10](def, e, &dmg)                  # defender side (shields, damage-down)
    for e in att.abstates: SubActor.vt[0x2c](e, &dmg)                       # attacker side
    for e in def.abstates: SubActor.vt[0x30](def, e, &dmg)
    for e in def.abstates: SubActor.vt[0x50](e, def, att, &dmg)             # "last damage" interceptors (defender)
    for e in att.abstates: SubActor.vt[0x68](e, att, def, &dmg)             # … (attacker)
    return dmg

CritStun(ctx):                                            @ FUN_00500070
    if ctx.critical and roe.vt[0](ctx) > rand1000():      # FUN_00500170, the stun chance
        ab = AbState index 307 (StaCommonStun02)
        if not def.vt[0x634](ab) (immune to it) and def is mob-like (vt 0x89c):
            def.SetAbstate(att, 307, strength 1, …);  broadcast set

LevelGap(att, def, dmg):                                  @ FUN_00500180
    player → mob:    rate = DamageLvGapPVE(att.level, def.level)   FUN_005c8220
    mob → player:    rate = DamageLvGapEVP(att.level, def.level)   FUN_005c8280
    player → player: rate = DamageLvGapPVP(att.level, def.level)   FUN_005c81c0
    else: return dmg
    return rate * dmg / 1000
```

The three tables are `DamageLvGapPVE.shn`, `DamageLvGapEVP.shn`, `DamageLvGapPVP.shn` (per mille by level
difference).

### 4.6 Attack power, defence, damage

```pseudo
roe_Damage(ctx, AP, DP):                                  @ FUN_00500510 (base)
    AP = ctx.apRate (+0x28) * AP / 1000
    return AP * (att.level + 1) / DP                      # log: "AttackPower * (Level(att) + 1) / DefendPower = "
NormalPY::roe_Damage / NormalMA::roe_Damage               @ FUN_00500a30 / FUN_00500e10
    d = base(ctx, AP, DP)
    return d + att.vt[0x468 | 0x46c]() − def.vt[0x474 | 0x478]()      # log "After FreeStatBonus": free-stat damage bonus minus the defender's
                                                                      # (0x468/0x474 physical, 0x46c/0x478 magical)

NormalPY::roe_AttackPower(ctx):                           @ FUN_00506660
    min = roe_MinWC(ctx) (FUN_004fdbe0);  max = roe_MaxWC(ctx) (FUN_004fea10)
    lost = (att.MaxHP − att.HP) * 1000 / att.MaxHP
    min += att.param.curve(+0xce0)(lost);  max += att.param.curve(+0xcfc)(lost)          # "berserk" style bonuses
    if item actions of either side match (FUN_005d2010): min, max = action(min), action(max)
    ap = min + g_Rng2.Range(max − min)                    # FUN_0063ccc0(&DAT_14d720d0, n)
    return ap * att.param[L10][24] / 1000                 # mastery rate

roe_MinWC / roe_MaxWC (labels from the log):              @ FUN_004fdbe0 / FUN_004fea10
    strtotal    = Total(STR)                    (min 1)
    upgrade     = param[L5][6]      abstate = param[L11][6]      purechar = param[L0][5 | 6]
    item        = param[L1][5 | 6]  wpt     = param[L8][5 | 6]   abrate   = param[L12][6]
    masteryplus = param[L9][24]     masteryrate = param[L10][24] itemattack = param[L4][5 | 6]
    rst = (upgrade + strtotal + abstate + purechar + item + wpt + masteryplus) * abrate / 1000 * itemattack / 1000 * param[L10][5|6] / 1000
    rst = att.vt[0x938](rst);  return max(rst / 10, 1)    # the sum order and the final /10 are read from the FPU code; treat as (inferred)

NormalPY::roe_DefendPower(ctx):                           @ FUN_00501fa0
    ac = Total(END) + Total(AC) of the defender (FUN_004fcbc0, min 1)
    return ac + def.param.curve(+0xd50)((MaxHP − HP) * 1000 / MaxHP)

NormalPY::roe_CriticalRate(ctx):                          @ FUN_00501700
    rate = att.param[L2][42] + att.param[L2][32] (Item) + att.param[L12][32] (AbnormalState) − att.param[L12][42]
           − (def.param …)                                # one subtraction from the defender's block; operand not identified
    log terms: Item, WeaponTitle [L8][32], AbnormalState, Upgrade Rate [L6][32], Total Rate [L15][32], Upgrade Plus [L5][32]
    rate = FUN_004ffdb0(ctx, rate)                        # + att.vt[0x478]() (free-stat critical bonus)
    return max(rate, 1)
```

The magical variants replace WC by MA, AC by MR, END by MEN and STR by INT, and read stat 33 for the critical rate.
The skill variants start from the skill row (`ActiveSkillInfo.MinWC/MaxWC` + `MinWCRate/MaxWCRate`, `MinMA…`,
`AC`, `MR`) on top of the same stats, then `ActiveSkillInfoServer.DmgIncRate / DmgIncValue` (not traced in detail).

---

## 5. Skills

### 5.1 Data

```pseudo
g_SkillData (DAT_13286828): FUN_00448140(&g_SkillData, skillId) → SkillEntry *
struct SkillEntry:
    +0x000 → ActiveSkillInfoServer.shn row   (server only)
    +0x004 → ActiveSkill.shn row              (= 2017 PDB `ActiveSkillInfo`, 0x29f bytes; offsets confirmed in the handlers)
    +0x008 / +0x00c  vector of item-action refs (begin / end)
    +0x018 / +0x01c  vector of ToggleSkill.shn rows (begin / end): non-empty = toggle skill
    +0x040 4 × { abstate index (0x318 = none), strength, rate }        # StaNameA…D resolved at load
    +0x070 → rule set (RulesOfEngagementPhisycalSkill / MagicalSkill, by EffectType)
    +0x074 i32 Range (copy)            +0x07c i32 heal amount (SS_HEALAMOUNT)
    +0x0a0 u8/i32 pairs: decoded `SpecialIndexA…E` / `SpecialValueA…E` (one "present" byte + value per SkillSpecial kind,
           e.g. +0x100 SS_REVIVAL, +0xd8 SS_WARPING, +0x168 SS_DASH, +0x170 shadow step, +0x178 SS_SHOOTME,
           +0x1d0 summon/servant skill, +0x208 / +0x210 "escape target" effects, +0x220 SS_RANDOMTARGET, +0x240 SS_NOTTARGET) (inferred from use)
```

`ActiveSkill.shn` columns used by the handlers (PDB offsets): `SP +0xa0`, `SPRate +0xa4`, `HP +0xa8`, `HPRate +0xac`,
`LP +0xb0`, `Range +0xb4`, `First +0xb8` / `Last +0xbc` (`TargetType`: 0 ENEMY, 1 ME, 2 PARTY, 3 FRIEND, 4 SPOT, 5 ALL,
6 GROUP, 7 ENEMYUSER, 8 EVERY), `IsMovingSkill +0xc0`, `DirectionRotate +0xc3`, `SkillDegree +0xc5`,
`SkillTargetState +0xc7` (0 LIVE, 1 CORPSE, 2 NONE), `CastTime +0xcb`, `DlyTime +0xcf`, `Area +0x103`,
`TargetNumber +0x107`, `nIMPT[4] +0x1af`, `nT0…nT3[5] +0x1bf…` (empower tables), `EffectType +0x20f`
(`SkillEffectType`: 5 HEALING, 7 REVIVAL, 8 CURE, 9 DISPEL), `DemandSoul +0x29c`.
`ActiveSkillInfoServer.shn`: `UsualAttack +0x22`, `SkilPyHitRate +0x23`, `SkilMaHitRate +0x27`, `SkillHitType +0x3a`,
`AggroPerDamage +0x3f`, `AbsoluteAggro +0x43`, `AttackStart +0x47`, `AttackEnd +0x48`, `SwingTime +0x49`, `HitTime +0x4b`.

```pseudo
struct SkillCastStruct (obj + 0x1d84):                   # scs_Clear @ FUN_005691f0
    +0x00 u32 castEnd (g_Now; 0 = not casting)   +0x04 u16 skillId
    +0x08 ptr target object                      +0x0c/+0x10 target xy
    +0x14 ptr SkillEntry                         +0x18 ptr produce recipe (Z02) — non-null blocks sp_castabort
    +0x28 u16 empower bits used (SKILL_EMPOWER)
obj + 0x1e8a  u16 blast index (running number from FUN_00434c40(&g_BlastEffects); ties START, BLAST and DAMAGE packets together)
p + 0x17d0c   CharaterSkillList (learned active skills: +4 cooldown end, +8 SKILL_EMPOWER per skill); +0x17d30 passive list
```

### 5.2 NC_BAT_SKILLBASH_OBJ_CAST_REQ `0x2440` (C→Z) @ FUN_0057fa50

Payload *(pdb2017, confirmed)*: `{ u16 skill, u16 target }`.
The handler never replies inline. It sets `p.castResult (+0x7f37)`; the next player tick sends
`0x2434 NC_BAT_SKILLBASH_CAST_FAIL_ACK { u16 err }` when it is non-zero (§3.4). The initial value is `0xFCD`, so any
path that returns without setting a code reports "Skill has not been finished normally".

```pseudo
sp_NC_BAT_SKILLBASH_OBJ_CAST_REQ(p, pkt):
    p.castResult = 0xFCD
    if p.mode != 2:                                   → 0xFC0
    if p.field == null or not field.row.CanSkill (+0x9f):   → 0xFC3
    for e in p.abstates: aeo_Attack(e)
    if p.flags1e78 & 4 (Fear):                        → 0xFCC
    if p.IsCaptivated():                              → 0xFD2
    if p.HasAbstate(326 StaEthereal) (vt 0x9e4):       → 0xFC0
    p.CancelOnAction()
    if p.IsCasting() (cast.castEnd != 0)  or  t = som_GetObject(pkt.target) == null:   → 0xFC4   # (original bug) Z03-B2
    if not SameLayer(p, t) or not g_MobData.Attackable(t.mobId, 2):  p.smo_BashStop(); return (0xFCD)
    if not CanSee(p, t):                              → 0xFC0   # (original bug) Z03-B1
    if p.HasAbstate(291) or p.HasAbstate(499):        → 0xFC1
    if t.HasAbstate(499): return (0xFCD)
    r = t.RemainTime(291)                              # target under login protection
    if r > 0:
        if not t.IsMobLike():                         → 0xFC2
        if r > 3600: return (0xFCD)                   # eternal immortality
        t.ResetAbstate(291)
    if p.param.flags (+0xcce) & 4  or  p.smo_SkillBlastOption() == 2:  p.sp_castabort(); return (0xFCD)
    if FindBlockLocate(p → t.pos) != t.pos:           p.smo_BashStop(); → 0xFD1
    s = g_SkillData.Find(pkt.skill)
    if s == null or s.info == null or s.info.SkillTargetState == 2 (TS_NONE):  → 0xFC6     # passive / not castable
    if s.info.EffectType == 7 (REVIVAL) and not (field.flags (+0x20c) & 2):   → 0xFC0     # no revive on this map (original bug) Z03-B1
    if t.vt[0xc44]() == 1 and s.<+0x100> == 1:        → 0xFD8                              # revive refused ("Blessing of Teva")
    if p.moveState (+0x18c) == 3 (forced move):
        if s.info.CastTime != 0:                      → 0xFC8
        if s.<+0x178> or s.<+0x190>:                  p.smo_BashStop(); → 0xFC8
    if not sp_AbstateCheck(s, t) (FUN_00408be0):      → 0xFD4           # target already has a higher grade of the skill's buff
    if not p.HasAbstate(394 StaSoulFree) and s.info.DemandSoul != 0
       and (t != p.soulOwner or p.soulCount < s.info.DemandSoul):       → 0xFD3
    # target class by s.info.First
    switch s.info.First:
      5 (ALL): ok
      0 (ENEMY), 7 (ENEMYUSER): if not p.so_mobile_ICanDamageTo(t, …): → 0xFC6
      else (friendly kinds):
        if s.info.EffectType == 5 (HEALING) and s.info.Area == 0
           and not (First == 8 and t is mob type 16)
           and not p.smo_ICanHealTo(t) (FUN_00435390):                  → 0xFD7
    if s.info.ID == g_SpouseSkillId (DAT_13286d06) and not p.vt[0xa78]():   → 0xFCE        # wedding skill outside its area
    if p.smo_SkillBlastOption() == 2:                 → 0xFC7                              # Silence
    if not csl_CoolTimeCheck(p.skills, pkt.skill) (FUN_0046a420: entry.cooldownEnd <= g_Now):   → 0xFC8
    p.smo_ply_SetItemEffect(pkt.skill)                                   # vt 0xef8: load set-item skill bonuses
    if not SkillCostCheck(p, pkt.skill, s, &p.cast.empower, consume = false):   # FUN_0055b920, §5.3
        need HP: if s.info.HP + p.MaxHP * s.info.HPRate / 1000 >= p.HP:  → 0xFD5
        else if p.LP < s.info.LP:                     → 0xFDC  else → 0xFC9 (not enough SP)
    reach = t.BodySize() + s.range (+0x74);  reach = min(reach * 10 / 8, reach + 60)       # 25 % tolerance, at most 60 units
    if dist²(p, t) > reach²:                          → 0xFCA
    if p.action is running (swinging):  p.smo_BashStop();  if not s.server.AttackEnd: p.attackFlags |= 1
    else: p.attackFlags.bit0 = s.server.AttackStart
    if not WeaponChargeOk(p): p.attackFlags &= ~1
    if s is a toggle skill and not csl_Toggle_CanUseSkill(s, p) (FUN_00445710):  → 0xFD5   # HP-rate condition / weapon
    smo_SkillBash_Casting(p, s, t, null, −1)                             # §5.4
    p.attackFlags &= ~2;  p.castResult = 0
```

`NC_BAT_SKILLBASH_CAST_FAIL_ACK` codes, client texts (`GameFrameWork` handler FUN_004aa840, TextData2):

| Code | Client text | Set when |
|---|---|---|
| 0xFC0 | Cannot use the skill while in nonbattle mode. | mode ≠ 2; also invisible target, revive not allowed here, caster has StaEthereal (original bug) Z03-B1 |
| 0xFC1 | Cannot use the skill right after logging in. | caster has StaImmortal / StaAdlFLoussierIMT |
| 0xFC2 | Cannot use the skill when the target logged in just now. | player target has StaImmortal |
| 0xFC3 | Cannot use the skill in this field. | `FieldList.CanSkill` = 0 |
| 0xFC4 | Casting another skill now. | already casting, or target handle unknown (original bug) Z03-B2 |
| 0xFC5 | The skill has been reserved. | not sent by these handlers |
| 0xFC6 | Incorrect Skill. | unknown / passive skill, or enemy skill on a non-enemy |
| 0xFC7 | Cannot use the skill due to Silence State. | `smo_SkillBlastOption() == 2` |
| 0xFC8 | Cannot use the skill yet. | cooldown; cast-time skill while being moved |
| 0xFC9 | Not enough SP. | |
| 0xFCA | The target is out of casting range. | |
| 0xFCB | Cannot find the target. | set at blast time when the target is gone/dead (`sbec_Routine`) |
| 0xFCC | Cannot use the skill on Fear State. | flag bit 2 |
| 0xFCD | Skill has not been finished normally. | default; silent early returns |
| 0xFCE | Skill usage is prohibited in this area. | spouse skill |
| 0xFCF | Your spouse is not online, skill cannot be used. | not sent here |
| 0xFD0 | Target is in a Guild War, skill cannot be used | not sent here |
| 0xFD1, 0xFD2, 0xFD3, 0xFD5, 0xFD6, 0xFDC | "Failed to Cast the Skill." (default text) | blocked line of sight; captivated; not enough souls; not enough HP / toggle condition; (0xFD6: `FUN_00580800`, item skill); not enough LP |
| 0xFD4 | The effect cannot be used because upper level effect are used already | `sp_AbstateCheck` |
| 0xFD7 | Target user cannot be healed at this time. | `smo_ICanHealTo` |
| 0xFD8 | You cannot use revival to user who is in state of Blessing of Teva. | |

### 5.3 Cost

```pseudo
SkillCostCheck(p, skillId, s, &empower, consume) → bool:        @ FUN_0055b920
    hp = s.info.HP + p.MaxHP * s.info.HPRate / 1000
    sp = s.info.SP + p.MaxSP * s.info.SPRate / 1000
    lp = s.info.LP
    empower = csl_EmpowerStruct(p.skills, csl_MaximumSkill(skillId))     # the SKILL_EMPOWER bits of the highest learned step
    if empower.sp != 0: sp −= s.info.nT1[empower.sp]                     # row +0x1cf + 4 * points
    sp = p.vt[0xa60]() * (g_SetEffect.Get(5) * sp / 1000) / 1000         # set-item SP rate, then the SAA_USESPRATE parameter
    if p has item actions and s has action refs: sp = action(sp)
    for e in p.abstates: sp = SubActor.vt[0x38](e, sp)                   # SubAbnormalStateActorUseSPDown
    ok = p.SP >= sp and p.HP > hp and p.LP >= lp
    if ok and consume: p.vt[0x4f8](sp) (SP −=); p.vt[0x500](hp) (HP −=); p.vt[0xd9c](lp)
    return ok
```

### 5.4 Casting, abort, blast

```pseudo
ShineMobileObject::smo_SkillBash_Casting(o, s, target, xy, castMs):      @ FUN_0057bef0
    o.vt[0xee4](0xFCD)                                # player: castResult = 0xFCD until the blast succeeds
    scs_Clear(o.cast);  o.cast.skill = s;  o.cast.skillId = s.info.ID
    o.blastIndex (+0x1e8a) = g_BlastEffects.NextIndex()
    if target == null:
        if xy == null: o.vt[0xee4](0xFCB); return
        o.cast.xy = xy
        send o:   0x2450 NC_BAT_SKILLBASH_HIT_FLD_START_CMD { u16 skill, u32 x, u32 y, u16 index }
        to sight (not o): 0x2451 NC_BAT_SOMEONESKILLBASH_HIT_FLD_START_CMD { u16 caster, u16 skill, u32 x, u32 y, u16 index }
    else:
        o.cast.target = target;  o.cast.xy = target.pos
        o.vt[0xf48]()
        send o:   0x244E NC_BAT_SKILLBASH_HIT_OBJ_START_CMD { u16 skill, u16 targetobj, u16 index }
        to sight (not o): 0x244F NC_BAT_SOMEONESKILLBASH_HIT_OBJ_START_CMD { u16 caster, u16 skill, u16 targetobj, u16 index }
    ms = castMs >= 0 ? castMs : s.info.CastTime
    if ms > 0:
        for e in o.abstates: ms += SubActor.vt[0x18](e)                  # SUBAB_CASTINGTIMEPLUS (ActorCastDelay)
        for e in o.abstates: SubActor.vt[0x60](e, &ms)                   # SubAbnormalStateActorDelCastTime (stops at ms < 1)
    o.cast.castEnd = g_Now + ms * 10 / 1000
    o.vt[0xe9c]()                                     # player FUN_005792f0: castResult = 0, send 0x2435 NC_BAT_SKILLBASH_CAST_SUC_ACK (empty),
                                                      #   attackFlags &= ~2
```

The cast bar is client side: the client (`0x2435` → state 3) shows it for `CastTime` after the `*_START_CMD`.

`ShineMobileObject::so_Routine` @ FUN_0056a080 (every tick) fires the cast when `cast.castEnd <= g_Now`:

```pseudo
    if cast.target == null: smo_SkillBash_Blast_Loc(o, &cast.xy)
    else:                   smo_SkillBash_Blast_Obj(o, cast.target, &cast.empower)
    (servant/summon skills and self-target single skills take a variant path through vt 0xbf4)

smo_SkillBash_Blast_Obj(o, t, empower):                                  @ FUN_0057cd40
    if s.<+0xe8> (cross-counter style skill):
        if t == null or not o.so_mobile_ICanDamageTo(t) or (dmg = t.so_smo_CrossCounterDamage(o)) == −1:
            send o: 0x2457 NC_BAT_SKILLBASH_HIT_BLAST_CMD { u16 index, u16 caster, u16 skill }
            smo_ClearSkillResultBuffer_Miss(t); smo_SkillResultPacket(o); return
        fixedDamage = dmg * 2;  flags1e78 |= 0x10
    if s.info.IsMovingSkill: flags1e78 |= 0x10
    if not (flags1e78 & 0x10):                        # two-phase: first pass only arms the blast
        cast.castEnd += 3 (0.3 s);  flags1e78 |= 0x10;  return
    flags1e78 &= ~0x10
    optional movement effects by skill special: escape-from-target (vt 0x648 / so_EscapeFromTarget), smo_WarpForward,
        smo_ShadowStep (unless param.flags & 2), dash to the target's edge (smo_WarpTo), each followed by smo_SkillResultPacket
    toggle skills (s has ToggleSkill rows): if already on (vt 0xbc4) switch off (vt 0xbcc) else on (vt 0xbc8)
    to sight (incl. o): 0x2457 NC_BAT_SKILLBASH_HIT_BLAST_CMD { u16 index = o.blastIndex, u16 caster, u16 skill }
    g_BlastEffects.sbec_Store(index, s, o, t, origin = (First == ME ? o.pos : t.pos), fixedDamage, o.vt[0xefc](), …)

smo_SkillBash_Blast_Loc(o, xy):                                          @ FUN_0057cb10
    same two-phase arming; SS_SHOOTME skills jump the caster there (aborted with sp_castabort when rooted or being moved);
    SS_WARPING → smo_WarpTo; then 0x2457 and sbec_Store with target = null, origin = xy
```

```pseudo
NC_BAT_SKILLBASH_CASTABORT_REQ 0x2444 (C→Z, no payload)                  @ FUN_0057c480
    if p.mode == 6 (riding): send 0x2445 NC_BAT_SKILLBASH_CASTABORT_ACK { u16 err = 0x20E9 }; return
    if p.mode != 2:          send 0x2445 { 0x20EA }; return
    sp_NC_BAT_SKILLBASH_CASTABORT_CMD(p)                                 # FUN_00579f10
    send 0x2445 { 0x20E8 }                                               # success

sp_NC_BAT_SKILLBASH_CASTABORT_CMD(p):                                    @ FUN_00579f10
    pkt = 0x2438 NC_BAT_SOMEONESKILLBASH_CASTCUT_CMD { u16 caster = p.handle }
    if p.mode != 2 or p.cast.castEnd == 0:  send pkt to p only
    else: broadcast pkt to sight (incl. p);  p.cast.castEnd = 0;  p.smo_BashStop()

sp_castabort(o):  (vt 0xed4)                                             @ FUN_00579d50
    if o.cast.recipe == null and o.cast.castEnd != 0:
        broadcast to sight (incl. o): 0x2438 { u16 caster };  scs_Clear(o.cast)
```

The client ignores the ACK payload (`FUN_0049a540` only stops the cast bar); `0x2438` stops the animation of `caster`.
`sp_castabort` is what interrupts a cast from the server side: target change (§2), silence set (§6.6), captivate,
`sp_ChineCastCut`.

### 5.5 NC_BAT_SKILLBASH_FLD_CAST_REQ `0x2441` (C→Z) @ FUN_0057f400

Payload *(pdb2017, confirmed)*: `{ u16 skill, u32 x, u32 y }`. Same reply mechanism as §5.2.

```pseudo
    p.castResult = 0xFCD
    if p.mode != 2:                                   → 0xFC0
    if p.HasAbstate(291) or p.HasAbstate(499):        → 0xFC1
    if no field or not CanSkill:                      → 0xFC3
    for e in p.abstates: aeo_Attack(e)
    if p.IsCasting():                                 → 0xFC4
    if Fear:                                          → 0xFCC
    if p.IsCaptivated():                              → 0xFD2
    if p.HasAbstate(326 StaEthereal):                  → 0xFC0
    p.CancelOnAction()
    if FindBlockLocate(p → xy, wall test) != xy:      p.smo_BashStop(); → 0xFD1
    s = g_SkillData.Find(pkt.skill);  if s == null or TS_NONE:  → 0xFC6
    if REVIVAL and map forbids it:                    → 0xFC0
    if s.<+0x178> (SHOOTME: the caster moves there) and FindBlockLocate(p → xy, move test FUN_0049df70) != xy:
                                                      p.smo_BashStop(); → 0xFD1
    if p.moveState == 3 and (CastTime != 0 or s.<+0x178> or s.<+0x190>):   → 0xFC8 (+ BashStop for the latter two)
    if p.smo_SkillBlastOption() == 2:                 → 0xFC7
    if cooldown:                                      → 0xFC8
    p.smo_ply_SetItemEffect(pkt.skill)
    if not SkillCostCheck(…, false):                  → 0xFD5 (HP) / 0xFDC (LP) / 0xFC9 (SP)
    reach = p.BodySize() + s.range, same 25 % / 60-unit tolerance
    if dist²(p.pos, xy) > reach²:                     → 0xFCA
    attack-flag handling as §5.2
    smo_SkillBash_Casting(p, s, null, &xy, −1);  p.attackFlags &= ~2;  p.castResult = 0
```

No target-kind, soul or toggle checks here; the area scan at blast time decides who is hit.

### 5.6 Effect application

```pseudo
g_BlastEffects (DAT_0087efd4) = SkillEffectApply::SkillBlastEffectContainer: queue of 0x6c-byte SkillBlastEffect
    { +0 fireAt, +4 index, +8 SkillEntry, +0xc caster charNo, +0x10 caster, +0x14 empower, +0x18 target charNo,
      +0x1c target, +0x20 origin xy, +0x28 fixedDamage, +0x2c hit counter (−1/0 = first hit), +0x34 area step,
      +0x68 u8 chain depth, +0x6a u16 set-effect slot }
sbec_Store(…) queues an effect at g_Now + smo_SkillBlastTick(s)          # player: s.server.HitTime (+0x4b) * 10 / 1000; mobs 0

sbec_Routine():                                           @ FUN_00437fc0   (main loop, at most 10 effects per tick)
    e = front; if e.fireAt > g_Now: stop
    valid = e.skill and e.caster and not caster.IsClosing() and caster.charNo == e.casterCharNo and caster.mode in {1, 2}
    if valid:
        load the caster's stored set-item SkillEffect (g_SetEffect DAT_1325edb0) for this cast
        if e.target == null: sds_Initialize(); sbe_BlastLocate(e)
        else if target.IsClosing(), or (dead and skill is not REVIVAL), or has StaImmortal / StaAdlFLoussierIMT,
                or target.charNo changed, or target.mode == 0:
            if first hit: caster.vt[0xee4](0xFCB)          # "Cannot find the target."
            skip
        else: sds_Initialize(); sbe_BlastObject(e)
        sds_Finish(e)                                       # sends the collected results
        caster.vt[0xf00]()
        if first hit: caster.smo_ply_CostumWeaponChargeDecrease(1, s, 1); …ShieldChargeDecrease(1, s, 1)
    pop;  (more than 299 queued → log "Too many skill reserved" and clear)

sbe_BlastObject(e):                                         @ FUN_00583bc0
    if first hit and chain depth == 1:
        caster.vt[0xee0](s.info.ID, s, &e.empower)          # player FUN_0055bc50 = SkillCostCheck(…, consume = true): SP/HP/LP are paid here
        caster item actions "on skill use"
    if s.server.AggroPerDamage or AbsoluteAggro: target.vt[0x700](caster, 1)          # the target notices the caster
    if s.info.TargetNumber == 1 or chain depth > 1:
        smo_SkillBlast(caster, s, target, &e.empower, e.fixedDamage, &e.hit, depth, 1000)
        caster item actions "after skill" (kind 1, then 3 physical / 2 magical by SkillHitType)
        summon skills: caster.vt[0xbf4](…)
    else:                                                   # area skill
        scanner by s.info.Last: 0 ENEMY → AxialListNearScanSkillEnemy, 1/3 → …Friend, 2/6 → …Party, 5 → …All, 7 → …EnemyUser
        shape: AreaSkill.shn row (FUN_00585730) if the skill has one, else a circle (SkillDegree == 360, radius Area / 2)
               or a cone of SkillDegree around the direction to the target (rotated by DirectionRotate)
        candidates sorted by distance (qsort), then
        AxialListScanSkillTarget::alsst_SkillBlast(scanner, s, &empower, TargetNumber, &hit)          # smo_SkillBlast per target
            (or alsst_SkillBlast_RandomTarget for SS_RANDOMTARGET 1/2)
    if first hit: MiscDataTable::mdt_PostSkillBlast(caster, target, skillId); mdt_SkillBlast_Summon(…)
    map script interrupt 0xac
```

```pseudo
ShineMobileObject::smo_SkillBlast(a, s, d, empower, fixedDamage, hit, depth, rate):     @ FUN_00581160   (one target)
    skip when: 64 results already, d not attackable (vt 0x5ac), d has StaImmortal / StaAdlFLoussierIMT,
               g_MobData.Attackable refuses, wrong sub-layer, d dead (unless revive: SS_REVIVAL → d.so_ply_Revival(), §8.4)
    a, d: "in battle";  ctx = BattleContext(a, d, s, empower, a.pos);  r = result slot (0x18 bytes, DAT_13283d18[])
    # A. hit roll (only when no fixed damage)
    if fixedDamage < 0:
        if s.rule.HitRate(ctx) + (g_SetEffect.hitRate − 1000) < rand1000()  or  s.rule.vt[0x2c](ctx) < rand1000():
            r = { target d, ismissed, isshieldblock if ctx.shield, resthp };  splash as in §3.2;  return
    # B. heal part (s.heal (+0x7c) > 0, target alive, caster may not damage it)
        amount = g_SetEffect.healRate * item-action(s.heal) / 1000 + s.info.nT0[empower.damage]
                 (+ a.healBonus (+0x1c9a) per mille when the skill has action 0x62)
        r = { isheal, hpchange = amount, resthp = hp + amount }
    # C. damage part (s.rule.vt[0x20]() and a may damage d)
        r.isdamage = 1; costume weapon/shield charge flags
        dmg = fixedDamage >= 0 ? fixedDamage : s.rule.CalcDamage(ctx)                    # §4.5 with the skill rule set
        dmg = g_SetEffect.damageRate * dmg / 1000 * hit.rate / 1000                      # chain/area fall-off, min 1
        specials: SS_TARGETHPDOWNDMGUPRATE (more damage on wounded targets), SS_DMGDOWNRATE per chain step
                  (floor SS_MAXDMGDOWNRATE), SS_JUMP, back-stab distance bonus, SS_HPCONVERTSP, SS_MANABURN …
        apply through a.vt[0xef0](d, dmg, &ctx) → so_DamagedBy / so_KilledBy (§7);  r.iscritical, r.isDead, r.isImmune
    # D. side effects: SP cost refund specials (vt 0x4fc), target SP burn (vt 0x4f8), StaCannotChangeTarget (392/393) on the
    #    caster for taunt skills (keep time s.<+0x194>), smo_Dispel for EffectType CURE / DISPEL
    # E. abnormal states: for each of the skill's 4 entries (index, strength, rate) and the weapon's hit abstate:
        if rand1000() < rate (+ empower keeptime bonus nT3[empower.keeptime]):
            if d.vt[0x634](ab) (resist roll, §6.2): r.isresist = 1
            else if d.SetAbstate(a, index, strength, …, keepTimeBonus): d.Inform; BroadcastSet; r.isenchant = 1
    d.vt[0x700](a, aggro)                                                                # AbsoluteAggro
    item actions of d ("on skill hit"), then ++result count

SkillDamageSender::sds_Finish(e):                           @ FUN_00437110
    broadcast to sight (incl. caster): 0x2452 NC_BAT_SKILLBASH_HIT_DAMAGE_CMD
        { u16 index = e.index, u16 caster (0xFFFF if gone), u8 targetnum, SkillDamage[targetnum] }      # 7 + 14 n bytes
        SkillDamage (0xe bytes, pdb2017 names): { u16 handle, u16 flag, u32 hpchange, u32 resthp, u16 hpchangeorder }
        flag: bit0 isdamage, 1 iscritical, 2 ismissed, 3 isshieldblock, 4 isheal, 5 isenchant, 6 isresist, 7 IsCostumWeapon,
              bit8 isDead, 9 isImmune, 10 IsCostumShield
    # 2016 header is 5 bytes; the 2017 struct inserts `kSkillID` and `pTarget` before the array
```

Souls (`smo_SoulManage` @ FUN_004a5e20, `smo_HowMachSoul` @ FUN_004a6060): skills with
`ActiveSkillInfoServer.AddSoul` collect "souls" on one target (`p.soulOwner`, `p.soulCount`); the client is told with
`0x2453 NC_BAT_SOULCOLLECT_CMD { u16 target, u8 soulnumber }`. Skills with `DemandSoul` need that many on the same target
(§5.2, 0xFD3).

---

## 6. Abnormal states

### 6.1 Tables and structures

```pseudo
g_AbState[792] (DAT_0087b060): index (AbStataIndex) → AbStateEntry *        # AbnormalStateDictionary::AbState::as_FromIndex
g_AbStateByName (DAT_0087aea8): InxName → AbStateEntry *  (FUN_00418f80 / FUN_004013e0)
struct AbStateEntry:
    +0x00 → AbState.shn row: InxName +2, AbStataIndex +0x22, KeepTimeRatio +0x26, KeepTimePower +0x2a, StateGrade +0x2b,
                             PartyState1…5 +0x2c (5 × char[32]), PartyRange +0xcc, PartyEnchantNumber +0xd0, SubAbState +0xd4,
                             DispelIndex +0xf4 (DispelAttr), SubDispelIndex +0xf8, AbStateSaveType +0xfc,
                             MainStateInx +0x100, Duplicate +0x120
    +0x04 → AbStateSaveTypeInfo.shn row: IsSaveLink +4, IsSaveDie +5, IsSaveLogoff +6
    +0x08 resist slot: byte offset of this state's resist stat inside the parameter block
    +0x0c + strength * 0x24 (strength 1…39): { → SubAbState.shn row for that Strength, +0x10… 4 × (ActionIndex, ActionArg) }
SubAbState.shn row: Strength +0x22, Type +0x26 (SubState), SubType +0x2a, KeepTime +0x2b (ms), ActionIndexA…D / ActionArgA…D +0x2f…

AbstateElementInObject (0x74 bytes, one per active state; list at obj+0x1cc+0xcb0, 296 slots):
    +0x00 flags          +0x04 abstate index        +0x08 setter object, +0x0c setter charNo
    +0x10 u8 setter level, +0x14 setter attack power (snapshot for DoT)
    +0x18 u8 strength    +0x1c set time (g_Now)     +0x20 end time (g_Now)
    +0x24 next tick, +0x28 tick interval (SAA_TICK, ms → g_Now units; 50 for some actors)
    +0x54 actor private value, +0x58/+0x5c origin xy, +0x70 skill id that set it
g_AbActiveInfo[792] (DAT_00875228, 12 bytes each): { → actor object for the element's SubState type, → AbStateEntry,
    u16 SubState type, u16 SubType }                # filled by aeo_Set; "SubActor[e]" in this file
g_SubActors[120] (DAT_008778ec): SubState type → actor (default actor DAT_00877748)
```

Actor classes (RTTI, 27 virtual slots each), keyed by `SubAbState.Type` *(names of the types: pdb2017 enum `SubState`;
the pairing type → class is read from the class names, the table itself is filled at start-up)*:

| Class | SubState | Effect |
|---|---|---|
| `SubAbnormalStateFear` | 28 FEAR | `sasa_Routine` sets flag bit 2 and runs the victim away |
| `SubAbnormalStateCaptivate` | 70 CAPTIVATE | §6.6 |
| `SubAbnormalStateCannotTarget` | 105 CANNOTTARGET | `vt[0x3c]` true: TARGETTING_REQ on the bearer is refused |
| `SubAbnormalStateActorSilence` / `…Silencetoone` | 32 MAGICATTACKNOUSE / 88 ONETIMECANNOTUSESKILL | `vt[0x1c]` returns 2 → `smo_SkillBlastOption() == 2` |
| `SubAbnormalStateActorCastDelay` / `…DelCastTime` | 30 CASTINGTIMEPLUS / 118 DELCASTING | cast time (§5.4) |
| `SubAbnormalStateActorIgnoreCoolTime` | 31 COOLTIMEREMOVE | `vt[0x20]` true: `smo_SkillCooltimeSet` sets flag bit 6 (no cooldown) |
| `SubAbnormalStateActorUseSPDown` | 100 USESPDOWN | SP cost (§5.3) |
| `SubAbnormalStateActorPoison` / `Disease` / `DmgState` | 33 / 34 / 22, 27, 83, 84 | damage over time (`so_mobile_DamageOverTime` @ FUN_00409cd0 → 0x243C NC_BAT_DOTDAMAGE_CMD) |
| `SubAbnormalStateActorHPHeal` / `SPHeal` / `HPSPHeal` | 29 / 41 / 66 | heal over time (`sasa_Routine`) |
| `SubAbnormalStateActorShield` / `ManaShield` / `ShieldHPRate` | 16, 104 / 17 / 115 | damage absorption (`vt[0x10]`, `vt 0xdb4`) |
| `SubAbnormalStateActorDamageDownRate` / `SubAbnormalStateDamageMinus` / `…RangeIntercept` / `SubAbnormalStateRangeDamageMinusAtk` | 116 / 76 / 114 / 119 | damage reduction hooks in `roe_CalcDamage` |
| `SubAbnormalStateActorLastDmgRatio` / `…_DefSide` / `SubAbnormalStateActerTimeAttack` | 77 … | last-step damage hooks (`vt[0x50]`, `vt[0x68]`) |
| `SubAbnormalStateActorHideDamage` | 106 HIDEDAMAGE | `sasa_Act_DamegeIntercept` |
| `SubAbnormalStateActorMinHP` / `SubAbnormalStateMaxHP` | 117 / 24, 39 | HP floor / max HP |
| `SubAbnormalStateActorSelfRevive` / `…PartyRecharge` | 58 / … | `sasa_Act_Killed` (`vt[0x14]`, run by so_KilledBy) |
| `SubAbnormalStateActorExpUpRate` / `…DropUpRate` | 109 / 110 | `vt[0x44]`: exp multiplier (§8.2) / drop rate |
| `SubAbnormalStateActorAreaDamage` / `…MagicField` / `…Bomb` / `…Dispel` / `…DetachProcess` | 107, 113, 78 … | periodic area effects, effect on removal |
| `SubAbnormalStateActor` (base) | all stat types (0…15, 19, 20, 37, 43…57 …) | no behaviour; the stat change comes from `so_RecalcAbstateParam` |

Stat states work through the parameter matrix: `ShineMobileObject::so_RecalcAbstateParam` @ FUN_004cbe50 (vt 0x360) and
`aeo_ParameterEnchant` @ FUN_004079f0 add each element's `ActionIndex/ActionArg` pairs (`SubAbstateAction`: `SAA_STRRATE`,
`SAA_WCPLUS`, … *(pdb2017 enum)*) into layers 11 (plus) and 12 (rate) of §4.1, then `smo_NotifyParameterChange`.
Setting `obj+0xe94 = 1` (`vt[0x528]`) requests the recalculation on the next tick.

### 6.2 Setting a state

```pseudo
so_AbnormalState_Set(o, setter, abIdx, strength, entry, setTime, flag, keepMs, how, origin) → bool    @ FUN_004162d0 (vt 0x638)
    if o.HP == 0: return false
    o.vt[0xa38](3, abIdx, 0)                                  # script hook kind 3
    ok = FUN_004161c0(…) → AbstateListInObject::asl_AbstateSet
    if ok and o rides a mover: mover.vt[0xcf4](same args)     # the mount gets the state too
    return ok
(vt 0x63c @ FUN_004165c0 is the same without the HP test: used to re-apply states after death)

asl_AbstateSet(list, setter, abIdx, strength, entry, o, setTime, keepMs, …):                      @ FUN_0040d020
    if entry == null or strength not in 1…39: fail
    sub = entry.strength[strength].sub
    if sub.Type == 28 (FEAR): o.vt[0x7c4]()                                                       # stop what the victim is doing
    e = list.Find(entry.row.AbStataIndex)                                                         # FUN_00409b10
    if e == null:
        if sub.Type != 38 (DEFAULT):
            for x in list with the same (SubState Type, SubType):                                 # one state per effect group
                c = Compare(x's sub row, sub)                                                     # FUN_00591ce0
                if c == 1: x.endTime = g_Now                                                      # new one is stronger: old one expires
                else if c != 0: (weaker) if entry.row.MainStateInx == "-" and setter: setter.SendErrorCode(2, 0x42, 0xFD4); fail
        e = list.Alloc() (fail: log "Alloc Error")
    else: SubActor[e].vt[0x34](e, o)                                                              # detach the old strength first
    if not aeo_Set(e, …): free; fail
    o.vt[0x528]()  (recalc);  entry actor: ase_AfterEnchant;  NATURALENEMY (64) → o.vt[0x9d8](actions);  actor.vt[0x1c](e, o) attach
    return true

aeo_Set(e, setter, abIdx, strength, setTime, entry, o, keepMs, …):                                @ FUN_0040a340
    if entry.row.Duplicate (stacking limit) != 0: strength = min(max(strength, e.strength + 1), Duplicate)   # stacks up
    if strength < e.strength: (refresh with a weaker one) → setter gets 0xFD4 when MainStateInx == "-"; fail
    e.index, e.setter, e.setterCharNo, e.strength, e.setTime = …
    ms = keepMs given ? keepMs : sub.KeepTime + 999 + keepMs
    units = ms <= 60000 ? ms * 10 / 1000 : (ms / 1000) * 10
    e.endTime = setTime + g_SetEffect.Get(4) * units / 1000                                       # set-item keep-time rate
    e.skillId = current skill;  g_AbActiveInfo[index] = { g_SubActors[sub.Type], entry, sub.Type, sub.SubType }
    tick = entry action SAA_TICK (0x1a);  e.nextTick, e.interval from it
    party states: when the state has PartyState1…5 and no source, all five must be resolvable (aspe_FindSubState)
    actions: SAA_NOATTACK (0x19) → o stops attacking, broadcast 0x243D CEASE_FIRE;
             SAA_DOTWCRATE (0x60) / SAA_DOTMARATE (0x62) → snapshot the setter's attack power (roe_GetAttackPower, physical / magical) and level
    return true

so_AbnormalState_Resist(o, entry) → bool:  (vt 0x634)                                             @ FUN_00416730
    return rand1000() < o.param[layer11-like +0x1158][entry.resistSlot] + o.param[+0x1950][entry.resistSlot]
```

Keep time `1000000000` / `SubStaKeepTime_Eternal` rows give practically permanent states (StaImmortal after login has
`FieldList.immortalsec` (row +0x3f, ms): the per-map protection time).

### 6.3 Packets

```pseudo
so_AbnormalState_BroadcastSet(o, abIdx, keepMs, strength):                                        @ FUN_004056a0
    to sight (not o):  0x2427 NC_BAT_ABSTATESET_CMD   { u16 handle, u32 abstateIndex }
    to sight (incl. o): 0x1C18 NC_BRIEFINFO_ABSTATE_CHANGE_CMD { u16 handle, u32 abstateIndex, u32 keepTime, u32 strength }
so_AbnormalState_BroadcastReset(o, abIdx):                                                        @ FUN_00405800
    to sight: 0x2428 NC_BAT_ABSTATERESET_CMD { u16 handle, u32 abstateIndex }
ShinePlayer::so_AbnormalState_Inform(p, abIdx, keepMs, effect):  (vt 0x3f0)                       @ FUN_00405900
    send p: 0x2429 NC_BAT_ABSTATEINFORM_CMD (effect != 0) or 0x242A NC_BAT_ABSTATEINFORM_NOEFFECT_CMD { u32 abstateIndex, u32 keepTime }
FUN_00401a00(o, abIdx) / FUN_00401a40(o, abIdx): set / clear bit abIdx in the object's brief-info abstate bitmap
    (what newcomers see; `BriefInfoExchangeAbstate`, Z02 §5)
```

Standard sequence after a successful set: bitmap bit, `Inform(idx, sub.KeepTime, 1)`, `BroadcastSet(idx, sub.KeepTime, strength)`.

### 6.4 Expiry and removal

```pseudo
asl_Routine(list, o):                                      @ FUN_00406840   (ListIter_ObjectAbStateRoutine, every tick)
    per element: actor routine at e.nextTick (DoT, HoT, fear movement …); when e.endTime <= g_Now: detach
    (actor.vt[0x20]), clear the bitmap bit, BroadcastReset, free the slot, request the stat recalculation      (inferred from asl_AbstateReset)

asl_AbstateReset(o, abIdx):                                @ FUN_0040a930
    e = list.Find(abIdx); if e == null: return
    if e's actions are the active NATURALENEMY list: o.vt[0x9d8](null)
    entry actor.vt[0x20](e, o)                             # detach hook
    e.endTime = g_Now                                      # the routine removes it on the next tick
    o.vt[0x528]()
so_AbnormalState_Reset(o, abIdx):  (vt 0x650)              @ FUN_00559ef0   = asl_AbstateReset + the same on the ridden mover
```

Abnormal states are saved with the character (`so_SaveAbstate` @ FUN_00454d80, `NC_CHARSAVE_ABSTATE`) according to
`AbStateSaveTypeInfo` (IsSaveLink / IsSaveDie / IsSaveLogoff); Z07 owns the save path.

### 6.5 NC_BAT_ABSTATE_ERASE_REQ `0x2454` (C→Z) @ FUN_0042b900

Payload *(pdb2017, confirmed)*: `{ u16 abstateIndex }` (the player right-clicks a buff icon).

```pseudo
sp_NC_BAT_ABSTATE_ERASE_REQ(p, pkt):
    if not (0x7E >> p.mode & 1): return
    entry = g_AbState[pkt.abstateIndex]                    # ≥ 792 or empty: log "Not Find Abstate Index", no reply
    if entry.row.MainStateInx != "-":                      # a party sub-state: erase the main state first
        main = g_AbStateByName.Find(entry.row.MainStateInx)   # missing: log "Not Find MainAbstate Index", no reply
        err = EraseAbstate(p, main.row.AbStataIndex, 0x1C72)
        if err != 0x1C70: goto reply
    err = EraseAbstate(p, entry.row.AbStataIndex, 0x1C71)
reply:
    send p: 0x2455 NC_BAT_ABSTATE_ERASE_ACK { u16 err }

ShinePlayer::EraseAbstate(p, abIdx, notFound) → code:      @ FUN_0042acc0
    entry = g_AbState[abIdx];  if missing: return notFound
    if entry.row.DispelIndex not in { 0 DA_NONE, 1 DA_GOOD, 9 DA_HIDE }: return 0x1C72
    if not p.HasAbstate(abIdx): return notFound
    p.so_AbnormalState_Reset(abIdx);  asl_AbstateReset(p, abIdx);  p.vt[0x528]()
    return 0x1C70
```

Client (`FUN_004b0ce0`): `0x1C70` nothing, `0x1C71` "Buff you are trying to remove does not exist", `0x1C72` "Unremovable buff".

### 6.6 The status flag byte `obj + 0x1e78` (open question from Z02)

| Bit | Mask | Meaning | Set / cleared by |
|---|---|---|---|
| 0 | 0x01 | "routine has run once" / regen done *(inferred)* | every `so_Routine` (player, mob, pet, door) sets it; `so_mob_RegenComplete`, `spt_RegenComplete`, FUN_0055fdf0 clear it; `so_RetrateFromMap` sets it |
| 1 | 0x02 | weapon / skill uses the alternate ("ranged") damage path | `sm_UseWeapon` (mob weapon), `smo_SkillBash_Casting` wrapper FUN_0057d880 (`s.<+0x130>`); cleared by `sp_ReviveNow` |
| 2 | 0x04 | **Fear**: no moving (Z02), no attacking (`so_mobile_ICanDamageTo`), no skills (0xFCC) | `SubAbnormalStateFear::sasa_Routine` @ FUN_00406e30 while the state lasts |
| 3 | 0x08 | **killed**: `so_KilledBy` already ran (guards double death) | `ShinePlayer/ShineMob::so_KilledBy`, FUN_00432df0; cleared on regen (with bits 1 and 4: `& 0xE5`) and login init (`& 0xE7`) |
| 4 | 0x10 | skill blast armed (second pass of the two-phase blast, §5.4) | `smo_SkillBash_Blast_Obj/Loc`, `so_Routine`; cleared by `so_smo_CrossCounterDamage` |
| 5 | 0x20 | **Captivate** (mind control) | `smo_SetCaptivate(on)` FUN_0055d570 (vt 0xf1c; calls `so_mobile_StopHere` first); read by vt 0xf20 |
| 6 | 0x40 | "ignore cooldown" for the skill being cast | `smo_SkillCooltimeSet` @ FUN_0057c5b0 / FUN_005794d0 (vt 0xf60); cleared by `sp_ChineCastCut` |
| 7 | 0x80 | generic switch set through FUN_005558d0 (vt 0xbf0) | not traced |

**Bit 5** is set by `SubAbnormalStateCaptivate` (attach @ FUN_0040d3f0: `sp_castabort`, cancel the queued blast effects
`sbec_SkillCancel`, `smo_SetCaptivate(1)`; detach @ FUN_0040d460: `smo_SetCaptivate(0)`), i.e. by the two abnormal
states whose `SubAbState.Type` is 70 `SUBAB_CAPTIVATE` *(pdb2017 name)*: **StaKarenCaptivate** (index 335) and
**StaWarLBrainWash** (index 562), both mob skills. It is also toggled by the GM command `&captivate`
(`AmpersandCommand::ac_Captivate`, log text "smo_SetCaptivate true/false") and cleared at login complete and by
`sp_ReviveNow`. While it is set the player cannot walk/run (Z02), target (§2.2) or cast (0xFD2), is not counted as an
enemy by mobs (FUN_004304c0), and **can be attacked by other players anywhere** (§3.3): the victim is "on the mobs' side".

---

## 7. Damage, death

```pseudo
ApplyDamage(a, d, dmg, ctx):  (a.vt[0xef0])                 @ FUN_0042aeb0
    if ctx == null: return
    hp = d.GetHP()
    if d.IsDead(): d.so_KilledBy(a, hp, hp, 1); return
    # absorbing states: physical rule set → StaACMode (201), magical → StaMRMode (202)
    if (not all of miss/resist/shield/immune set) and d.HasAbstate(201 | 202 by a's rule set):
        d.so_DamagedBy(a, 0, 1000, 1);  d.vt[0x4e4](dmg)   # the damage heals instead;  ctx.+0x15 = 1
        return
    if dmg < hp: d.so_DamagedBy(a, dmg, 1000, 1)
    else:        d.so_KilledBy(a, hp, hp, 1)
    d.vt[0xbd4]()

ShinePlayer::so_DamagedBy(p, a, dmg, aggroRate, countHit):  @ FUN_00431500   (vt 0x5c0)
    if a: a.stats.damage += dmg;  for e in p.abstates: aeo_Attacked(e)          # states that break on damage (sleep, hide …)
    p.HP (+0x7f67) −= dmg
    if countHit: p.stats.hitsTaken += 1;  p.CancelOnAction()                    # casting items, gathering … are interrupted
    map script interrupt 0xac (damage) if the field has one

ShineMob::so_DamagedBy(m, a, dmg, aggroRate):               @ FUN_00431750
    a.stats.damage += dmg;  aeo_Attacked;  MobChatManager::mcm_DamageChat(m)
    m.HP (+0x1ec4) −= dmg;  AI-script event 0x58 (damaged)
    m.vt[0x700](a, dmg * aggroRate / 1000)                  # aggro (so_mob_AppendAggro)
    m.hitMeList (+0x22f0).Add(a, dmg)                       # FUN_00482f00: who dealt how much (exp shares, loot right)
    boss fields: BossFieldContent maal_MobDamaged;  target selector notified;  first attacker handle (+0x24ae);
    home position updated;  sm_Scream4Rescue (calls MobInfoServer "family" mobs for help)
```

HP changes are shown to the client only through the attack packets (`resthp` + `hpchangeorder`) and
`0x240E NC_BAT_HPCHANGE_CMD` / `0x240F NC_BAT_SPCHANGE_CMD` (regen, potions; Z04/Z09).

### 7.1 Common part

```pseudo
ShineMobileObject::so_KilledBy(o, killer, dmg):             @ FUN_00432240
    o.mode = 3 (dead);  o.vt[0xf18]();  o.killerHandle (+0x184) = killer ? killer.handle : 0xFFFF
    AI-script event 0x74 (object dead) on the object and map script interrupt 0x74 on the field
    rest = remaining time of StaRestExp (345)
    o.vt[0xf64]() (boss abstate bookkeeping);  brief-info abstate bitmap cleared
    remove ALL abnormal states (ListEraser over the element list)
    if rest != 0: re-apply StaRestExp with the remaining time (vt 0x63c) + Inform + BroadcastSet
    o.so_RecalcAbstateParam()
    everyone in sight who targets o: so_ply_Send2WhoTargetMe → so_ply_TargetChange(null)
    o.smo_NotifyParameterChange(0)
    if killer:
        killer.stats.killExp += o.vt[0xee8]();  killer.stats.damage += dmg
        field CinemaComplex::cc_ScriptInterrupt(sim_ObjectDead { o.handle, o.name, killer.handle, killer.name })
        guild tournament system (if the field has one): FUN_0047e640(o, killer)      # kill score, Z08
        killer item actions "on kill" (kind 4)
        killer.vt[0xa08](0)
```

The death itself reaches clients as the `dead` flag of the damage packet that killed (`SWING_DAMAGE` flag bit1,
`SkillDamage.isDead`, DoT packet); the client runs `Char::OnDead` (Z02 §1). There is no separate "someone died" packet in
this path (`0x2406/0x2407 NC_BAT_SOMEONEDEAD_*` are not sent by the 2016 zone).

### 7.2 Player death

```pseudo
ShinePlayer::so_KilledBy(p, killer, dmg):                    @ FUN_00433be0   (vt 0x5bc)
    if p.flags1e78 & 8: return;  p.flags1e78 |= 8
    if p.mode == 5: sp_CloseStreetBooth(p)                  # mode 5 = street booth (vendor) (confirms Z02's "another rest state")
    if killer: party/raid quest check `sqd_MobDead` (kill-player quests)
    if p.mode == 6: dismount (sp_HorseOff, or leave the mover)
    clear the action timer (unless gathering state 4);  p.CancelOnAction()
    for e in p.abstates: SubActor.vt[0x14](p, e)            # sasa_Act_Killed: SelfRevive, PartyRecharge
    remember StaWeddingSub02 (295): setTime and keep time
    # abnormal-state shelters: states are parked by charNo and given back on revive
    if p has the item g_ReviveKeepBuffItem (DAT_14d504c8):  # "keep buffs on death" charged item
        g_ShelterItem (DAT_0087c4d8)[p.charNo] = all states with DispelIndex 1 (GOOD) or 11 (CHARGED) and IsSaveDie == 0
    g_ShelterDie (DAT_0087c4c8)[p.charNo] = all states with IsSaveDie != 0
    ShineMobileObject::so_KilledBy(p, killer, dmg)          # §7.1 (removes every state)
    restore the saved shape data if a polymorph was active (+0x292ac → brief +0x25)
    re-apply StaWeddingSub02 if it was on
    p.HP = 0;  HP/SP recovery functions = none;  FUN_004d2470(p, 8)

    lost = 0
    k = killer is mob-like ? killer.owner() : killer
    if k is a player:
        if field.freePK or kq.type == 4:
            lost = sp_LostExperienceByKilled(p, sp_LostExpWhenKilledByPlayerInPKField)
            n = k.vt[900]()                                  # killer's PK count after increment (so_ply_SavePKCount)
            → WM: 0x244A NC_BAT_PKINPKFIELD_WMS_CMD   { u16 killerWmHandle, u32 killerCharNo, u32 pkCount }
            → p and k: 0x244B NC_BAT_PKINPKFIELD_CLIENT_CMD { u16 killer, u16 victim, u32 pkCount }
        if GuildWar(k.guild, p.guild): → WM: 0x7445 NC_GUILD_ZONE_WAR_KILL_CMD { u16 killerWmHandle, u16 victimWmHandle }
        p.stats.pvpDeaths += 1;  k.stats.pvpKills += 1
        # PvP rating transfer (stats +0x28, start/min 1000): a = p.rating, b = k.rating, m = min(a, b)
        f = m / (a + b);  f = (b > a) ? 2 f² : 1 − f;  d = (int)(f * 1000)       (scaling read from x87 code, (inferred))
        p.rating = max(a − d, 1000);  k.rating += d
    else if killer:
        lost = sp_LostExperienceByKilled(p, sp_LostExpWhenKilledByMob)
        p.questDiary.MobKilledMe(killer.mobId, killer.handle)                    # FUN_005cbdd0
    ShinePlayer::sp_KQElementFunction(kqpil_KnockDownPlus)
    p.stats.deaths += 50
    send p: 0x104D NC_CHAR_DEADMENU_CMD { u32 reviveWaitSec = field ? field.<+0x210> : 180, u8 = 50,
                                          u32 canReviveHere = p.<+0x2aac4> and (field.flags & 2) ? 1 : 0 }
    p.autoReviveAt (+0x2aa4c) = g_Now + (wait ? wait + 2 + (wait / 60) * 2 : 0) * 10
    → GameLog: 0x042B NC_LOG_GAME_MKED (killed by mob / unknown: charNo, map, xy, u16 mobId, u64 lostExp)
               or 0x0429 NC_LOG_GAME_PKED (killed by player: killerCharNo, map, xy, victimCharNo, …)
               + 0xC80B NC_SYSLOG_CHAR_VICTORY for a player killer
               + 0xC80A NC_SYSLOG_CHAR_DEATH { userNo, charNo, u8 zone, u8 kind (0 player, 1 mob, 2 none), u32 killerId, xy }
    p.vt[0xa38](1, 0, 0)                                    # script hook kind 1 = died
    map script interrupt 0xac
```

```pseudo
sp_LostExperienceByKilled(p, formula) → lost:               @ FUN_0042e210
    if p.<+0x2a5a6> (exp protected: a list entry at +0x2a5a8 must exist, e.g. KQ / protection item): return 0
    if p.level < g_ExpLossMinLevel (DAT_0da504a8, low byte): return 0           # client text: "Starting from level 20 …"
    cur = g_LevelExp[p.level], next = g_LevelExp[p.level + 1]                   # 64-bit table DAT_0da504a8 + 8 * level
    lost = formula(cur, next, field.row)
    if lost == 0 or lost > p.exp: return 0
    if p.exp − lost < cur: lost = p.exp − cur                                   # never below the start of the level
    p.exp −= lost
    send p: 0x2411 NC_BAT_EXPLOST_CMD { u32 lost }                              # client: "%u EXP lost."
    → WM:  0x1073 NC_CHAR_EXP_CHANGED_CMD { u16 wmHandle, u32 charNo, u64 exp }
    return lost
sp_LostExpWhenKilledByMob(cur, next, row):                   @ FUN_0042e030
    lost = (next − cur) / 100;  if row: lost = lost * row.ExpLostAtDeadByMob (+0xa7) / 1000   # 1 % of the level × the map rate (‰; 0 in towns)
sp_LostExpWhenKilledByPlayerInPKField(p, …, row):            @ FUN_0042e130
    lost = g_LevelTable[p.level].<+0x6b>;  if row: lost = lost * row.ExpLostAtDeadByPly (+0xa9) / 1000
```

### 7.3 Revive by skill: NC_SKILL_REPLYREVIVE_CMD `0x482A` (C→Z) @ FUN_00418a30

No payload (`PROTO_NC_SKILL_REPLYREVIVE_CMD` is empty). A revival skill does not raise the target at once:
`smo_SkillBlast` calls `target.so_ply_Revival()` (vt 0x7e0 @ FUN_0057ab90) when the skill has SS_REVIVAL. It sends the
empty `0x4829 NC_SKILL_SOMEONEREVAVALTOME_CMD` to the dead player (the client shows the accept dialog), sets
`p.flags5cb9 |= 0x40` ("revival offered") and adds an `isheal` result slot to the skill result packet. The answer:

```pseudo
sp_NC_SKILL_REPLYREVIVE_CMD(p):
    if p.field == null or (field.flags (+0x20c) & 2):       # map allows revival
        g_ShelterItem.Free(p.charNo)                        # the "keep buffs" shelter is not used on a skill revive
        if p.flags5cb9 & 0x40:
            p.flags5cb9 &= ~0x40
            sp_ReviveNow(p, 1000)                           # full HP (per mille of MaxHP)
            g_ShelterDie[p.charNo].ab_Recover(p);  g_ShelterDie.Free(p.charNo)    # IsSaveDie states come back
            return
    p.so_SendErrorCode(18, 0x2B, 0x1506)                    # 0x482B NC_SKILL_REPLYREVIVEFAIL_CMD { u16 err }; the client ignores it (original bug) Z03-B3

ShinePlayer::sp_ReviveNow(p, hpRate):                       @ FUN_0057d290
    p.mode = 1;  restore saved shape;  p.HP = MaxHP * hpRate / 1000;  dead flag (+0x1d7c) = 0
    sp_KQElementFunction(kqpi_KnockDownMinus)
    send p:   0x481E NC_SKILL_REVIVE_CMD { u32 hp, u32 sp, u32 lp }
    to sight: 0x481F NC_SKILL_SOMEONEREVIVE_CMD { u16 reviver = p.handle, u32 hp, u32 sp, u32 lp }
    p.flags5cb8 &= ~0x08
    set StaImmortal (291) for FieldList.immortalsec (row +0x3f) ms, how = 10;  asl_SendAfterLogin (re-send the abstate list)
    reset emoticon, move manager, last move, cast struct, fixed damage, regen timers; send 0x203E MOVESPEED
    flags1e78 &= ~0x02;  sp_LoginInit(p)
    if wedding status == 2: re-apply the wedding state (DAT_0087b4f4, permanent)
    class passive states (table DAT_1328c128 by class/grade): set each + BroadcastSet + Inform
    everyone targeting p gets fresh target info;  smo_SetCaptivate(0)
    maps with FieldList.KQ (row +0x36) == 1 but no running KQ instance: sp_2Roumen(p) (sent back to town)
```

The other revive paths (`NC_CHAR_REVIVE_REQ` at the town/menu, revive items, soul stones) belong to Z04/Z05; they end in
the same `sp_ReviveNow`.

---

## 8. Mob death, experience, level-up

### 8.1 Mob death

```pseudo
ShineMob::so_KilledBy(m, killer, dmg, aggroRate, dropArg):   @ FUN_00432760
    if m.flags1e78 & 8: return;  m.flags1e78 |= 8
    field.mobDeadCount.mdc_Count(m.mobId);  regen group: lastDeath = g_Now
    m.vt[0x700](killer, dmg * aggroRate / 1000)
    ShineMobileObject::so_KilledBy(m, killer, dmg)           # §7.1
    m.deadAt (+0x1fbc) = g_Now;  m.HP = 0;  MobChatManager::mcm_KilledChat(m)
    if killer == null: return
    m.killerHandle (+0x1fba) = killer.handle
    if the field is a KQ map: KQContributeList::kqcl_SendMobKill for the killer, or for every living party member within 1000 units
    killer.questDiary.MobKill(m.mobId) (FUN_005cbe70);  m.hitMeList.Finish(killer, dmg, m) (FUN_00483030)
    if MobKillAnnounce row for this mob:  → WM 0x2458 NC_BAT_WORLD_MOB_KILL_ANNOUNCE_CMD { u32 textIndex }
    if MobInfoServer.<+0x9b>:              → WM 0x244C NC_BAT_MOBSLAYER_CMD (pdb2017 name) { list from the mob's attacker object, 5 + 4 n bytes }
    looter = hitMeList.el_FindLooter()
    hitMeList.el_ExpDistribute(m, m.data, m.handle)          # §8.2
    if m.dropEnabled (+0x250c): ItemDropFromMob::DropIndexCluster::dic_ItemDrop(killer, mobData, regen, m, looter, dropArg)   # Z06
    party/raid quest check `ShineQuestDiary::sqd_MobDead`    # kill quests (Z08)
    if MobKillLog row: → GameLog 0x0791 NC_LOG_GAME_MK2_DEAD { u16 mobId, map, xy, u32 killerCharNo };  map-wide notice 0x38f
    if killer is a player: → GameLog 0xC80B NC_SYSLOG_CHAR_VICTORY (kind 1 mob)
    map script interrupt 0xac
```

### 8.2 Experience

```pseudo
HitMeList::EnemyList (mob + 0x22f0): one entry per attacker "unit" { kind 0 single / 1 party / 2 raid, u16 party|raid number,
                                     damage dealt, representative object };  +0x1a8 total damage
el_ExpDistribute(list, mob, mobData, mobHandle):             @ FUN_004828b0   → ExperienceDistribute::lid_Call per entry @ FUN_00483360
    base = MobInfoServer.<u32 +0x35> (MonEXP), or mob.vt[0xb9c]() when a script overrides it (so_mob_GetMonEXP)
    share = round(base * entry.damage / totalDamage)
    single (kind 0):            ed_GiveExperience(entry.obj)
    party (1) / raid (2):
        members = living members of that party/raid near the mob (FUN_00483260 / FUN_00483190); 0 → log "friendnumber zero"
        1 member: ed_GiveExperience(entry.obj)
        else: share += round(share * (g_PartyExpBonus[n] − 1.0))     # double table DAT_0075d480, n ≤ 20
              split among the members by level (FUN_00482620 / FUN_004826b0), each through the same level handicap
              (World/ExpRecalculation.txt tables ByPartyMem {0,1: 1000; 2: 1200; 3: 1400; 4: 1600; 5: 1800 ‰} and ByLevelDiff, and
               PartyBonusByMember.shn / PartyBonusByLvDiff.shn / PartyBonusLimit.shn; which loader fills which table was not traced)

ExperienceDistribute::ed_GiveExperience(ed, player):         @ FUN_00481890
    exp = share * LevelHandicap4ExperienceDouble::lh4ed_Handicap(player.level − MobInfoServer.<+0x42> (mob level))
                                                             # double table g_ExpLvHandicap (0xd55aa30 + 0x4b0), index = level difference
    player.so_GetExperienceFromMob(exp, mobData.id, mobHandle)   (vt 0x5c4)

ShinePlayer::so_GetExperienceFromMob(p, exp, mobId, mobHandle):   @ FUN_004302a0
    (StaRestExp checked);  for e in p.abstates: exp = SubActor.vt[0x44](e, exp)   # SubAbnormalStateActorExpUpRate (exp buffs, rest exp)
    exp = max((int) exp, 1)
    HuntingLog::MobHuntLog::mhl_Logging(p, mobId, exp)
    sp_GainExp(p, exp, mobHandle, mobId)
```

### 8.3 `ShinePlayer::sp_GainExp` @ FUN_0042d830

```pseudo
sp_GainExp(p, exp, mobHandle, mobId):
    if p.mode in {0, 3}: return                              # dead players get nothing
    if exp > 0 and mobId != −1 and p.so_weapontitle(&mobId) == 1:        # weapon title (licence) kill counter advanced
        send p: 0x5C0D NC_WT_MOBINC_CMD { u16 mobId }
    if p.<+0x2a5cc> == 1: exp = 0                            # exp blocked
    if p.level (+0x7f56) >= g_MaxLevel (DAT_0da50484): return
    p.exp (+0x7f57, u64) += exp
    send p: 0x240B NC_BAT_EXPGAIN_CMD { u32 expgain, u16 mobhandle }
    → WM:  0x1073 NC_CHAR_EXP_CHANGED_CMD { u16 wmHandle, u32 charNo, u64 exp }
    if p.exp < g_LevelExp[p.level + 1]:                      # 64-bit thresholds DAT_0da504b0 + 8 * level
        if p.exp > p.nextSaveExp (+0x7fb0): p.nextSaveExp = sp_NextSaveExperience(p)
        return
    # level up (one level per call)
    p.level += 1
    p.so_allparametercalculate();  MaxHP/MaxSP recomputed;  p.HP = MaxHP;  p.SP = MaxSP                 # full heal
    quest diary level hook (FUN_005cc2f0);  name/level cache (FUN_005b8f70);  p.<+0x173e8>.vt[4](level)
    send p:   0x240C NC_BAT_LEVELUP_CMD { u8 level, u16 mobhandle, CHAR_PARAMETER_DATA (0xe8 bytes, so_fill_CHAR_PARAMETER_DATA) }   # 0xed total
    to sight (not p): 0x240D NC_BAT_SUMEONELEVELUP_CMD { u16 handle, u16 mobhandle }
    WholeSaver::ws_savelevel2worldmamager(p)
    → WM:      0x1074 NC_CHAR_LEVEL_CHANGED_CMD { u16 wmHandle, u32 charNo, u8 level }
    → GameLog: 0x041E NC_LOG_GAME_LEVEL_UP { u32 charNo, map[12], u32 x, u32 y, u8 level, u64 exp }
    WholeSaver::ws_save2DB(p, 1, 8)
    if p is an academy member (vt 0x858) with an academy guild:
        → GameDB: 0x986B NC_GUILD_ACADEMY_DB_ACADEMY_REWARD_REQ { u16 handle, u32 charNo, u32 charNo, u32 guildNo, u8 level }
    free = p.vt[0x6b8]() (empower points earned by level) − csl_EmpowerSummary(p.skills) (points spent)
    if free > 0: send p: 0x4810 NC_SKILL_EMPOWPOINT_CMD { u8 restempow = free }
    stat points (FUN_0058bd10), level hooks vt 0x20 / 0x450 / 0x44c, p.nextSaveExp, brief block level (+0xc5),
    p.vt[0xb18](), level-up reward table (FUN_0046d8e0(&DAT_14d42940, p))
```

Client: `0x240B` adds the exp and prints the gain; `0x240C` (`FUN_004aa3d0`) replaces the whole parameter block, plays the
level-up effect ("Aura120") and at the class-change levels shows the promotion hint; `0x4810` prints
"Skill Empower %d point was acquired."; `0x104D` opens the death menu (once per session it adds "Starting from level 20,
character will lose part of the exp when dying.").

---

## 9. Skill learning, empowering, unlearning

### 9.1 NC_SKILL_EMPOWALLOC_REQ `0x4811` (C→Z) @ FUN_0044f150

Payload *(pdb2017, confirmed)*: `{ u16 skill, SKILL_EMPOWER plus, SKILL_EMPOWER minus }`, `SKILL_EMPOWER` = u16 bit field
`damage:4 | sp:4 | keeptime:4 | cooltime:4`. Reply: `0x4814 NC_SKILL_EMPOWALLOC_ACK { u16 skill, u16 err }`
(`so_ply_SkillEmpowerSetResult` @ FUN_00518d20).

```pseudo
sp_NC_SKILL_EMPOWALLOC_REQ(p, pkt):
    if not (0x76 >> p.mode & 1) (modes 1, 2, 4, 5, 6):       reply (0xFFFF, 0x882); return
    for each of the 4 nibbles: if plus.n != 0 and minus.n != 0:   reply (skill, 0x889); return     # not both directions on one line
    removed = minus.damage + minus.sp + minus.keeptime + minus.cooltime
    if removed != 0:                                         # taking points back costs one "skill redistribution" item each
        have = total lot of item g_EmpowResetItem (DAT_14d50496) in unlocked inventory cells
        if have < removed:                                   reply (skill, 0x886); return
    delta = Σ plus − Σ minus
    if csl_EmpowerSummary(p.skills) + delta > p.vt[0x6b8]() (points available at this level):
        log "Too many points";                               reply (skill, 0x883); return
    if not csl_EmpowerAlloc(p.skills, &pkt, &newBits):       reply (skill, 0x884); return           # applied in memory at once
    → GameDB: 0x4812 NC_SKILL_EMPOWALLOC_DB_REQ
        { u16 zonehandle, u32 chrregnum, u16 lockindex, u16 skill, u8 bUseItem, u16 skill, SKILL_EMPOWER newBits, SKILL_EMPOWER newBits,
          u16 lockindex2, PROTO_ITEMDELETEREQUEST-style list: u8 count|0x80 = last cell is partly used,
          [ partly used cell: new lot + item key + attribute blob ], count × u64 item keys to delete }
        the cells are locked in p.inventoryLocking (+0xfaa8) under p.lockIndex (+0xfaac, then incremented) until the answer

CharaterSkillList::csl_EmpowerAlloc(list, req, out):         @ FUN_00448570
    cur = csl_EmpowerStruct(csl_MaximumSkill(req.skill))     # bits of the highest learned step of this skill line
    for each nibble: cur.n + plus.n ≤ 5 ("Too many point1…4") and minus.n ≤ cur.n ("Too many point5…8"), else false
    entry = list.Find(req.skill) (FUN_004465b0); null → "Not learn", false
    entry.empower (+8) = cur + plus − minus (per nibble);  *out = entry.empower;  return true

GameDBSession::gds_NC_SKILL_EMPOWALLOC_DB_ACK 0x4813 (DB→Z)  @ FUN_0044f7d0
    { ref (u16 zonehandle, u32 chrregnum), u16 lockindex, u16 skill, u16 err, u8 bUseItem }
    p = som_GetObject(zonehandle), charNo must match
    p.so_ply_SkillEmpowerSetResult(err, skill)               # 0x4814 to the client
    if err != 0x881: p.so_Disconnect(0x68a, 0, 0)            # DB refused after the memory change: kick to resync
    if bUseItem == 1: p.inventoryLocking.Release(p, lockindex, 0)    # commits the item deletion; failure only logged
```

Empower effects are read at cast time: `damage` → `nT0`, `sp` → `nT1`, cool time → `nT2`, keep time → `nT3` columns of
`ActiveSkill.shn` (index = points 1…5) (§5.3, §5.6).
Client (`FUN_004acf60`): `err == 0x881` "Skill Empower succeeded.", anything else "Skill Empower failed." (+ debug `errcode:%d`).

| err | Meaning (server side) |
|---|---|
| 0x881 | success (from the DB) |
| 0x882 | wrong player mode |
| 0x883 | more points than the level gives |
| 0x884 | `csl_EmpowerAlloc` refused (limit 5 per line, skill not learned) |
| 0x886 | not enough redistribution items |
| 0x889 | plus and minus on the same line |

### 9.2 Empower reset answers (DB→Z)

The request side (`0x480A NC_SKILL_EMPOW_RESET_REQ`, item use → `0x480B …_DB_REQ`) is an item effect (Z04).

```pseudo
gds_NC_SKILL_EMPOW_RESET_DB_SUC_ACK 0x480D { ref }           @ FUN_0044ef50
    p by ref (charNo must match);  p.vt[0x6bc]()             # csl_EmpowerClear: all skills' empower bits = 0
    send p: 0x480F NC_SKILL_EMPOW_RESET_SUC_ACK { u8 totalempow = p.vt[0x6b8]() }    # client: "Skill Empower Point has been reset."
gds_NC_SKILL_EMPOW_RESET_DB_FAIL_ACK 0x480C { ref }          @ FUN_0044f080
    p.so_SendProtocol(18, 14)                                # 0x480E NC_SKILL_EMPOW_RESET_FAIL_ACK (empty): "Failed to reset the skill Empower point."
```

### 9.3 Skill teach answers (DB→Z)

`0x4801 NC_SKILL_SKILLTEACH_REQ` is sent to the GameDB by the skill-book item (Z04), by `&learnskill`, and by §9.4.
Layout as built in §9.4: `{ u16 zonehandle, u32 chrregnum, u32 chrregnum, u16 skill, u8 ispassive, u16 = 0xFFFF }`.

```pseudo
gds_NC_SKILL_SKILLTEACHSUC_ACK 0x4802 { ref, u16 skillid, u8 ispassive }      @ FUN_0044ec80
    p by ref, not closing, charNo matches
    if not ispassive: p.vt[0x624](skillid)                   # add to CharaterSkillList
    else: p.vt[0x620](); p.vt[0x364](); p.vt[0x368]()        # add to CharacterPassiveList, re-apply passive parameters and passive abstates
    send p: 0x4804 NC_SKILL_SKILL_LEARNSUC_CMD { u16 skillid, u8 ispassive }  # client: "You learned %s skill."
    p.vt[0x528]()                                            # stat recalculation
    if ispassive: → WM 0x4820 NC_SKILL_PASSIVESKILL_LEARN_CMD { u16 wmHandle, u32 charNo, u16 skillid }
gds_NC_SKILL_SKILLTEACHFAIL_ACK 0x4803 { ref }               @ FUN_0044ee70
    p.so_SendProtocol(18, 5)                                 # 0x4805 NC_SKILL_SKILL_LEARNFAIL_CMD: "Failed to learn the skill."
```

### 9.4 NC_SKILL_PRODUCTFIELD_REQ `0x4822` (C→Z) @ FUN_0046c820

Payload *(pdb2017, confirmed)*: `{ u16 mainskill }`. Chooses a production profession. Reply
`0x4823 NC_SKILL_PRODUCTFIELD_ACK { u16 mainskill, u16 err }`.

```pseudo
    if not (0x16 >> p.mode & 1) (modes 1, 2, 4):             err 0xB04
    else if mainskill not one of the five production base skills g_ProduceSkill[0…4] (DAT_13286cfc … DAT_13286d04):
        log "ProductField Error";                            err 0xB12
    else if csl_IsLearn(p.skills, mainskill):                err 0xB13      # already has it
    else if (number of the five already learned) >= 2:       err 0xB14      # at most two professions
    else:
        send ACK err 0xB01 (accepted)
        → GameDB: 0x4801 NC_SKILL_SKILLTEACH_REQ { u16 handle, u32 charNo, u32 charNo, u16 mainskill, u8 0, u16 0xFFFF }
        return                                               # the skill arrives with 0x4802 → 0x4804
    send ACK err
```

Client (`FUN_004ad070`): only `0xB04` has a text ("You cannot select the production skill in your current status.");
`0xB01` is silent, other codes show nothing (original bug) Z03-B4.

### 9.5 NC_SKILL_UNLEARN_REQ `0x4824` (C→Z) @ FUN_0057ad80

Payload *(pdb2017, confirmed)*: `{ u8 slot, u16 skill }` (`slot` = inventory cell of the skill-erase item). Reply
`0x4827 NC_SKILL_UNLEARN_ACK { u16 skill, u16 err }`.

```pseudo
sp_NC_SKILL_UNLEARN_REQ(p, pkt):
    if not (0x46 >> p.mode & 1) (modes 1, 2, 6):             ACK 0x1502
    if not csl_IsLearn(p.skills, pkt.skill):                 ACK 0x1503
    if pkt.slot >= inventory size: log "wrong slot";         ACK 0x702
    if p.inventoryLocking.IsLocked(9, pkt.slot):             ACK 0x70A
    cell = p.inventory[pkt.slot]
    if cell.itemId != g_SkillEraseItem (DAT_14d504ae):       ACK 0x702
    if cell lot < 1 or no ItemInfo row:                      ACK 0x703
    UseEffect::UseItemNormal::uib_AfterCast(p, inventory, itemRow, pkt.slot)      # the generic "consume one item" path (Z04)
    p.skillEraseSlot (+0x2a7a2) = g_SkillEraseQueue.Store(p.handle, pkt.skill)    # FUN_00579a90: 128 × { u16 handle, u16 skill }
    # no ACK yet

ShinePlayer::so_ply_SkillEraseItemUseSuccess(p):             @ FUN_0057b060   (called when the item DB transaction succeeded)
    q = g_SkillEraseQueue[p.skillEraseSlot];  if q.handle != p.handle: log, return
    → GameDB: 0x4825 NC_SKILL_ERASE_REQ { u16 handle, u32 charNo, u16 skill }

GameDBSession::gds_NC_SKILL_ERASE_ACK 0x4826 { ref, u16 skill, u16 err }          @ FUN_0057b3f0
    p by ref, not closing, charNo matches → p.so_UnlearnSkillAck(&pkt.ref)        (vt 0x97c)

ShinePlayer::so_UnlearnSkillAck(p, m):                       @ FUN_0057f200
    skill = m.skill;  err = m.err
    if err == 0x1501:
        if skill < 30000: csl_UnLearn(p.skills, skill)                            # active skill (and its lower steps)
        else: skill −= 30000;  err = 0x1505                                       # passive skills travel as id + 30000
              cpl UnLearn (p + 0x17d30, skill);  p.vt[0x364](); p.vt[0x368]()     # re-apply passives
    send p: 0x4827 NC_SKILL_UNLEARN_ACK { u16 skill, u16 err }
```

Client (`FUN_004acd80`): `0x1501` active skill removed → "Deleted %s skills" and the skill leaves the skill window /
quick slots; `0x1505` passive removed (same text, passive list); any other code → nothing shown except the generic item
errors. "Skill has been successfully reset." belongs to the full reset path.

| err | Meaning |
|---|---|
| 0x1501 / 0x1505 | removed (active / passive) |
| 0x1502 | wrong player mode |
| 0x1503 | skill not learned |
| 0x702 | bad slot or not the erase item |
| 0x703 | empty cell / lot 0 |
| 0x70A | cell locked by another transaction |

---

## 10. Client cross-check (packets sent by this subsystem)

Handlers are in the `GameFrameWork` dispatcher (`FUN_004be490`); source: `re-data/client-handlers.json` (C01) and the
client export.

| Opcode | Name | Client handler | Client use |
|---|---|---|---|
| 0x2402 | NC_BAT_TARGETINFO_CMD | FUN_00499fa0 | order 0 → target frame, 1 → target-of-target frame |
| 0x243F | NC_BAT_ASSIST_ACK | FUN_0049a2b0 | targets the returned handle |
| 0x244D | NC_BAT_TARGETCHANGE_CMD | FUN_0049a2e0 | sets / clears the current target (0xFFFF) |
| 0x2447 | NC_BAT_SWING_START_CMD | FUN_004b9200 | plays swing `actioncode` at `attackspeed`, remembers `damageindex` |
| 0x2448 | NC_BAT_SWING_DAMAGE_CMD | FUN_004a2620 | damage number, miss/block/critical text, HP bar (`resthp`, ordered by `hpchangeorder`), death |
| 0x2449 | NC_BAT_SOMEONESWING_DAMAGE_CMD | FUN_004a2850 | hit reaction and HP of third parties |
| 0x243D | NC_BAT_CEASE_FIRE_CMD | FUN_004a2570 | stops the attack loop of `handle` |
| 0x2434 | NC_BAT_SKILLBASH_CAST_FAIL_ACK | FUN_004aa840 | system message by code (§5.2 table), cast state reset |
| 0x2435 | NC_BAT_SKILLBASH_CAST_SUC_ACK | inline | cast state = 3 (casting) |
| 0x244E / 0x2450 | …HIT_OBJ_START / …HIT_FLD_START | FUN_004b8cb0 / FUN_004b7810 | own cast animation + cast bar; remembers `index` |
| 0x244F / 0x2451 | SOMEONE… variants | (same family) | other players' cast animation |
| 0x2457 | NC_BAT_SKILLBASH_HIT_BLAST_CMD | FUN_004a22e0 | fires the skill effect of `caster` for `index` |
| 0x2452 | NC_BAT_SKILLBASH_HIT_DAMAGE_CMD | FUN_004b79f0 | per target: damage / heal number, flags, HP, death |
| 0x2438 | NC_BAT_SOMEONESKILLBASH_CASTCUT_CMD | FUN_0049a3b0 | cancels the cast of `caster` |
| 0x2445 | NC_BAT_SKILLBASH_CASTABORT_ACK | FUN_0049a540 | stops the own cast bar (payload not read) |
| 0x2453 | NC_BAT_SOULCOLLECT_CMD | FUN_004a4120 | soul counter on the target |
| 0x2455 | NC_BAT_ABSTATE_ERASE_ACK | FUN_004b0ce0 | §6.5 |
| 0x2427 / 0x2428 | NC_BAT_ABSTATESET_CMD / RESET | (C01 list) | buff effect on / off for `handle` |
| 0x2429 / 0x242A | NC_BAT_ABSTATEINFORM(_NOEFFECT)_CMD | (C01 list) | own buff icon with remaining time |
| 0x240B / 0x240C / 0x240D / 0x2411 | EXPGAIN / LEVELUP / SUMEONELEVELUP / EXPLOST | FUN_0049a150 / FUN_004aa3d0 / – / FUN_004aa7d0 | §8.3, §7.2 |
| 0x244B | NC_BAT_PKINPKFIELD_CLIENT_CMD | FUN_004a29a0 | PK notice |
| 0x104D | NC_CHAR_DEADMENU_CMD | FUN_004a9940 | death menu with the wait time |
| 0x481E / 0x481F | NC_SKILL_REVIVE_CMD / SOMEONEREVIVE | FUN_004a2da0 / – | stand up, set HP/SP/LP |
| 0x4829 | NC_SKILL_SOMEONEREVAVALTOME_CMD | FUN_00575f30 | "accept revival?" dialog → 0x482A |
| 0x482B | NC_SKILL_REPLYREVIVEFAIL_CMD | inline | accepted and ignored |
| 0x4804 / 0x4805 | SKILL_LEARNSUC / LEARNFAIL | FUN_004acb60 / FUN_00479fa0 | §9.3 |
| 0x480E / 0x480F / 0x4810 / 0x4814 | empower replies | FUN_00479fa0 / FUN_004acf20 / FUN_004ad020 / FUN_004acf60 | §9.1, §9.2 |
| 0x4821 | NC_SKILL_COOLTIME_CMD | FUN_0049a9e0 | starts the cooldown display |
| 0x4823 / 0x4827 | PRODUCTFIELD_ACK / UNLEARN_ACK | FUN_004ad070 / FUN_004acd80 | §9.4, §9.5 |

No packet capture in the repository covers combat (`re-data/captures/` is absent in this checkout), so nothing here is
marked *(captured)*.

---

## Original-server bugs

Behaviour of the 2016 zone combat code that looks unintended. A faithful rebuild reproduces it; a fixed rebuild should
change it deliberately. All items are read in the code; none was observed in a capture.

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z03-B1 | 0x2440 / 0x2441 §5.2, §5.5 | 0xFC0 is also used for an invisible target, a map that forbids revival and a caster with StaEthereal | client says "Cannot use the skill while in nonbattle mode." for unrelated refusals | specific codes (0xFC6, 0xFCE, …) |
| Z03-B2 | 0x2440 §5.2 | an unknown target handle reports 0xFC4 | client says "Casting another skill now." | 0xFCB "Cannot find the target." |
| Z03-B3 | 0x482A §7.3 | refusal sends 0x482B NC_SKILL_REPLYREVIVEFAIL_CMD | the client accepts and ignores it: a refused revive is silent | a reply the client shows |
| Z03-B4 | 0x4822 §9.4 | codes 0xB12 (not a production skill), 0xB13 (already learned), 0xB14 (two professions) | no client text: the refusal is silent | codes with texts |

## 11. Not reconstructed / uncertain

- **Formulas.** Hit rate for normal attacks, the damage core and its modifiers are read from the FPU code and the log
  strings. Not fully traced: the two skill hit-rate functions (the "As Normal" / "As Skill" combination with the levels),
  the exact operand order inside `roe_MinWC/MaxWC` (the term list is certain, the final `/10` and which value passes
  through `vt[0x938]` are *(inferred)*), one defender-side operand of the critical rate, all magical variants (same
  shape, different stat indices), the skill `AttackPower/DefendPower` functions, the stun chance `FUN_00500170`, the
  PvP rating arithmetic. `g_HitRateScale` (DAT_00870dd8) is a runtime double (default not read).
- **Stat matrix.** Layer and stat meanings come from debug labels; stats 3, 4, 10–23 and the layers without a label are
  not identified. `so_allparametercalculate` (Z07) fills it.
- **`smo_SkillBlast`** (790 lines) is summarised: the order of its parts and the result flags are certain, the individual
  `SkillSpecial` handlers (mana burn, dispel variants, HP→SP, jump/dash, chain targets, steal enchant, summon,
  metamorphosis) were not read one by one. `sbe_BlastLocate`, `alsst_SkillBlast*`, `mdt_PostSkillBlast`,
  `smo_Dispel`, toggle skills (`ToggleSkill.shn`, 0x245C/0x245D), magic fields (`ShineMagicField`, `StateField.shn`,
  0x245A area DoT) and `smo_ReflectionDamage` (0x245B) are only named.
- **SkillEntry layout** beyond the fields listed in §5.1 (the decoded special table +0xa0…+0x260) is inferred from use.
- **Where the cooldown is set** (`csl_SetCoolTime` → `0x4821 NC_SKILL_COOLTIME_CMD {u16 skill, u32 sec}`, `smo_SkillCooltimeSet`,
  `csl_GetDelayGroup` for shared cooldown groups, `csl_SufferingAttack_CoolTimeMinus`) was not read line by line.
- **Abnormal states.** `asl_Routine`'s per-element iterator, the individual actor classes (DoT/HoT amounts, shields,
  bomb, magic field), `so_RecalcAbstateParam` / `aeo_ParameterEnchant` (which `SubAbstateAction` writes which matrix
  cell), party states (`PartyState1…5`, `PartyRange`, `PartyEnchantNumber`), `sp_AbstateCheck`, `asl_CanEnchant`,
  `GroupAbState.shn`, `ChargedDeletableBuff.shn`, `MobAbStateDropSetting.shn` and the save/restore path
  (`AbstateShelter`, `NC_CHARSAVE_ABSTATE`) are described from their call sites only. The SubState → actor table is
  filled at start-up; the pairing in §6.1 follows class names and the 2017 enum, not the table.
- StaACMode (201) / StaMRMode (202) turn
  physical/magical damage into healing in `FUN_0042aeb0`; their actors (SUBAB_ACMODE 73 / MRMODE 74) were not read. 392/393 (StaCannotChangeTarget / StaShadowBinding) are set on the caster by taunt-type skills.
- **Mob side.** Mob normal attacks and skills (`so_attack`, `MobAttackSequence`, aggro lists `MobTarget*`), servants and
  pets, doors, `sm_Scream4Rescue`, the so_Bash packet family (§3.5) in live use: Z09.
- **Experience.** The party/raid split helpers (FUN_00482500 … FUN_004826b0), the bonus tables' loaders and the
  per-mille columns of `FieldList` used for exp loss (+0xa7, +0xa9) are not identified by column name. `g_ExpLossMinLevel`
  shares its address with the level-exp table base (the first entry doubles as the threshold).
- **0x244C** has no name in the 2016 binaries; `NC_BAT_MOBSLAYER_CMD` is *(pdb2017)*. Its payload builder
  (`mob+0x2234 .vt[0x30]`) was not read. `0x244A` carries two 2017 names (`NC_BAT_PKINPKFIELD_WMS_CMD` /
  `NC_BAT_REALLYKILL_CMD`, same value).
- The item / soul-stone / town revive paths: Z04/Z05. (`FUN_0057ab90` carries the profiler string
  `ShineMagicField::so_ply_Revival`; it is the ShinePlayer slot 0x7e0.)
- **Costume weapon / shield charges** (`sp_CostumWeaponChargeDecrease_*`, `WeaponChargeOk` FUN_00562160): Z06.
