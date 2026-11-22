defmodule Zone.MapEntry.Placeholders do
  @moduledoc """
  The placeholder steps of the Zone map-entry burst (`Zone.MapEntry`, issue 88): packets whose data belongs to a
  later milestone, sent empty at their original position. Each function names its milestone; the milestone that
  owns the data replaces the function by a real step. No table or column holds placeholder data.
  """

  alias Proto.Packets.BatHpchangeCmd
  alias Proto.Packets.BatLpchangeCmd
  alias Proto.Packets.BatSpchangeCmd
  alias Proto.Packets.CharChangeparamchangeCmd
  alias Proto.Packets.CharClientCardcollectBookmarkCmd
  alias Proto.Packets.CharClientCardcollectCmd
  alias Proto.Packets.CharClientCardcollectRewardCmd
  alias Proto.Packets.CharClientChargedbuffCmd
  alias Proto.Packets.CharClientChartitleCmd
  alias Proto.Packets.CharClientCoininfoCmd
  alias Proto.Packets.CharClientGameCmd
  alias Proto.Packets.CharClientItemCmd
  alias Proto.Packets.CharClientPassiveCmd
  alias Proto.Packets.CharClientQuestDoingCmd
  alias Proto.Packets.CharClientQuestDoneCmd
  alias Proto.Packets.CharClientQuestReadCmd
  alias Proto.Packets.CharClientQuestRepeatCmd
  alias Proto.Packets.CharClientSkillCmd
  alias Proto.Packets.CharMysteryvaultUiStateCmd
  alias Proto.Packets.CharParameterData
  alias Proto.Packets.CharStatRemainpointCmd
  alias Proto.Packets.CharUseitemMinimonInfoClientCmd
  alias Proto.Packets.ChargedBoothslotsizeCmd
  alias Proto.Packets.ItemChargedinvenopenAck
  alias Proto.Packets.ItemRewardinvenopenAck
  alias Proto.Packets.KqTeamTypeCmd
  alias Proto.Packets.ParamChange
  alias Proto.Packets.QuestResetTimeClientCmd
  alias Proto.Packets.SkillItemactioncooltimeCmd

  # The flags of the 0x1035 of the original map login, in its order (capture 26_11_15_idle_in_world).
  @refresh_flags [0x10, 0x11, 0x24, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B] ++
                   [0x00, 0x01, 0x02, 0x03, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D]

  @doc "Placeholder until milestone 5 (quests): `0x103A` with no running quest."
  @spec quest_doing(Zone.Player.t()) :: [struct()]
  def quest_doing(%Zone.Player{} = p), do: [%CharClientQuestDoingCmd{chrregnum: id(p), need_clear: 1, count: 0}]

  @doc "Placeholder until milestone 5 (quests): `0x103B` with no done quest."
  @spec quest_done(Zone.Player.t()) :: [struct()]
  def quest_done(%Zone.Player{} = p),
    do: [%CharClientQuestDoneCmd{chrregnum: id(p), total: 0, total_size: 12, count: 0, index: 0}]

  @doc "Placeholder until milestone 5 (quests): `0x10CE` with no read quest."
  @spec quest_read(Zone.Player.t()) :: [struct()]
  def quest_read(%Zone.Player{} = p), do: [%CharClientQuestReadCmd{chrregnum: id(p), count: 0}]

  @doc "Placeholder until milestone 5 (quests): `0x10D7` with no repeatable quest."
  @spec quest_repeat(Zone.Player.t()) :: [struct()]
  def quest_repeat(%Zone.Player{} = p), do: [%CharClientQuestRepeatCmd{chrregnum: id(p), count: 0}]

  @doc "Placeholder until milestone 4 (skills): `0x103D` with no skill, one part (start and end)."
  @spec skills(Zone.Player.t()) :: [struct()]
  def skills(%Zone.Player{} = p),
    do: [%CharClientSkillCmd{rest_empower: 0, part_mark: 3, max_count: 0, chrregnum: id(p), count: 0}]

  @doc "Placeholder until milestone 4 (passives): `0x103E` with no passive skill."
  @spec passives(Zone.Player.t()) :: [struct()]
  def passives(%Zone.Player{}), do: [%CharClientPassiveCmd{count: 0}]

  @doc "Placeholder until milestone 3 (items): `0x1047` for the boxes 9, 8, 12 and 15, each empty with flag 1 (clear the box)."
  @spec items(Zone.Player.t()) :: [struct()]
  def items(%Zone.Player{}), do: for(box <- [9, 8, 12, 15], do: %CharClientItemCmd{count: 0, box: box, flag: 1})

  @doc "Placeholder until milestone 6 (titles): `0x1049` with no title."
  @spec titles(Zone.Player.t()) :: [struct()]
  def titles(%Zone.Player{}),
    do: [%CharClientChartitleCmd{current_title: 0, current_element: 0, current_mob_id: 0, count: 0}]

  @doc "Placeholder until milestone 9 (charged buffs): `0x104A` with no charged buff."
  @spec charged_buffs(Zone.Player.t()) :: [struct()]
  def charged_buffs(%Zone.Player{}), do: [%CharClientChargedbuffCmd{count: 0}]

  @doc "Placeholder until milestone 6 (party numbers): `0x1048` with no party and no raid."
  @spec party(Zone.Player.t()) :: [struct()]
  def party(%Zone.Player{}), do: [%CharClientGameCmd{party_no: 0xFFFF, raid_no: 0xFFFF}]

  @doc "Placeholder until milestone 11 (coins): `0x10DE` of a character that never used coins (the captured values)."
  @spec coins(Zone.Player.t()) :: [struct()]
  def coins(%Zone.Player{}), do: [%CharClientCoininfoCmd{coin: 0, exchangeable: 1_000_000}]

  @doc "Placeholder until milestone 5 (quests): `0x441E` with every reset time 0."
  @spec quest_reset_time(Zone.Player.t()) :: [struct()]
  def quest_reset_time(%Zone.Player{}), do: [%QuestResetTimeClientCmd{year: 0, month: 0, week: 0, day: 0}]

  @doc """
  Placeholder until milestone 4 (parameters): the parameter block of `0x1802`, the stored HP and SP as maximum,
  everything else 0 (so also the stale `Wizdom` bytes of the original, Z07-B7).
  """
  @spec parameters(Zone.Player.t()) :: CharParameterData.t()
  def parameters(%Zone.Player{character: c}) do
    %CharParameterData{
      prev_exp: 0,
      next_exp: 0,
      stats: <<0::size(128 * 8)>>,
      max_hp: c.hp,
      max_sp: c.sp,
      max_lp: 0,
      max_ap: 0,
      max_hp_stone: 0,
      max_sp_stone: 0,
      rest: <<0::size(64 * 8)>>
    }
  end

  @doc "Placeholder until milestone 11 (card collection): `0x10E4`, `0x10E7`, `0x10EA`, each empty (Z18-B19: `chrregnum` is unwritten in the original; we send 0)."
  @spec card_collection(Zone.Player.t()) :: [struct()]
  def card_collection(%Zone.Player{}) do
    [
      %CharClientCardcollectCmd{chrregnum: 0, count: 0},
      %CharClientCardcollectBookmarkCmd{chrregnum: 0, count: 0},
      %CharClientCardcollectRewardCmd{chrregnum: 0, count: 0}
    ]
  end

  @doc "Placeholder until milestone 10 (Kingdom Quest): `0x583A` with team type 2, the value outside a Kingdom Quest."
  @spec kq_team_type(Zone.Player.t()) :: [struct()]
  def kq_team_type(%Zone.Player{}), do: [%KqTeamTypeCmd{team_type: 2}]

  @doc "Placeholder until milestone 4 (stat points): `0x105B` with no unspent point."
  @spec stat_points(Zone.Player.t()) :: [struct()]
  def stat_points(%Zone.Player{}), do: [%CharStatRemainpointCmd{remain: 0}]

  @doc "Placeholder until milestone 6 (booth size): `0x9010` with the default 5 slots."
  @spec booth_size(Zone.Player.t()) :: [struct()]
  def booth_size(%Zone.Player{}), do: [%ChargedBoothslotsizeCmd{size: 5}]

  @doc "Placeholder until milestone 9 (mini-mon): `0x1123` with no mini-mon item (0xFFFF everywhere)."
  @spec minimon_info(Zone.Player.t()) :: [struct()]
  def minimon_info(%Zone.Player{}) do
    none = List.duplicate(0xFFFF, 12)
    [%CharUseitemMinimonInfoClientCmd{normal: 0, charged: 0, normal_items: none, charged_items: none}]
  end

  @doc "Placeholder until milestone 4 (item action cool-downs): `0x482C` with no cool-down."
  @spec item_action_cooltime(Zone.Player.t()) :: [struct()]
  def item_action_cooltime(%Zone.Player{}), do: [%SkillItemactioncooltimeCmd{count: 0}]

  @doc "Placeholder until milestone 11 (mystery vault): `0x10D4` with state 0."
  @spec mystery_vault(Zone.Player.t()) :: [struct()]
  def mystery_vault(%Zone.Player{}), do: [%CharMysteryvaultUiStateCmd{state: 0}]

  @doc """
  Placeholder until milestone 4 (parameters): the parameter refresh at the end of the `0x1803` answer. `0x1035`
  with the 26 parameters of the original in its order, stored HP and SP for the flags 0x10 and 0x11 and 0 for the
  others; then `0x240E` (HP, order 1), `0x240F` (SP) and `0x245F` (LP 0). The original sends them one tick later;
  here they end the answer, in the same order on the wire. Milestone 4 decides about the tick.
  """
  @spec parameter_refresh(Zone.Player.t()) :: [struct()]
  def parameter_refresh(%Zone.Player{character: c}) do
    params =
      for flag <- @refresh_flags do
        %ParamChange{flag: flag, value: refresh_value(flag, c)}
      end

    [
      %CharChangeparamchangeCmd{params: params},
      %BatHpchangeCmd{hp: c.hp, order: 1},
      %BatSpchangeCmd{sp: c.sp},
      %BatLpchangeCmd{lp: 0}
    ]
  end

  @doc "Placeholder until milestone 3 (reward inventory): the answer `0x302D` to `0x302C`, empty (P02-B3: the stray byte of the original is 0)."
  @spec reward_inventory() :: ItemRewardinvenopenAck.t()
  def reward_inventory, do: %ItemRewardinvenopenAck{count: 0, stray: 0}

  @doc "Placeholder until milestone 9 (charged inventory): the answer `0x3021` to `0x3020`, empty with the captured code 0x1041."
  @spec charged_inventory() :: ItemChargedinvenopenAck.t()
  def charged_inventory, do: %ItemChargedinvenopenAck{error: 0x1041, part_mark: 3, count: 0}

  defp refresh_value(0x10, c), do: c.hp
  defp refresh_value(0x11, c), do: c.sp
  defp refresh_value(_flag, _c), do: 0

  defp id(%Zone.Player{character: c}), do: c.id
end
