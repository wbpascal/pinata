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

defmodule Replay.Milestone2Test.Unbuilt.ActSomeoneMoveWalkCmd do
  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x2018
end

defmodule Replay.Milestone2Test.Unbuilt.ActSomeoneMoveRunCmd do
  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x201A
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
      drop_after: opts[:drop_after] || []
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
       about: [],
       npc?: &__MODULE__.npc?/2
     }, 4, "the monsters of the map (mobs); the NPC elements of 0x1C09 are compared"},
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
  @mob_moves "mob moves (mobs, milestone 4); issue 110 defines the packets and must narrow this to a :mobs deferral"

  # Behind a map entry: mob moves, abstate resets and the Kingdom Quest notices.
  @in_world [
    {:absent, U.ActSomeoneMoveWalkCmd, 4, @mob_moves},
    {:absent, U.ActSomeoneMoveRunCmd, 4, @mob_moves},
    {:absent, U.BatAbstateresetCmd, 4, "the reset of abstate 291 (abstates)"},
    {:absent, U.KqListUpdateAck, 10, "the Kingdom Quest list updates (Kingdom Quest)"},
    {:absent, U.KqJoiningAlarmCmd, 10, "the Kingdom Quest joining alarm (Kingdom Quest)"}
  ]

  # Behind the map entry (140): mob moves (milestone 4), the reset of abstate 291 with its 0x1035 at 145 and 146
  # (milestone 4), the expiry of the pick-up mini-mon at 161 to 168 (milestones 3 and 9), the Kingdom Quest notices
  # (milestone 10) and the leave: 0x2012, 0x1071 and the option saves get no answer, 0x0C18 {0} ends the session.
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
  # resets at 292.5 s and 423.4 s. 0x2001 (&adminlevel), 0x2012 and 0x2019 are sent; the server drops them (issues
  # 116 and 110).
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
end
