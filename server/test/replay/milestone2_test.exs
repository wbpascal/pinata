# Stand-ins for the packets nobody defines yet: the `:absent` deferral needs a module with `opcode/0`.
defmodule Replay.Milestone2Test.Unbuilt.BriefinfoMobCmd do
  @spec opcode() :: 0..0xFFFF
  def opcode, do: 0x1C09
end

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
      deferrals: opts[:deferrals] || []
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
    {:unsent, 44, [46], 2,
     "order race of the original: its 0x7C07 comes between 0x7005 and 0x700D; the rebuild answers in request order (test/map_entry_test.exs)"},
    {:payload, P.CharOptionGetShortcutsizeAck, :all, 6,
     "the stored shortcut sizes of the captured character (options)"},
    {:payload, P.CharOptionGetWindowposAck, :all, 6, "the stored window positions of the captured character (options)"},
    {:unsent, 52, [127, 128, 129, 130], 10,
     "order race of the original (its 0x581C comes after the WorldManager burst) and the Kingdom Quest list 0x581D (Kingdom Quest); the answer is checked by test/map_entry_test.exs"},
    {:absent, U.BriefinfoMobCmd, 2,
     "the sight exchange: issue 109 builds it for NPCs and players, milestone 4 for mobs (the two captured are mobs)"},
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

  # Stop point 140: the last packet of map entry (0x3021). Behind it: mob moves from 141 (milestone 4), the reset of
  # abstate 291 with its 0x1035 at 145 and 146 (milestone 4), the expiry of the pick-up mini-mon at 161 to 168
  # (milestones 3 and 9) and the logout from 174 (issue 111).
  test "26_11_15_idle_in_world",
    do: replay("26_11_15_idle_in_world", :idle_in_world, 140, deferrals: @deferrals)
end
