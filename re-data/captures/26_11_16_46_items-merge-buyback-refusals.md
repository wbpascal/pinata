Scenario 46 (docs/plan/capture-scenarios.md §3 "46"): items III, what `s21` left open, no DB change
- recorded on the server PC by tools/capture/46/46-server.ps1 capture-start (dumpcap, loopback + LAN, filter of capture-guide.md)
- account A: "admin", character "X46A" (created in the client as Trickster, made level 20 / GM 100 / 1 000 cen by 46-server.ps1 prep), world "Enid"
- no second client
- prep output: X46A level 20 GM 100 money 1000 (expected 20 / 100 / 1000); account storage money before the run ______
- server DB readings: 26_11_16_46_items-merge-buyback-refusals-db.txt (snapshots "after prep", "after setup", "after logout")
- setup typed by gmtype.ps1 -File 46\46-setup.txt? yes (or by hand)
- inventory cells after setup: 0 HP Potion (Tier 1) x40, 1 HP Potion x30, 2 Leather Boots, 3 Frozen Earrings, 4 Broad Sword (correct? yes)
- write every message text the client shows; "nothing" is an answer too
- do not click any NPC other than the one named in the step while a shop or storage window is open (P02-B31)

Start
- capture started; A logged in; tutorial question shown? no (expected no); standing next to Storage Keeper Raina? yes
- setup typed; server: .\46-server.ps1 snapshot -Label "after setup" done? yes

Step 1: stack onto a fuller stack
- dragged the x30 stack (cell 1) onto the x40 stack (cell 0) -> cell 0 = 50 , cell 1 = 20 (expected 50 / 20) ; message: nothing
- dragged the x20 stack onto the full x50 stack -> cell 0 = 20 , cell 1 = 50 (expected: the two swap, 20 where the 50 was) ; message: nothing

Step 2: storage keeper (Storage Keeper Raina)
- deposited the x20 stack -> storage cell 3 ; message: nothing
- deposited all cen (1000 cen) -> purse 0? yes ; message: nothing
- closed the storage window

Step 3: sell and buy back onto an empty cell (Blacksmith James; no other NPC until step 7)
- sold the Leather Boots (cell 2) for 2 cen -> repurchase list shows them? yes ; message: nothing
- bought them back -> back in cell 0 (expected an empty cell, e.g. 2, update because we deposited in step 2, cell 0 was empty) ; purse 0 (expected 0) ; message: nothing

Step 4: buy-back without enough money
- sold the Broad Sword (cell 4) for yes cen (expected 50)
- bought the cheapest item, Short Sword, for 12 cen (expected 12) -> purse 38 (expected 38)
- tried to buy the Broad Sword back -> message: Cannot make the purchase due to insufficient money (expected "Not enough money to buy the item.") ; still in the repurchase list? yes

Step 5: buy-back above the character's level
- sold the Frozen Earrings (cell 3) for 89 367 cen (expected 89 367)
- tried to buy them back -> message: nothing (expected none) ; still in the repurchase list? yes ; purse 89 405 (89 367 + 38 from step 4)

Step 6: buy-back with a full inventory
- left James's window open? yes ; gmtype -Command '&makeitem LeatherBoots' -Repeat 60 (or by hand) -> inventory full? yes ; failure message once full: nothing
- sold one Leather Boots -> repurchase list shows it? yes
- &makeitem LeatherBoots once more -> the freed cell filled? yes
- tried to buy the boots back -> message: Inventory is full. (expected "Inventory is full.") ; still in the repurchase list? yes
- closed James's window

Step 7: soul stones with 0 cen and over the limit (Storage Keeper Raina, Healer Julia)
- at Raina: deposited all cen (89407 cen) -> purse 0? yes ; closed the window
- at Julia: tried to buy 1 HP soul stone -> message: You have insufficient money
- at Raina: withdrew all cen (90407 cen) ; closed the window
- at Julia: the window allows at most 36 HP stones (stones held before: 15) ; bought that many -> message: Item has been purchased
- asked for more: could the number be typed? no ; message: Cannot purchase more

End
- capture stopped; A logged out to the login screen; .\46-server.ps1 cleanup -Dest <this folder> done? ___
- anything unexpected: ___
