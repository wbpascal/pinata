# Stand-ins for the packets nobody defines yet: the `:absent` deferral needs a module with `opcode/0`.
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

defmodule Replay.Milestone2Test.Unbuilt.BriefinfoDropeditemCmd do
  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x1C0A
end

defmodule Replay.Milestone2Test.Unbuilt.BatTargetinfoCmd do
  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x2402
end

defmodule Replay.Milestone2Test.Unbuilt.BatExpgainCmd do
  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x240B
end

defmodule Replay.Milestone2Test.Unbuilt.BatSkillbashCastSucAck do
  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x2435
end

defmodule Replay.Milestone2Test.Unbuilt.BatCeaseFireCmd do
  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x243D
end

defmodule Replay.Milestone2Test.Unbuilt.BatSwingStartCmd do
  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x2447
end

defmodule Replay.Milestone2Test.Unbuilt.BatSwingDamageCmd do
  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x2448
end

defmodule Replay.Milestone2Test.Unbuilt.BatSomeoneswingDamageCmd do
  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x2449
end

defmodule Replay.Milestone2Test.Unbuilt.BatPkinpkfieldWmsCmd do
  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x244A
end

defmodule Replay.Milestone2Test.Unbuilt.BatSkillbashHitObjStartCmd do
  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x244E
end

defmodule Replay.Milestone2Test.Unbuilt.BatSomeoneskillbashHitObjStartCmd do
  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x244F
end

defmodule Replay.Milestone2Test.Unbuilt.BatSkillbashHitDamageCmd do
  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x2452
end

defmodule Replay.Milestone2Test.Unbuilt.BatSkillbashHitBlastCmd do
  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x2457
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
      deferrals: (opts[:deferrals] || []) ++ from_notices(transcript) ++ admin_levels(transcript),
      close_after: opts[:close_after] || [],
      drop_after: opts[:drop_after] || [],
      late_ms: opts[:late_ms] || 0,
      masks: opts[:masks] || [],
      tick_offset: opts[:tick_offset] || 0,
      before: opts[:before] || %{},
      handles: opts[:handles] || []
    )
  end

  @from "the address of the capture's client in the \"From\" notice; the rebuild sends the address of the test client. No milestone removes it"

  # the "From <address>" notices of the map entries of a GM (0x2011, text starting with "From ")
  defp from_notices(transcript) do
    indices =
      for %{dir: :server, opcode: 0x2011, payload: <<_unused, _len, "From ", _::binary>>, index: i} <-
            transcript.packets,
          do: i

    if indices == [], do: [], else: [{:payload, indices, P.ActNoticeCmd, :all, 2, @from}]
  end

  @admin_race "order race of the original: &adminlevel sent right after 0x1803 is answered inside the 0x1803 burst; the rebuild answers after it (test/gm_command_test.exs)"

  # the client's &adminlevel after each 0x1803 of a GM and its answer "Admin level is <n>" on the same connection
  defp admin_levels(transcript) do
    packets = transcript.packets

    for %{dir: :client, opcode: 0x2001, payload: <<_count, _len, "&adminlevel">>, conn: conn, index: i} <- packets,
        answer = Enum.find(packets, &(&1.index > i and &1.conn == conn and &1.opcode == 0x2011 and admin?(&1.payload))),
        answer != nil,
        do: {:unsent, i, [answer.index], 2, @admin_race}
  end

  defp admin?(<<_unused, _len, "Admin level is ", _::binary>>), do: true
  defp admin?(_payload), do: false

  @deferrals [
    {:payload, P.CharOptionImproveGetShortcutdataCmd, :all, 4,
     "the stored shortcut bar of the captured character (shortcuts); the placeholder sends an empty list"},
    {:payload, P.CharOptionImproveGetKeymapCmd, :all, 6,
     "the stored key map of the captured character (options); the placeholder sends an empty list"},
    {:payload, P.CharOptionImproveGetGameoptionCmd, :all, 6,
     "the stored game options of the captured character (options); the placeholder sends an empty list"},
    {:payload, P.CharClientBaseCmd, :fame, 4, "fame has no column yet; the rebuild sends 0"},
    {:payload, P.CharClientBaseCmd, :stat_distribute, 4, "stat distribution has no column yet; the rebuild sends 0"},
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
    {:absent, P.BatAbstateinformNoeffectCmd, 4, "the abstates 345 and 291 of the captured character (abstates)"},
    {:absent, U.BatAbstateinformCmd, 4, "the title abstates and abstate 728 (abstates)"},
    {:absent, U.BriefinfoAbstateChangeCmd, 4, "the abstates of the captured character (abstates)"},
    {:payload, P.CharStatRemainpointCmd, :remain, 4, "the unspent stat points of the captured character (stat points)"},
    {:absent, U.CharClientAutoPickAck, 9, "the auto-pick state of the captured character (auto-pick)"},
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
    {:absent, P.BatAbstateresetCmd, 4, "the reset of abstate 291 (abstates)"},
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
  # resets at 292.5 s and 423.4 s. 0x2001 (&adminlevel) and its answer are unsent (the order race of admin_levels/1); 0x2012 and 0x2019 are
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

  @running_inform "the position of a running player at the instant the original answered a 0x1C01 about it: its handling delay is not in the capture. No milestone removes it"
  @mob_inform "0x1C01 for a monster the client was shown and its 0x1C08 answer (mobs)"
  @combat "step 5 of the scenario: B targets and fights the mob 5375, A targets B (combat); its packets and the HP and SP changes of the fight"
  # X14B is created in the capture: its number comes from the database sequence (8 in the capture), which other tests
  # move on (SQLite keeps the highest id it gave), so every packet that carries it binds it as an identifier.
  @x14b_number for(
                 mod <- [
                   P.CharClientBaseCmd,
                   P.CharClientQuestDoingCmd,
                   P.CharClientQuestDoneCmd,
                   P.CharClientQuestRepeatCmd
                 ],
                 do: {mod, :chrregnum, :character, "identifier: the character number of X14B, created in the capture"}
               )

  @tick_position "B's position at the tick that brings it into sight: the original's tick phase and handling delays are not in the capture. No milestone removes it"
  @npc_order "two NPCs at B's sight border enter 46 ms apart in the original and in the other order in the rebuild: the positions of B's run between its requests (tick phase, handling delay) are not in the capture. No milestone removes it"

  # the module-wide abstate deferrals hide the &hide and &show packets; this test defers them by index
  defp without_abstates(deferrals),
    do:
      Enum.reject(
        deferrals,
        &match?({:absent, m, _, _} when m in [P.BatAbstateinformNoeffectCmd, P.BatAbstateresetCmd], &1)
      )

  @second_client_deferrals [
    {:payload, [10_853], P.BatHpchangeCmd, :order, 4,
     "the HP change counter after the map change counts the HP changes of the fight (combat)"},
    {:unsent, 10_776, [], 10, @kq_again},
    {:payload, [10_724], P.BriefinfoLogincharacterCmd, :x, 2, @running_inform},
    {:payload, [10_724], P.BriefinfoLogincharacterCmd, :y, 2, @running_inform},
    {:payload, [10_724], P.BriefinfoLogincharacterCmd, :dir, 2, @running_inform},
    {:payload, [1130], P.BriefinfoLogincharacterCmd, :y, 2, @running_inform},
    {:absent, U.BriefinfoDropeditemCmd, 3, "the item the mob drops (items)"},
    {:absent, [1153], 3, "0x1805 of the dropped item 10500 when it vanishes (items)"},
    {:absent, [1057, 1058], 4, "0x1805 of the killed mob 5375 (combat)"},
    {:absent, [898, 913, 930, 955, 966, 973, 995, 1020, 992, 1017, 1043], 4, @combat},
    {:absent, [916, 918], 4, "the chat line 0x2002 of the mob 5375 (mobs)"},
    {:unsent, 653, [], 4, @combat},
    {:unsent, 720, [], 4, @combat},
    {:unsent, 843, [], 4, @combat},
    {:unsent, 867, [], 4, @combat},
    {:unsent, 878, [], 4, @combat},
    {:unsent, 934, [], 4, @combat},
    {:unsent, 978, [], 4, @combat},
    {:unsent, 1003, [], 4, @combat},
    {:unsent, 1023, [], 4, @combat},
    {:absent, U.BatTargetinfoCmd, 4, @combat},
    {:absent, U.BatExpgainCmd, 4, @combat},
    {:absent, U.BatSkillbashCastSucAck, 4, @combat},
    {:absent, U.BatCeaseFireCmd, 4, @combat},
    {:absent, U.BatSwingStartCmd, 4, @combat},
    {:absent, U.BatSwingDamageCmd, 4, @combat},
    {:absent, U.BatSomeoneswingDamageCmd, 4, @combat},
    {:absent, U.BatPkinpkfieldWmsCmd, 4, @combat},
    {:absent, U.BatSkillbashHitObjStartCmd, 4, @combat},
    {:absent, U.BatSomeoneskillbashHitObjStartCmd, 4, @combat},
    {:absent, U.BatSkillbashHitDamageCmd, 4, @combat},
    {:absent, U.BatSkillbashHitBlastCmd, 4, @combat},
    {:payload, P.BriefinfoLogincharacterCmd, :equip, 3,
     "Equ_LeftHand: B's starting weapon, which the rebuild does not equip on the new character (items)"},
    {:payload, [383], P.BriefinfoLogincharacterCmd, :x, 2, @tick_position},
    {:payload, [383], P.BriefinfoLogincharacterCmd, :y, 2, @tick_position},
    {:payload, P.BriefinfoLogincharacterCmd, :title_type, 6, "the current title of Test1235 (titles)"},
    {:payload, P.BriefinfoLogincharacterCmd, :title_element, 6, "the current title of Test1235 (titles)"},
    {:absent, [372], 4,
     "0x1C0E of object 14204: no packet of the capture introduces this handle, it is not a player and not an NPC of the rebuild (objects)"},
    {:payload, [354, 356], P.BriefinfoRegenmobCmd, :all, 2, @npc_order},
    {:unsent, 231, [290], 2, @inventory_race},
    {:unsent, 232, [298], 2, @inventory_race},
    {:payload, [273], P.ChargedBoothslotsizeCmd, :size, 6,
     "the booth slot count of the new character X14B (booth size); the placeholder sends 5"},
    {:absent, [307], 9, "the 0x9010 at 114.8 s with the item change (charged items)"},
    {:absent, [297, 310], 3, "the 0x3001 item cell changes of the new character (items)"},
    {:unsent, 299, [300], 3, "0x200A on an NPC whose role is not Gate and its 0x4401 menu (NPC menus)"},
    {:absent, [265], 3,
     "B's starting weapon (1750) the original shows at the first map login of the new character; its 0x1406 lists no worn item (items)"},
    {:unsent, 214, [216], 2, @prison_race},
    {:extra, P.CharClientItemCmd, 3,
     "the placeholder sends an empty 0x1047 for each of the boxes 9, 8, 12 and 15; the original leaves out an empty box other than 15, which needs the loaded boxes (items)"},
    {:absent,
     [139, 142, 143, 304, 305, 306, 308, 309, 462, 463, 464, 465, 639, 640, 641, 642, 711, 712, 713, 714] ++
       [956, 957, 958, 959, 1088, 1111, 1135, 1136, 1137, 1138, 8861, 8862, 8863, 8864, 10_864] ++
       [10_926, 10_927, 10_929, 10_930], 4, @param_1035},
    {:unsent, 49, [55, 56, 57, 58], 10, @kq_race},
    {:unsent, 225, [286, 287, 288, 289], 10, @kq_race},
    {:absent, [96, 98, 269, 10_818, 10_820, 10_822, 10_824, 10_826, 10_828, 10_830], 4,
     "the abstates 345 and 291 of the captured characters (abstates); the 0x242A of &hide at 1086 is compared"},
    {:absent, [138, 303, 1089, 1090, 10_863], 4,
     "the abstate resets of the login protection (abstates); the 0x2428 of &show at 1110 and 1112 are compared"},
    {:payload, P.CharClientCoininfoCmd, :exchangeable, 11,
     "the exchangeable coins of the captured characters (coins); the placeholder sends the value of idle_in_world"},
    {:payload, P.CharMysteryvaultUiStateCmd, :state, 11,
     "the mystery vault window state of the captured characters (mystery vault); the placeholder sends 0"},
    {:payload, P.BriefinfoLogincharacterCmd, :abstatebit, 4, "the abstate bits (abstates)"},
    {:payload, P.BriefinfoCharacterCmd, [:chars, :abstatebit], 4, "the abstate bits (abstates)"},
    {:absent, U.BriefinfoAbstateChangeListCmd, 4, "the abstate list of a player in sight (abstates)"},
    {:absent, U.BatAbstatesetCmd, 4, "the abstate set of a player in sight (abstates)"},
    {:absent, U.CharUseitemMinimonUseBroadCmd, 9, "the mini-mon broadcast of a player that enters (charged items)"}
  ]

  @p02_b27 "P02-B27, 431 s to 492 s (between &dimension 1 and &dimension 0): the original sends an appear and a delete of every object near the GM for each of its steps across dimensions; fixed by decision (issue 90). No milestone removes it"
  @dimension_exchange "the exchange of a dimension change (issue 154): the GM gets the delete or the appear of every object whose sight changes, the players that see it now its appear; the original sends none at the command and storms on every step instead (P02-B27). No milestone removes it"

  # The storm of P02-B27 in the window between &dimension 1 (1149) and &dimension 0 (10702): appears (0x1C06 of the
  # other player; to the GM A also 0x1C08 of an NPC), the move resent right behind an appear of the same handle and
  # time, deletes (0x1C0E of the other player; to A also of an NPC), and the client's 0x1C01 answered inside it.
  # Monsters are left to the :mobs deferral, with their moves and deletes by index (monster_packets/2).
  defp computed_deferrals(transcript) do
    npcs = npc_handles(transcript, true)
    window = for p <- transcript.packets, p.index > 1149 and p.index < 10_702, do: p

    storm =
      window
      |> Enum.chunk_every(2, 1, [nil])
      |> Enum.flat_map(fn [p, next] -> storm(p, next, npcs) end)
      |> MapSet.new()

    informs = informs(transcript)

    # a 0x1C01 for a monster: its 0x1C08 answer stays for the :mobs deferral, which takes it out and learns the handle
    mob_informs =
      for {c, a} <- informs, a.opcode == 0x1C08 and handle(a) not in npcs, do: {:unsent, c.index, [], 4, @mob_inform}

    storm_informs = for {c, a} <- informs, a.index in storm, do: {:unsent, c.index, [a.index], 2, @p02_b27}
    answers = MapSet.new(storm_informs, fn {:unsent, _c, [a], _m, _r} -> a end)

    [
      {:absent, storm |> MapSet.difference(answers) |> Enum.sort(), 2, @p02_b27},
      {:absent, monster_packets(transcript, npc_handles(transcript, false)), 4,
       "the moves and deletes of the monsters of the map (mobs)"}
    ] ++ storm_informs ++ mob_informs
  end

  # the handles of the NPCs (true) or the monsters (false) of the 0x1C08 appears
  defp npc_handles(transcript, npc?) do
    for %{dir: :server, opcode: 0x1C08, payload: <<h::little-16, _mode, mob_id::little-16, _::binary>>} <-
          transcript.packets,
        npc?("RouN", mob_id) == npc?,
        into: MapSet.new(),
        do: h
  end

  # 0x1C01 requests with the first server packet of the connection about the handle
  defp informs(transcript) do
    for %{dir: :client, opcode: 0x1C01, payload: <<_own::16, _command::16, h::little-16>>} = c <- transcript.packets,
        answer = Enum.find(transcript.packets, &answer?(&1, c, h)),
        answer != nil,
        do: {c, answer}
  end

  # The :mobs deferral leaves out a monster only from an appear to its delete, but to a GM in dimension -1 the
  # original relays monster moves before their next appear.
  defp monster_packets(transcript, monsters) do
    for %{dir: :server, opcode: op} = p <- transcript.packets,
        op in [0x2018, 0x201A, 0x2013, 0x1C0E] and handle(p) in monsters,
        do: p.index
  end

  defp deferred_indices({:absent, indices, _m, _r}) when is_list(indices), do: indices
  defp deferred_indices({:unsent, c, answers, _m, _r}), do: [c | answers]
  defp deferred_indices({:payload, indices, _mod, _path, _m, _r}), do: indices
  defp deferred_indices(_entry), do: []

  defp answer?(p, c, h), do: p.index > c.index and p.conn == c.conn and p.dir == :server and handle(p) == h

  @other %{"zone#1" => 0x1F41, "zone#2" => 0x1F40}

  defp storm(%{dir: :server, opcode: op, conn: conn} = p, next, npcs) when op in [0x1C06, 0x1C08] do
    h = handle(p)

    cond do
      not storm_object?(op, conn, h, npcs) -> []
      resent?(p, next, h) -> [p.index, next.index]
      true -> [p.index]
    end
  end

  defp storm(%{dir: :server, opcode: 0x1C0E, conn: conn} = p, _next, npcs),
    do: if(storm_object?(0x1C08, conn, handle(p), npcs), do: [p.index], else: [])

  defp storm(_p, _next, _npcs), do: []

  # the other player on either connection; an NPC only on the GM's connection
  defp storm_object?(op, conn, h, npcs), do: h == @other[conn] or (op == 0x1C08 and conn == "zone#1" and h in npcs)

  defp resent?(p, next, h),
    do:
      next != nil and next.conn == p.conn and next.time == p.time and next.opcode in [0x2018, 0x201A] and
        handle(next) == h

  defp handle(%{payload: <<h::little-16, _::binary>>}), do: h
  defp handle(_p), do: :none

  # zone#1 is A (Test1235, admin level 100), zone#2 is B (X14B, created in the capture by 0x1401, admin level 0).
  @dimension_deferrals [
    {:extra, P.BriefinfoBriefinfodeleteCmd, 2, @dimension_exchange},
    {:extra, P.BriefinfoLogincharacterCmd, 2, @dimension_exchange},
    {:extra, P.BriefinfoRegenmobCmd, 2, @dimension_exchange}
  ]

  # Played to the end: B's login, character creation and tutorial skip, both entries, the moves and the sight between
  # them, the shouts, the whispers, the stance, the emotes and jumps, and A's GM commands: &hide (0x242A to A, 0x1805
  # to B), &show (0x2428 to both), &dimensio 1 ("Invalid command"), &dimension 1, -1, -1, 70000 and 0 (0x1805 to B
  # where B saw A before), &linkto (0x1809 to a free cell of RouN: TestRandomSpot gives the captured x 4975, y 5825)
  # and the map entry after it. B's &adminlevel (level 0) is played and answers nothing. Deferred: the combat of step
  # 5 (milestone 4), the P02-B27 storm between &dimension 1 and &dimension 0 (computed_deferrals/1), the packets of
  # our dimension exchange the capture does not have (@dimension_deferrals, issue 154), abstates, monsters, items,
  # the regular 0x1035. late_ms: 200 as in walk-run-portals.
  test "26_11_15_14_second-client-in-sight" do
    name = "26_11_15_14_second-client-in-sight"
    transcript = "transcripts/#{name}.txt" |> Path.expand(__DIR__) |> Replay.Transcript.read!()
    on_exit(fn -> Replay.Topology.all(Application, :delete_env, [:pinata, :random_source]) end)

    deferrals =
      without_abstates(@deferrals ++ @in_world) ++
        @second_client_deferrals ++ computed_deferrals(transcript) ++ @dimension_deferrals

    # the GM command lines are sent and their answers compared (none of them deferred)
    touched = Enum.flat_map(deferrals, &deferred_indices/1)
    gm_lines = [1085, 1109, 1147, 1149, 6453, 7138, 8417, 10_702, 10_773]
    answers = [1086, 1087, 1110, 1112, 1148, 1150, 7139, 8418, 10_774, 10_775]
    assert Enum.filter(gm_lines ++ answers, &(&1 in touched)) == []

    replay(name, :second_client_in_sight, :end,
      deferrals: deferrals,
      masks: @walk_sit_emote_masks,
      late_ms: 200,
      handles: @x14b_number,
      before: %{
        10_773 => fn -> Replay.Topology.all(Application, :put_env, [:pinata, :random_source, TestRandomSpot]) end
      }
    )
  end
end
