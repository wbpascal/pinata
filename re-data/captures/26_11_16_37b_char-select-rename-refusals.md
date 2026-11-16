Scenario 37, second run "37b" (docs/plan/capture-scenarios.md §3 "37"): the character-select paths s37 left open
(capture-validation §4.2 "never seen on the WM": 0x1404 create error, 0x140F / 0x1410 rename, 0x1002 char login
error; plus the rename right of dept 45, 0xB409 -> 0xB40A / 0xB40B -> 0xB40C)
- recorded on the server PC by tools/capture/37/37b-server.ps1 capture-start (dumpcap, loopback + LAN, filter of capture-guide.md)
- account A: "admin", characters before prep: Test1235 (GM), Test2, X37Del ; account B ("testaccountB") is not used
- prep (tools/capture/37/37b-server.ps1 prep): X37Del renamed to "X37-Ren" in the DB; Test2 got a tCharacterChangeID row (bFlag 0, bInit 0)
- prep output: p_Char_Rename variant: 2018 Fixes copy ; other output
```
check_name|index_name|is_unique
----------|----------|---------
open_x02_or_x37_object
----------------------
X02_save_13a
X02_save_13b 
X37_save 
```
- server DB readings: out/26_11_16_37b_char-select-rename-refusals-db.txt (copy it next to this file)
- clients run on: another PC
- write every message text the client shows; "nothing" is an answer too

Step 1: create refused (name taken)
- logged in with admin, world "Enid", character list shows: Test1235, Test2, X37-Ren
- "Create", any class, name "Test1235" -> message: "The name is already in use. Please choose another" (expected "The name is already in use.")
- name "X37 Sp" (with a space) -> refused by the client itself (no OK possible / message: Please enter a correct name.)
- create screen cancelled, back on the character list: Had to manually press Exit on character creation screen, then back to character select.

Step 2: plain rename (name with '-')
- selected X37-Ren (simply selected) -> rename window opened? yes ; its text: Character name must be changed.
- entered the old name "X37-Ren" -> message: Please enter a correct name. (expected: the client refuses it itself)
- entered "Test1235" -> message: nothing, succeeded but when trying to start leads to a "Map under Maintenance screen. After logging in with the original "Test1235" character from the first slot (which succeeds) and going back to character select, I got prompted again for a rename (character got their old name "X37-Ren" back).
- entered "X37Ren" -> message: nothing ; name shown in the list afterwards: X37Ren
- selected it again and pressed start -> other: Disconnected
- reopened client and logged back in until character select
- Character back to "X37-Ren". When renaming to X37Ren goes back into Disconnect (so on and so forth. Maybe an issue because we "renamed" the character to "Test1235" before?)

Step 3: rename right (tCharacterChangeID row)
- selected Test2 -> rename window opened? yes ; its text (differs from step 2?): no ; a "reset relations" option shown? no (left unticked)
- entered "Test1235" -> message: successfully closed window without a message. However, character remains as "Test2" and wants to be renamed when selected again. (expected "The name is already taken by another user.")
- entered "X37Id" -> message: "Character name successfully changed." (expected "Character name successfully changed.") ; name in the list: X37Id
- selected it again and pressed start -> game loads
  (if the game loaded: menu -> "character select")

Step 4: map under maintenance (all zones down)
- on the character list; server: .\37b-server.ps1 stop-zones -> done
- selected Test1235 and pressed start -> message: The Map is under maintenance (expected "The Map is under maintenance") ; still on the character list? yes
- server: .\37b-server.ps1 start-zones -> READY
- selected Test1235 again -> in game? yes ; message: nothing
- menu -> exit game ; client closed

End
- capture stopped (Ctrl+C in the dumpcap window)
- server: .\37b-server.ps1 cleanup -> names restored: yes ; rename rows removed: yes
