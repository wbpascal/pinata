Scenario 38 (docs/plan/capture-scenarios.md): session loss, kicks, back to character select
- recorded on the server PC, loopback + LAN interface, filter of capture-guide.md (client ports + server links, 9411 included)
- account A: "admin", character "<name>" (GM 100 by tools/capture/38/38-prep.sql, S1); world "Enid"
- account B ("testaccountB") is not used: the "second client" of this scenario is a second client of account A
- clients run on: another PC
- server actions: tools/capture/38/38-server.ps1 in an elevated PowerShell on the server; its DB readings are in
  out/26_11_16_38_session-loss-kicks-char-select-db.txt (copy that file next to this one)
- prep output: money 99999634524 , map / position RouN next to Blacksmith (snapshot "before step 1")
- write every message text the client shows; "nothing" is an answer too
- deviation from the scenario text: step 5 gets its money from `&getmoney 100` instead of a ground pick-up. No mob of
  the 2016 data drops money (ItemDropTable MinCen / MaxCen / CenRate are 0 in every record and only read for the
  checksum, Z09 §11; no DrItem names the `Cen` item). `&getmoney` runs the same `so_ply_PickupMoney` and the same
  `0x3438` -> `0x3439` commit (Z11 §7.4)

Step 1: back to character select, same character again
- in game, menu -> "character select" (not the world list) -> message: nothing
- character list shown: yes ; selected the same character -> in game again? yes ; message: nothing

Step 2: quit from inside the game
- menu -> exit game -> message: nothing ; client closed? yes

Step 3: only the zone connection closed
- client 1 started, A in game; client 2 started, sitting at the login screen with "admin" and the password typed in
- server: .\38-server.ps1 close-zone-conn -> "client links left" shows the WM link? no
- client 1 shows: message "Disconnected from the server.". After confirmation closes the client. (message, screen it went to, frozen?)
- client 2: pressed login within 10 s of the reset -> message in client 2: nothing, successfully connected (shows world list)
- client 2: world -> character list -> selected the character -> in game? yes
- client 1 closed

Step 4: client process killed
- client 2 killed (server: .\38-server.ps1 kill-client, or Task Manager on the client PC)
- client started again, logged in, in game? yes ; message: nothing

Step 5: money committed, then the zone killed
- money in the UI before: 99999634724
- &getmoney 100 -> money in the UI: 99999634824 ; chat message: "[Leather Boots] has been obtained" (Notice message, not in chat) ; waited 3 s
- server: .\38-server.ps1 kill-zone -Char Test1235 -> DB money after the kill: 99999634824 (expected before + 100)
- client shows: "Disconnected from the server." (message / screen)
- after "READY": client closed if it was still open, started, logged in -> in game? yes ; money in the UI: 99999634824

Step 6: money and the zone kill within a second
- walked some distance to a spot you can recognise: RouN near Storage Keeper Raina (map, near what; the coordinates if the minimap shows them)
- server: .\38-server.ps1 getmoney-kill -Char Test1235 -> typed by the script / countdown: countdown
  (countdown: pressed Enter in the client at "PRESS ENTER")
- money in the UI just before the client lost the zone (if seen): 99999635324
- DB money after the kill: 99999635324 (expected before + 500 or before, nothing else)
- client shows: Disconnected from server
- after "READY": logged in again -> money in the UI: 99999635324 ; where the character stands: next to Blacksmith James
  (expected: the last saved spot, not the spot walked to)

End
- capture stopped
