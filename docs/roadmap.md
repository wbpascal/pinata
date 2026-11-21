# Milestone roadmap

The order in which the Elixir server is built. Terms (Milestone, Capture checkpoint) are defined in
[`GLOSSARY.md`](../GLOSSARY.md). Scenario numbers refer to [`plan/capture-scenarios.md`](plan/capture-scenarios.md);
"recorded" means the capture is in `re-data/captures/`.

## Rules

- **Slicing:** each milestone is one step further along the path a new player takes, and is usable with the real
  2016 client on its own. Areas that already have captures go first.
- **Fixed and provisional:** milestones 1 to 4 are fixed. Milestones 5 to 11 are provisional: the order is confirmed
  or changed when the milestone before closes, and each is cut into issues only then.
- **Milestone map:** every milestone after the first is planned on its own wayfinder map (GitHub issue labelled
  `wayfinder:map`, attached to the GitHub milestone). The map is opened as soon as the GitHub milestone exists and
  collects points that come up during earlier work. It is charted when the milestone before closes: that session
  checks the captures, triages the original-server bugs and cuts the milestone into issues.
- **Version:** a milestone closes with its version published. The session that charts a milestone map adds the
  issue "Publish version 0.N.0" as the milestone's last one, opens the version's section in
  [`CHANGELOG.md`](../CHANGELOG.md) with its title and a first overview from the milestone's row below, and gives
  every issue it cuts a "Done when" line pointing at the changelog checklist of `server/AGENTS.md`.
- **Capture checkpoint:** a milestone's captures are recorded and validated before its issues are cut. It closes
  after capture replay passes and the user has confirmed it with the real client. A feature without any capture
  scenario (guild tournament) is built from the pseudocode and closes on the manual check alone.
- **GM commands:** each milestone builds the GM commands its own capture scenarios use as setup
  (`&makeitem`, `&getmoney`, `&levelup`, `&sethp`, …). Milestone 7 adds the rest.
- **Game log:** from milestone 3 on, each milestone logs the player actions it builds. There is no separate
  game-log milestone.
- **Mobs:** maps show NPCs but no mobs until milestone 4. Mob packets in the milestone 2 captures are left out of
  the replay comparison until then.
- **Load:** a manual load run with many instances of the TCP test client, in two scenarios (World: 2500 players
  over the maps; Crowd: 1500 on one map instance). First Crowd run at the end of milestone 2, as information only.
  From milestone 4 on, each milestone's capture checkpoint needs both scenarios to pass in both modes (single-node
  on SQLite, multi-node on Docker Compose with PostgreSQL). CI runs only a small smoke run. Bots arrive at
  milestone 7 and are never the load tool.

## Milestones

| # | State | Milestone | Captures recorded | Captures still to record |
|---|---|---|---|---|
| 1 | fixed | Login to character select: login, world select, character list / create / delete | login-logout, login-errors, create-char, 37, 37b | – |
| 2 | fixed | Enter the world: map entry, walking, portals, sight of other players, NPCs standing, normal / shout / whisper chat, logout, session loss, character rename | login-logout, idle_in_world, walk-run-portals, 14, 37b, 38, 52, 45 | 54 (open: which steps, see the milestone 2 map) |
| 3 | fixed | Items and NPC economy: inventory, equip, drop / pick-up, use, NPC menus, shop, buy-back, storage | 21 (b, c, d), 46, buy-equip-storage-sell | 53 |
| 4 | fixed | Combat: mobs, spawns, attack, exp, level-up, drops, death / revive, skills, abstates, stat points, soul stones. Includes the real-client check at levels 151 and 255 | travel-attack-die-revive, 24 | 39, 51 |
| 5 | provisional | Quests, class change, upgrades | – | 23, 22 |
| 6 | provisional | Social: party, friends, titles, trade, booth, block list, options, megaphone | – | 15, 17, 20, 36 |
| 7 | provisional | Bots and a full GM session | – | 32 |
| 8 | provisional | Guild, guild academy, raid | – | 18, 19, 16 |
| 9 | provisional | Pets, mounts, wing stone, premium inventory | – | 25, 26, 27, 34 |
| 10 | provisional | Kingdom Quest and instance dungeons | – | 30, 31 |
| 11 | provisional | Long tail: mini-house, wedding, dice / gamble / cards, gathering / production, holy promise, prison, guild tournament | – | 28, 29, 35, 40, 44, 33 |

Scenarios 45, 46 and 52 are validated in `protocol/capture-validation.md` (§27, §26, §28).
