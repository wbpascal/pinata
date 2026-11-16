Scenario 24 (docs/plan/capture-scenarios.md §3 "24"): skills, abstates, stat points
- recorded on the server PC by tools/capture/24/24-server.ps1 capture-start (dumpcap, loopback + LAN, filter of capture-guide.md)
- account A: "admin", character "X24A" (created as Fighter, made Gladiator 100 / GM 100 by 24-server.ps1 prep), world "Enid"
- account B: "testaccountB", character "X24B" (created as Cleric, made HighCleric 20 / GM 100 by prep)
- prep also wrote: A money 100 000 and skills 7300 "Heat of Fury [01]" + 452 "Dash [01]"; B skills 1620 "Revive [01]" +
  1800 "Invincible [01]"; tutorial done for both; both start at RouN next to Skill Master Ruby (6307,7147)
- prep output: X24A level 100 class Gladiator spent ___ (expected 100 / 4 / 127); X24B level 20 class HighCleric (20 / 7); Each got their necessary skill
- server DB readings: out/26_11_16_24_skills-abstates-stat-points-db.txt (copy it next to this file)
- clients run on: one PC, two instances
- manually typed setup files (gmtype.ps1 did not work)
- write every message text the client shows; "nothing" is an answer too

Start
- capture started; A logged in, then B; tutorial question shown? no (expected no)
- A: GM level shown (GM commands work)? yes ; free stat points in the character window: 3 (expected 3) ; free empower points: 49
- B: Revive and Invincible in the skill list? yes ; A: Heat of Fury and Dash in the skill list? yes
- typed 24-setupA.txt into A, 24-setupB.txt into B; Titanic Axe, Vulcan Sword, Heater Shield in A's inventory? yes

Step 1: learn a skill at the skill master
- A bought "Slice and Dice [01]" from Skill Master Ruby (price 41), used the book -> message: You learned Slice and Dice [1] skill

Steps 2 and 3, part 1: without reset items
- empower: A put 1 point into Slice and Dice (damage) -> Pressed complete -> message: Skill empower succeeded ; free empower points before 49 / after 48
- empower: A tried to take the point back -> message: client did not allow that (or: the client did not allow it)
- stats (character window before: STR 594 (+60) END 405 (+67) DEX 272 INT 100 SPR 218): A added 1 point to STR three times
  -> STR 593 (+63) ; free points left 0 ; other values that changed (attack, HP ...): none
- stats: A tried a fourth point -> message: can press plus button but does not change anything (pressed it)
- stats: A tried to remove 1 STR point -> message: no - button
- server: .\24-server.ps1 snapshot -Label "after steps 2-3 part 1" -> STR in the DB 53 (expected 63) ; Skills from db:
```
sID|nSkillNo|nSkillLevel|nSkillPowerDemage|nSkillPowerSP|nSkillPowerKeepTime|nSkillPowerCoolTime
---|--------|-----------|-----------------|-------------|-------------------|-------------------
X24A|452|0|0|0|0|0
X24A|7300|0|0|0|0|0
X24A|29001|1|0|0|0|0
X24A|29200|1|0|0|0|0
X24A|29201|1|0|0|0|0
X24A|29202|1|0|0|0|0
X24A|29203|1|0|0|0|0
X24A|29204|1|0|0|0|0
X24A|29205|1|0|0|0|0
X24A|29206|1|0|0|0|0
X24A|29209|1|0|0|0|0
X24A|29429|1|0|0|0|0
X24A|29430|1|0|0|0|0
X24A|29468|1|0|0|0|0
X24A|29469|1|0|0|0|0
X24A|29480|1|0|0|0|0
X24A|29482|1|0|0|0|0
X24A|29484|1|0|0|0|0
X24A|29498|1|0|0|0|0
X24A|29499|1|0|0|0|0
X24A|29500|1|0|0|0|0
X24A|29613|1|0|0|0|0
X24A|29614|1|0|0|0|0
X24A|29644|1|0|0|0|0
X24A|29645|1|0|0|0|0
X24A|29745|1|0|0|0|0
X24A|29746|1|0|0|0|0
```

Steps 2 and 3, part 2: with reset items (typed 24-items.txt into A first)
- empower: A took the point back with the Skill Reset Scroll -> message: Skill empower succeeded ; scrolls left 1 ; free empower points 49
- empower: A put 1 point in again, then used the Full Skill Reset Capsule -> message: nothing ; free empower points 49
- stats: A removed 1 STR point with the Stat Reset Scroll -> message: nothing ; scrolls left 1 ; free points 1
- stats: A used the Full Stat Reset Capsule -> message: nothing ; free points 130 (expected 130)
- server: .\24-server.ps1 snapshot -Label "after steps 2-3 part 2" -> spent in the DB 0 (expected 0)

Step 4: cast abort and ground-target skill
- B cast "Invincible [01]" on itself and pressed a movement key at once -> cast bar stopped? yes ; message: nothing
- B cast it again without moving (completes) -> ok? yes
- A (Titanic Axe equipped) cast "Dash [01]" on a free spot on the ground -> A moved there? yes ; B saw it? yes
- Waited for cooldown (1 minute)
- A cast Dash at a spot far out of range -> A tries to go closer before casting. As soon as in range, casts it.

Step 5: toggle skill "Heat of Fury [01]" (axe equipped)
- A cast it -> shortcut slot marked active? yes ; buff icon? yes ; HP drains? yes (76 damage pro instance)
- A cast it again -> off? yes
- on, then A unequipped the axe -> switched off by itself? yes ; re-equipped the axe
- A typed &sethp 100, tried to switch it on -> message: Failed to cast the skill ; then &fullpoint
- on, &sethp 100 while it is on -> switched off by itself? yes ; then &fullpoint
- on, A walked through the Roumen town portal to Forest of Mist (map) -> on the new map: slot still active? no buff icon still there? no
- A cast it once on the new map -> it switched on / off? on ; cast again -> off
- typed 24-moveA.txt into A (back to RouN at the slimes, &staticdamage 1), then 24-moveB.txt into B

Step 6: abstates and their reset conditions (A at the slimes, B in sight)
- assist: B targeted a slime; A targeted B and used assist -> A's target became the slime? no (key / button used: Assist action)
- only after B started attacking the slime, did A target the slime as well when pressing assist
- &setabstate StaNeglect 60000, then walk -> icon gone? yes ; B saw it go? yes
- &setabstate StaNeglect 60000, then run -> gone? yes
- &setabstate StaNeglect 60000, then attack a slime -> gone? yes
- attacked a slime, stopped, &setabstate StaNeglect 60000, stood still while the slime hit A -> still there after 10 hits (mostly misses)? yes
- &resetabstated
- &setabstate StaHide 60000, then walk -> still there? yes ; run -> still there? yes ; attack a slime -> gone? yes
- attacked a slime, stopped, &setabstate StaHide 60000, slime kept hitting? yes -> gone after the first hit? yes
- equipped Vulcan Sword + Heater Shield; &setabstate StaBuckler 60000; walk -> still there? yes ; attack -> still there? yes ;
  took the shield off -> gone? yes
- &resetabstate, equipped the Titanic Axe again

Step 7: damage over time (Diamond Trumpy casts "Venomous Shot", StaDiaTrumpyPoison: 200 per 3 s)
- typed 24-step7.txt into A (&fullpoint, &staticdamage 1, one Diamond Trumpy); A attacked it -> poisoned within a minute? yes ; ticks seen: more than 10 (not fully counted) but duration is 4-5 minutes so a while

Step 8: death and revive by skill
- A typed &sethp 1 while the mob / poison was on A -> A died, killed by none ; death menu shown? no 
- A attacked Diamon Trumpy again; A died; death menu shown ; EXP lost message: none
- B typed &killallmob, then cast "Revive [01]" on A -> A got the accept dialog? death menu shown "Revival" option
- A cannot decline, only wait until timeout
- B cast Revive again after the cooldown (30 s) -> A accepted -> A alive with HP 3836 (full) ; B saw A stand up? yes
- A typed &staticdamage 0

End
- both logged out to the login screen; capture stopped (Ctrl+C in the dumpcap window)
- server: .\24-server.ps1 cleanup -> X24A / X24B deleted (p_Char_Delete returned 0 for both)? ___
