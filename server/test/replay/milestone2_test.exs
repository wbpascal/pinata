# Stand-ins for the packets nobody defines yet: the `:absent` deferral needs a module with `opcode/0`.
defmodule Replay.Milestone2Test.Unbuilt.BatAbstateinformNoeffectCmd do
  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x242A
end

defmodule Replay.Milestone2Test.Unbuilt.BatAbstateinformCmd do
  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x2429
end

defmodule Replay.Milestone2Test.Unbuilt.BriefinfoAbstateChangeCmd do
  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x1C18
end

defmodule Replay.Milestone2Test.Unbuilt.CharClientAutoPickAck do
  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x10BD
end

defmodule Replay.Milestone2Test.Unbuilt.ShortcutdataCmd do
  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x7032
end

defmodule Replay.Milestone2Test.Unbuilt.KeymapCmd do
  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x7033
end

defmodule Replay.Milestone2Test.Unbuilt.GameoptionCmd do
  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x7034
end

defmodule Replay.Milestone2Test.Unbuilt.BatAbstateresetCmd do
  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x2428
end

defmodule Replay.Milestone2Test.Unbuilt.ItemEquipchangeCmd do
  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x3002
end

defmodule Replay.Milestone2Test.Unbuilt.KqListUpdateAck do
  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x581F
end

defmodule Replay.Milestone2Test.Unbuilt.KqJoiningAlarmCmd do
  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x5824
end

defmodule Replay.Milestone2Test.Unbuilt.BriefinfoAbstateChangeListCmd do
  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x1C19
end

defmodule Replay.Milestone2Test.Unbuilt.BatAbstatesetCmd do
  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x2427
end

# official name from the 2017 PDB only (NC_CHAR_USEITEM_MINIMON_USE_BROAD_CMD); capture-validation.md §12 calls it the
# range broadcast of the mini-mon use
defmodule Replay.Milestone2Test.Unbuilt.CharUseitemMinimonUseBroadCmd do
  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x112C
end

defmodule Replay.Milestone2Test do
  # The harness swaps the global clock source, so it cannot run async.
  use ExUnit.Case, async: false

  alias Proto.Packets, as: P
  alias Replay.Milestone2Test.Unbuilt, as: U

  @moduletag capture_log: true

  defp replay(name, setup, stop, opts) do
    apply(Replay.Setups, setup, [])
    transcript = "transcripts/#{name}.txt" |> Path.expand(__DIR__) |> Replay.Transcript.read!()

    Replay.assert_replay(transcript,
      stop: stop,
      endpoints: Replay.Topology.endpoints(),
      deferrals: opts[:deferrals] || [],
      close_after: opts[:close_after] || [],
      drop_after: opts[:drop_after] || [],
      late_ms: opts[:late_ms] || 0,
      masks: opts[:masks] || [],
      tick_offset: opts[:tick_offset] || 0
    )
  end

  @options "the option pushes 0x7032 to 0x7034 after 0x1003 (stored shortcuts, key map, game options): issue 132 decides"
  @admin "the admin level column is issue 116; a loaded character has level 0"

  @deferrals [
    {:absent, U.ShortcutdataCmd, 2, @options},
    {:absent, U.KeymapCmd, 2, @options},
    {:absent, U.GameoptionCmd, 2, @options},
    {:payload, P.CharClientBaseCmd, :fame, 4, "fame has no column yet; the rebuild sends 0"},
    {:payload, P.CharClientBaseCmd, :stat_distribute, 4, "stat distribution has no column yet; the rebuild sends 0"},
    {:payload, P.CharClientBaseCmd, :admin_level, 2, @admin},
    {:payload, P.CharClientQuestReadCmd, :all, 5, "the read quests of the captured character (quests)"},
    {:payload, P.QuestResetTimeClientCmd, :all, 5, "the quest reset times (quests); the rebuild sends 0"},
    {:payload, P.CharClientSkillCmd, :all, 4, "the skills of the captured character (skills)"},
    {:payload, P.CharClientPassiveCmd, :all, 4, "the passive skills of the captured character (passives)"},
    {:payload, P.CharClientItemCmd, :all, 3, "the items of the captured character (items)"},
    {:payload, P.CharClientChartitleCmd, :all, 6, "the titles of the captured character (titles)"},
    {:payload, P.CharClientChargedbuffCmd, :all, 9, "the charged buff of the captured character (charged buffs)"},
    {:payload, P.MapLoginAck, :param, 4,
     "the parameter block (parameters); the rebuild sends stored HP and SP as maxima"},
    {:payload, P.CharOptionGetShortcutsizeAck, :all, 6,
     "the stored shortcut sizes of the captured character (options)"},
    {:payload, P.CharOptionGetWindowposAck, :all, 6, "the stored window positions of the captured character (options)"},
    {:mobs,
     %{
       appear: [{P.BriefinfoRegenmobCmd, :handle, :mob_id}],
       lists: [{P.BriefinfoMobCmd, :mobs, :handle, :mob_id, 28}],
       gone: [{P.BriefinfoBriefinfodeleteCmd, :handle}],
       about: [{P.ActSomeonemovewalkCmd, :handle}, {P.ActSomeonemoverunCmd, :handle}, {P.ActSomeonestopCmd, :handle}],
       npc?: &__MODULE__.npc?/2
     }, 4, "the monsters of the map and their moves (mobs); the NPC elements of 0x1C09 are compared"},
    {:absent, U.BatAbstateinformNoeffectCmd, 4, "the abstates 345 and 291 of the captured character (abstates)"},
    {:absent, U.BatAbstateinformCmd, 4, "the title abstates and abstate 728 (abstates)"},
    {:absent, U.BriefinfoAbstateChangeCmd, 4, "the abstates of the captured character (abstates)"},
    {:payload, P.CharStatRemainpointCmd, :remain, 4, "the unspent stat points of the captured character (stat points)"},
    {:absent, P.ActNoticeCmd, 2,
     "the \"From\" notice needs an admin level and \"Admin level is 100\" answers &adminlevel: issue 116"},
    {:absent, U.CharClientAutoPickAck, 9, "the auto-pick state of the captured character (auto-pick)"},
    {:absent, P.CharAdminLevelInformCmd, 2, @admin},
    {:payload, P.CharChangeparamchangeCmd, [:params, :value], 4,
     "the parameter values (parameters); the rebuild sends stored HP and SP and 0 elsewhere"},
    {:payload, P.KqJoiningAlarmList, :all, 10, "the Kingdom Quests open to join (Kingdom Quest)"},
    {:payload, P.CharClientNewbieGuideViewListCmd, :all, 11, "the newbie guides the captured character has seen"}
  ]

  @doc false
  @spec npc?(String.t() | nil, non_neg_integer()) :: boolean()
  def npc?(map, mob_id) do
    Enum.any?(GameData.lookup(GameData.ShineNpc, :map, map), fn row ->
      Enum.any?(GameData.lookup(GameData.MobInfo, :inx_name, row.mob_name), &(&1.id == mob_id))
    end)
  end

  @prison_race "order race of the original: its 0x7C07 comes between 0x7005 and 0x700D; the rebuild answers in request order (test/map_entry_test.exs)"
  @kq_race "order race of the original (its 0x581C comes after the WorldManager burst) and the Kingdom Quest list 0x581D (Kingdom Quest); the answer is checked by test/map_entry_test.exs"
  # Behind a map entry: abstate resets and the Kingdom Quest notices (mob moves are in the :mobs deferral).
  @in_world [
    {:absent, U.BatAbstateresetCmd, 4, "the reset of abstate 291 (abstates)"},
    {:absent, U.KqListUpdateAck, 10, "the Kingdom Quest list updates (Kingdom Quest)"},
    {:absent, U.KqJoiningAlarmCmd, 10, "the Kingdom Quest joining alarm (Kingdom Quest)"}
  ]

  # Behind the map entry (140): mob moves (milestone 4), the reset of abstate 291 with its 0x1035 at 145 and 146
  # (milestone 4), the expiry of the pick-up mini-mon at 161 to 168 (milestones 3 and 9), the Kingdom Quest notices
  # (milestone 10) and the leave: 0x2012 (a stop, relayed to nobody in sight), 0x1071 and the option saves get no
  # answer, 0x0C18 {0} ends the session.
  @idle_deferrals @deferrals ++
                    @in_world ++
                    [
                      {:unsent, 44, [46], 2, @prison_race},
                      {:unsent, 52, [127, 128, 129, 130], 10, @kq_race},
                      {:absent, U.ItemEquipchangeCmd, 3, "the expiry of the pick-up mini-mon (items)"},
                      {:absent, [167, 168], 9,
                       "HP and SP after the expiry of the pick-up mini-mon (charged items); the built 0x240E and 0x240F stay"},
                      {:absent, [146, 161, 162, 166], 4,
                       "the late 0x1035 of the abstate reset and the mini-mon expiry (parameters); the built one at 133 stays"},
                      {:unsent, 191, [], 2,
                       "the rebuild closes the Zone connection when the session ends (0x0C18 {0} on the WorldManager connection, one line earlier); the client's copy on the Zone connection would race that close. No milestone removes it"}
                    ]

  test "26_11_15_idle_in_world",
    do: replay("26_11_15_idle_in_world", :idle_in_world, :end, deferrals: @idle_deferrals)

  @linger "the original saves (and sets the KQ date) about 10 s after a session ends, the logout linger the rebuild leaves out by decision (issue 94); the lists at 429 and 574 show that time. No milestone removes it"
  @inventory_race "order race of the original: 0x302C and 0x3020 sent before the end of the 0x1803 burst are answered inside it; the rebuild answers after it (test/map_entry_test.exs)"

  # Per world entry the two order races: the 0x7C06 with its 0x7C07, the 0x581B with its 0x581C and three 0x581D.
  @entries [{42, [45], 47, [60, 61, 62, 63]}, {206, [209], 210, [216, 217, 218, 219]}] ++
             [{459, [462], 463, [537, 538, 539, 540]}, {604, [607], 608, [683, 684, 685, 686]}] ++
             [{764, [767], 768, [839, 840, 841, 842]}]

  @session_loss_deferrals @deferrals ++
                            @in_world ++
                            Enum.flat_map(@entries, fn {prison, prison_answers, kq, kq_answers} ->
                              [
                                {:unsent, prison, prison_answers, 2, @prison_race},
                                {:unsent, kq, kq_answers, 10, @kq_race}
                              ]
                            end) ++
                            [
                              {:payload, [429, 574], P.UserLoginworldAck, [:avatars, :kq_date], 2, @linger},
                              {:payload, [429, 574], P.UserLoginworldAck, [:avatars, :kq_date_sec], 2, @linger},
                              {:unsent, 220, [283], 2, @inventory_race},
                              {:unsent, 221, [282], 2, @inventory_race},
                              {:unsent, 469, [541], 2, @inventory_race},
                              {:unsent, 470, [548], 2, @inventory_race},
                              {:unsent, 614, [687], 2, @inventory_race},
                              {:unsent, 615, [694], 2, @inventory_race},
                              {:absent, [137, 301, 317, 318, 352, 353, 390, 391, 698, 862], 4,
                               "the late 0x1035 of the abstate resets (parameters); the built one of each map entry stays"}
                            ]

  # Steps 1 to 5 of the scenario up to the first &getmoney. Closed by the client: 144 (zone#1, 1 s after 0x0C18 {1}),
  # 154 (wm#1 after 0x0C34), 164, 405 and 415 (Login connections that ended with 0x0C18 {0}), 718 and 722 (the killed
  # client, zone#4 and wm#4). Dropped: zone#2 and zone#3 at their last played line, for the capture's server-side
  # resets at 292.5 s and 423.4 s. 0x2001 (&adminlevel) is sent and dropped (issue 116); 0x2012 and 0x2019 are
  # handled and answer nothing (no other player in sight, no refusal).
  test "26_11_16_38_session-loss-kicks-char-select",
    do:
      replay(
        "26_11_16_38_session-loss-kicks-char-select",
        :session_loss_kicks_char_select,
        {:cut, 547, "the first &getmoney (items, milestone 3)"},
        deferrals: @session_loss_deferrals,
        close_after: [144, 154, 164, 405, 415, 718, 722],
        drop_after: [386, 547]
      )

  @target "0x2401 target select and its 0x2402 (combat)"
  @town_npc "0x200A on the town portal NPC with 0x243D and the menu 0x201C (NPC menus); only the Gate role is built"

  @kq_again "a later 0x581B of the session, answered by nothing: with the first one left out (the order race at 49) the rebuild would answer this one with 0x581C; only the first of a session is answered (test/map_entry_test.exs)"

  @border "an NPC appear at the sight border after the arrival in RouN at 608: the original placed the player at x + 25, so its positions cross the border in other slices; the placement search comes with mob spawns"

  @walk_run_deferrals @deferrals ++
                        @in_world ++
                        [
                          {:unsent, 44, [47], 2, @prison_race},
                          {:unsent, 49, [54, 55, 56, 57], 10, @kq_race}
                        ] ++
                        for(i <- [254, 370, 480, 610, 882], do: {:unsent, i, [], 10, @kq_again}) ++
                        [
                          {:unsent, 58, [124], 2, @inventory_race},
                          {:unsent, 59, [131], 2, @inventory_race},
                          {:absent, [139, 172, 173, 331, 444, 451, 452, 557, 698, 787, 788, 966, 1016, 1017], 4,
                           "the late 0x1035 of the abstate resets (parameters); the built one of each map entry stays"},
                          {:unsent, 222, [223], 4, @target},
                          {:unsent, 336, [337], 4, @target},
                          {:unsent, 445, [448], 4, @target},
                          {:unsent, 567, [568], 4, @target},
                          {:unsent, 846, [849], 4, @target},
                          {:unsent, 224, [225, 227], 3, @town_npc},
                          {:unsent, 338, [340, 341], 3, @town_npc},
                          {:unsent, 446, [449, 450], 3, @town_npc},
                          {:unsent, 569, [571, 572], 3, @town_npc},
                          {:absent, [851], 4, "0x243D cease fire after the target select of the gate click (combat)"},
                          {:absent, [706, 733], 4, @border},
                          {:absent, [761], 4,
                           "0x1C0E of handle 14204, an object never shown on this connection (no mob or NPC of the map; mobs)"},
                          {:payload, [368, 608], P.MapLoginAck, :x, 4,
                           "the original moves an arriving player off an occupied cell (x + 25 at the town portal NPC of RouN); the placement search comes with mob spawns"}
                        ]

  # zone#1 walks and runs through RouN: every 0x2017, 0x2019 and 0x2012 is played (no refusal, nothing relayed: no
  # other player), the NPCs that come into sight appear with 0x1C08 on the tick; the mob moves are in the :mobs
  # deferral. Then five map changes: the town portal 0x181A (228, 343, 453, 583: RouN to RouVal01 and back, twice)
  # with 0x181B and 0x180A, and the gate of RouN to RouCos02 (0x200A at 847, the menu 0x3C01, "Yes" 0x3C02 at 856,
  # 0x180A). Each new Zone connection enters with the full burst; the WorldManager connection sends only 0x5826 and
  # 0x182A. The client closed each old Zone connection after its 0x180A (close_after). late_ms: 200 because the
  # original handled each move 5 to 60 ms after its capture time and ticked at its own phase, so a tick-driven appear
  # can lie before the tick that sends it here; without it the replay fails at the first NPC appear (146) for every
  # tick phase, with it it passes for all (testing.md, "Clock").
  test "26_11_15_walk-run-portals",
    do:
      replay(
        "26_11_15_walk-run-portals",
        :walk_run_portals,
        :end,
        deferrals: @walk_run_deferrals,
        close_after: [231, 346, 456, 586, 857],
        late_ms: 200
      )

  @param_1035 "the late and the once-a-minute 0x1035 (parameters, regeneration; capture-validation.md §27.8); the built ones at 134 and 246 stay"

  @walk_sit_emote_deferrals @deferrals ++
                              @in_world ++
                              [
                                {:unsent, 43, [46], 2, @prison_race},
                                {:unsent, 64, [79, 80, 81, 82], 10, @kq_race},
                                {:unsent, 70, [131], 2, @inventory_race},
                                {:unsent, 71, [138], 2, @inventory_race},
                                {:unsent, 164, [167], 2, @prison_race},
                                {:unsent, 171, [177, 178, 179, 231], 10, @kq_race},
                                {:unsent, 232, [257], 2, @inventory_race},
                                {:unsent, 233, [256], 2, @inventory_race},
                                {:payload, P.CharClientCoininfoCmd, :exchangeable, 11,
                                 "the exchangeable coins of the captured characters (coins); the placeholder sends the value of idle_in_world"},
                                {:payload, P.CharMysteryvaultUiStateCmd, :state, 11,
                                 "the mystery vault window state of the captured characters (mystery vault); the placeholder sends 0"},
                                {:payload, [213, 215], P.BriefinfoMobCmd, :all, 4,
                                 "B's entry lists of NPCs and monsters: the original's first list holds a monster, so its border differs, and the :mobs deferral cannot join the two lists across the 0x1C07 between them (mobs)"},
                                {:payload, [222], P.ChargedBoothslotsizeCmd, :size, 6,
                                 "the booth slot count of X45B (booth size); the placeholder sends 5"},
                                {:extra, P.CharClientItemCmd, 3,
                                 "the placeholder sends an empty 0x1047 for each of the boxes 9, 8, 12 and 15; the original leaves out an empty box other than 15 (A has no worn item, B none and no box 12 item), which needs the loaded boxes (items)"},
                                {:absent, [879], 4,
                                 "0x1C0E of object 14204: no packet of the capture introduces this handle, it is not a player and not an NPC of the rebuild (objects)"},
                                {:absent, [243, 280, 282], 3,
                                 "the 0x3001 item cell changes at the entry and at 42.9 s (items)"},
                                {:absent, [279], 9, "the 0x9010 at 42.9 s with the item changes (charged items)"},
                                {:unsent, 357, [358, 359], 4,
                                 "B's &fullpoint and its 0x240E / 0x240F (GM commands, stats)"},
                                {:unsent, 368, [369], 3, "B's &makeitem HeavyBow and its 0x3001 (items)"},
                                {:unsent, 421, [422], 4, "B's skill shortcut 0x7037 and its 0x7038 (skills)"},
                                {:unsent, 425, [426, 427, 428, 429, 430], 3,
                                 "B equips the bow 0x300F: 0x1C05 to A, 0x3002, 0x3001, 0x3011, 0x1035 (items)"},
                                {:payload, [888], P.BriefinfoLogincharacterCmd, :equip, 3,
                                 "Equ_LeftHand: the bow B equipped at 151.9 s (items); the mask covers the 20 slots, only the left hand differs"},
                                {:payload, [888], P.BriefinfoLogincharacterCmd, :y, 2,
                                 "B's position at the tick that brings it into sight: the original's tick phase and handling delays are not in the capture. No milestone removes it"},
                                {:payload, P.BriefinfoLogincharacterCmd, :abstatebit, 4, "the abstate bits (abstates)"},
                                {:payload, P.BriefinfoCharacterCmd, [:chars, :abstatebit], 4,
                                 "the abstate bits (abstates)"},
                                {:absent, U.BriefinfoAbstateChangeListCmd, 4,
                                 "the abstate list of a player in sight (abstates)"},
                                {:absent, U.BatAbstatesetCmd, 4, "the abstate set of a player in sight (abstates)"},
                                {:absent, U.CharUseitemMinimonUseBroadCmd, 9,
                                 "the mini-mon broadcast of a player that enters (charged items)"},
                                {:absent, [239], 4,
                                 "the 0x2013 {B} the original sends to the players in sight inside 0x1803, between the abstate packets of the login protection; its cause is not reconstructed"},
                                {:absent,
                                 [
                                   169,
                                   277,
                                   283,
                                   350,
                                   353,
                                   437,
                                   440,
                                   551,
                                   554,
                                   644,
                                   646,
                                   835,
                                   837,
                                   989,
                                   991,
                                   1080,
                                   1083
                                 ], 4, @param_1035},
                                {:absent,
                                 [
                                   267,
                                   278,
                                   281,
                                   351,
                                   352,
                                   438,
                                   439,
                                   552,
                                   553,
                                   645,
                                   647,
                                   836,
                                   838,
                                   990,
                                   992,
                                   1081,
                                   1082
                                 ], 4, @param_1035},
                                {:absent, [628, 629], 4, "the chat line 0x2002 of a mob (handle 5991; mobs)"}
                              ]

  @handling "the server position of a mover at the instant of a request: the original handled the packet up to 45 ms after its capture line (the relay's own delay bounds it), one unit at run speed is 8 ms; test/movement_test.exs compares these fields with capture 45 at a set clock"

  @walk_sit_emote_masks [
    {P.ActSomeonemovewalkCmd, :from_x, @handling},
    {P.ActSomeonemovewalkCmd, :from_y, @handling},
    {P.ActSomeonemoverunCmd, :from_x, @handling},
    {P.ActSomeonemoverunCmd, :from_y, @handling},
    {P.ActSomeonestopCmd, :x, @handling},
    {P.ActSomeonestopCmd, :y, @handling}
  ]

  # zone#1 is A (X45A), zone#2 is B (X45B), in sight of each other from the start. Played: the walk and run relay
  # (169 to 180 s), the sit 0x2020 {7} and the jump, the dance three times and the step that ends it (0x2021 to both,
  # 0x2025 to A only), B leaving and entering A's sight at run speed (0x1C0E, 0x1C06 with B's emote state), the shout
  # out of sight and the whisper to an unknown name. Deferred: B's GM setup at 104 to 152 s (items, stats, skills),
  # the bow in B's later appear (items), abstates, the regular 0x1035, the mob chat. late_ms: 200 as in
  # walk-run-portals (the tick-driven 0x1C0E / 0x1C06 of B's runs at 305.6 s and 385.0 s).
  # The 0x1047 placeholders of the empty boxes the original leaves out are dropped (:extra). The `from` of the move
  # relays and the stop position are masked: the server takes the mover's position at the instant it handles the
  # request, which the capture bounds only by the relay's delay; for each of the 108 relayed requests before 471 s
  # a delay inside that bound gives the captured position (simulation of Zone.Mover over the transcript).
  test "26_11_21_45_walk-sit-emote-stop-shout-whisper-cast-abort",
    do:
      replay(
        "26_11_21_45_walk-sit-emote-stop-shout-whisper-cast-abort",
        :walk_sit_emote,
        {:cut, 471, "&mb ArchMageBook: the mob, B's death and town revive, casts (combat, milestone 4)"},
        deferrals: @walk_sit_emote_deferrals,
        masks: @walk_sit_emote_masks,
        late_ms: 200
      )
end
