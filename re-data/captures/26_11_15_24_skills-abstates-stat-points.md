Scenario 24 (docs/plan/capture-scenarios.md): skills, abstates, stat points
- recorded on the server PC, loopback + LAN interface, filter of capture-guide.md (client ports + server links, 9411 included)
- account A: "admin", character "X24A" (created as Fighter, made Gladiator 100 / GM 100 by tools/capture/24/24-prep.sql), world "Enid"
- account B: "testaccountB", character "X24B" (created as Cleric, made HighCleric 20 / GM 100 by 24-prep.sql)
- clients run on: <one PC, two instances | two PCs>
- 24-prep.sql output: X24A level ___ class ___ spent ___ (expected 100 / 4 / 127); X24B level ___ class ___ (20 / 7)
- client A and client B both start at RouN, next to Skill Master Ruby (6307,7147)
- write every message text the client shows; "nothing" is an answer too

Start
- capture started; both clients started; A logged in, then B
- A's login burst: GM level message / free stat points shown in the character window: ___ (expected 3), free empower points: ___
- gmtype 24-setupA.txt into A, 24-setupB.txt into B; "You learned ... skill" messages: A ___ / B ___

Step 1: learn a skill at the skill master
- A bought "Slice and Dice [01]" from Skill Master Ruby (price ___), used the book -> message: ___

Steps 2 and 3, part 1: without reset items
- empower: A put 1 point into Slice and Dice (damage) -> message: ___ ; free empower points before ___ / after ___
- empower: A took the point back -> message: ___ (or: the client did not allow it)
- stats (character window before: STR ___ END ___ DEX ___ INT ___ SPR ___): A added 1 point to STR three times
  -> STR ___ ; free points left ___ ; other values that changed (attack, HP ...): ___
- stats: A tried a fourth point -> message: ___ (or: the + button was disabled)
- stats: A tried to remove 1 STR point -> message: ___ (or: no - button)

Steps 2 and 3, part 2: with reset items (gmtype 24-items.txt into A first)
- empower: A took the point back with the Skill Reset Scroll -> message: ___ ; scrolls left ___ ; free empower points ___
- empower: A put 1 point in again, then used the Full Skill Reset Capsule -> message: ___ ; free empower points ___
- stats: A removed 1 STR point with the Stat Reset Scroll -> message: ___ ; scrolls left ___ ; free points ___
- stats: A used the Full Stat Reset Capsule -> message: ___ ; free points ___ (expected 130)

Step 4: cast abort and ground-target skill
- B cast "Invincible [01]" on itself and pressed a movement key at once -> cast bar stopped? ___ ; message: ___
- B cast it again without moving (completes) -> ok? ___
- A (Titanic Axe equipped) cast "Dash [01]" on a free spot on the ground -> A moved there? ___ ; B saw it? ___
- A cast Dash at a spot far out of range -> message: ___

Step 5: toggle skill "Heat of Fury [01]" (axe equipped)
- A cast it -> shortcut slot marked active? ___ ; buff icon? ___ ; HP drains? ___
- A cast it again -> off? ___
- on, then A unequipped the axe -> switched off by itself? ___ ; re-equipped the axe
- A typed &sethp 100, tried to switch it on -> message: ___ ; then &fullpoint
- on, &sethp 100 while it is on -> switched off by itself? ___ ; then &fullpoint
- on, A walked through the Roumen town portal to ___ (map) -> on the new map: slot still active? ___ buff icon still there? ___
- A cast it once on the new map -> it switched on / off? ___ ; cast again -> ___
- A back to RouN (&linkto RouN 6443 9850, the Slime area); B &linkto RouN 6500 9850

Step 6: abstates and their reset conditions (A at the slimes, B in sight; A types &staticdamage 1 first so slimes survive)
- assist: B targeted a slime; A targeted B and used assist -> A's target became the slime? ___ (key / button used: ___)
- &setabstate StaNeglect 60000, then walk -> icon gone? ___ ; B saw it go? ___
- &setabstate StaNeglect 60000, then run -> gone? ___
- &setabstate StaNeglect 60000, then attack a slime -> gone? ___
- attacked a slime, stopped, &setabstate StaNeglect 60000, stood still while the slime hit A -> still there after ___ hits? ___
- &resetabstate
- &setabstate StaHide 60000, then walk -> still there? ___ ; run -> still there? ___ ; attack a slime -> gone? ___
- attacked a slime, stopped, &setabstate StaHide 60000, slime kept hitting? ___ -> gone after the first hit? ___
- equipped Vulcan Sword + Heater Shield; &setabstate StaBuckler 60000; walk -> still there? ___ ; attack -> still there? ___ ;
  took the shield off -> gone? ___
- &resetabstate, equipped the Titanic Axe again

Step 7: damage over time (Diamond Trumpy casts "Venomous Shot", StaDiaTrumpyPoison: 200 per 3 s)
- &mobbreed DiaTrumpy 1 60 n 1, A attacked it (still &staticdamage 1) -> poisoned within a minute? ___ ; ticks seen: ___
- (only if not poisoned) &setabstate StaDiaTrumpyPoison 20000 -> ticks seen: ___ ; source used: mob / &setabstate

Step 8: death and revive by skill
- A typed &sethp 1 while the mob / poison was on A -> A died, killed by ___ ; death menu shown? ___ ; EXP lost message: ___
- B typed &killallmob, then cast "Revive [01]" on A -> A got the accept dialog? ___
- A declined -> message on A ___ / B ___
- B cast Revive again after the cooldown (30 s) -> A accepted -> A alive with HP ___ ; B saw A stand up? ___
- A typed &staticdamage 0

End
- both logged out to the login screen; capture stopped
