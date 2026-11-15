Scenario 21 (docs/plan/capture-scenarios.md): items II: drop, split, storage, use, shop
- recorded on the server PC, loopback + LAN interface, filter of capture-guide.md (client ports + server links, 9411 included)
- account A: "admin", character "Test2" (GM level 100, S1), world "Enid"; account B: "testaccountB", character "X14B"
- setup typed by tools/capture/gmtype.ps1 -File tools/capture/21/21-setup.txt; level before 8 / after 33
- SQL snapshots: 26_11_15_21_items-snapshot-before.txt / -after.txt
- inventory cells after setup: 0 HP Potion x10, 1 HP Potion x3, 2 HP Potion x1, 3 Jeweled Skeleton Ring, 4 Jeweled Skeleton Ring,
  5 Leather Boots, 6 Binding Reset Resin (Grade 1), 7 Freezing Ice, 8 Freezing Ice (correct? yes)
- step 7 (full inventory) is done last, because it ends with &cleariv
- times are wall clock; fill in hh:mm:ss as you go; write every message text the client shows

- __:__:__ capture started, client started, A logged in, setup typed (ended __:__:__), money 299378

Step 1: split / merge
- __:__:__ split 4 off the x10 stack (cell 0) into free cell 9
- __:__:__ merged the 4 back onto cell 0
- __:__:__ split 4 off cell 0 onto the x3 stack (cell 1) -> cell 0 = 10, cell 1 = 3 (did not work)
- __:__:__ refusal try: split 0 -> message: Range from 1 to 9 ; split the whole lot -> works
Step 2: drop / pick up a stack
- __:__:__ dropped the cell-1 stack (lot 3), confirmed -> on the ground? yes
- __:__:__ picked it up -> cell 0 (now 13 count)
Step 3: non-stackable dropped by A, picked by B
- __:__:__ A dropped Leather Boots (cell 5)
- __:__:__ B picked it up (B next to A? yes) -> You do not have the right to pick up the item.
- ~30 seconds later: B optained Leather Boots (cell 1)
Step 4: destroy
- __:__:__ dragged Binding Reset Resin (cell 6) out of the inventory, confirmation 1 yes, confirmation 2 yes -> gone? yes
Step 5: use
- __:__:__ used one HP Potion from cell 0 (lot after: 12)
- __:__:__ used the single HP Potion in cell 2 (cell empty after? yes)
Step 6: rings
- __:__:__ equipped ring (cell 3) -> slot left/right? right
- __:__:__ equipped ring (cell 4) -> other slot? yes
Step 8: storage (NPC: Storage Keeper Raina)
- __:__:__ deposited the cell-0 HP Potion stack (lot 12), changed to page 2, back to page 1, withdrew it
- __:__:__ deposited 1333 cen, withdrew 1333 cen (money before 299378 / after 299378)
Step 9: sell and buy back (NPC: Blacksmith James)
- split 4 potions from cell 0 into cell 1. cell 0 -> 8, cell 1 -> 4
- sold all 4 potions individually
- accidentially bought back 1 potion and used it
- buyback list shows 3 potions (a single per cell)
- bought back all 3 potions
- split 3 potions from cell 0 into cell 1. cell 0 -> 8, cell 1 -> 3
- __:__:__ sold the cell-1 HP Potion stack (lot 3, price 18), repurchase list shows it? yes
- __:__:__ could not buy back stack of 3 potions (bug?)
Step 10: soul stones (NPC: Healer Julia)
- __:__:__ bought 3 HP stones and 42 SP stones (counts shown: 15 / 51, money 297677)
- __:__:__ HP stone at full HP -> no message, stones not used
- __:__:__ &sethp 1 / &setsp 1 (client bars changed? yes), used an HP stone -> yes (444 hp after), an SP stone -> yes (591 hp after)
Step 11: KQ pick-up limit
- __:__:__ dropped one Freezing Ice (accepted? yes, no message), picked it up while holding the other -> message: Failed to obtain the item
Step 7: full inventory (gmtype -Command '&makeitem LeatherBoots' -Repeat 100, ended __:__:__, cells filled 46, although the makeitem command was executed more often, no failure message)
- __:__:__ unequipped a ring with the inventory full -> message: Failed to unequip the item
- __:__:__ dropped one Leather Boots, &makeitem LeatherBoots once more, tried to pick the dropped one -> message: Inventory is full
- __:__:__ &cleariv, unequipped both rings and picked up dropped items, &cleariv
- __:__:__ capture stopped; A logged out to the login screen; after-snapshot taken
