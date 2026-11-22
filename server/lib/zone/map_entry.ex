defmodule Zone.MapEntry do
  @moduledoc """
  The map-entry burst of the Zone as two ordered lists of named steps (issue 88, flow:
  `docs/technical/flows/map-entry.md`). A step is a function from the player to its packets; real steps are private
  functions here, placeholder steps are in `Zone.MapEntry.Placeholders`, tagged with the milestone that owns them.
  A packet the rebuild does not send yet has a comment at its original position.

  `login/1` is the answer to an accepted `0x1801` (`0x1038` … `0x1802`), `login_complete/2` the answer to `0x1803`;
  its second argument are the packets of the sight exchange (`0x1C07` / `0x1C09`, `Zone.Sight.entry/2`), which the
  map instance computes and which go out after `0x583A`.
  """

  alias Proto.Packets.ActMovespeedCmd
  alias Proto.Packets.ActNoticeCmd
  alias Proto.Packets.BriefinfoChangedecorateCmd
  alias Proto.Packets.BriefinfoChangeupgradeCmd
  alias Proto.Packets.BriefinfoChangeweaponCmd
  alias Proto.Packets.BriefinfoUnequipCmd
  alias Proto.Packets.CharAdminLevelInformCmd
  alias Proto.Packets.CharClientBaseCmd
  alias Proto.Packets.CharClientShapeCmd
  alias Proto.Packets.MapCanUseReviveitemCmd
  alias Proto.Packets.MapFieldAttributeCmd
  alias Proto.Packets.MapLoginAck
  alias Zone.MapEntry.Placeholders

  @doc "The burst after an accepted `0x1801`, in wire order."
  @spec login(Zone.Player.t()) :: [struct()]
  def login(%Zone.Player{} = player), do: Enum.flat_map(login_steps(), & &1.(player))

  @doc "The burst after `0x1803`, in wire order."
  @spec login_complete(Zone.Player.t(), [struct()]) :: [struct()]
  def login_complete(%Zone.Player{} = player, sight_packets),
    do: Enum.flat_map(login_complete_steps(sight_packets), & &1.(player))

  defp login_steps do
    [
      &base/1,
      &shape/1,
      &Placeholders.quest_doing/1,
      &Placeholders.quest_done/1,
      &Placeholders.quest_read/1,
      &Placeholders.quest_repeat/1,
      &Placeholders.skills/1,
      &Placeholders.passives/1,
      &Placeholders.items/1,
      &Placeholders.titles/1,
      &Placeholders.charged_buffs/1,
      &Placeholders.party/1,
      &Placeholders.coins/1,
      &Placeholders.quest_reset_time/1,
      &map_login_ack/1
    ]
  end

  defp login_complete_steps(sight_packets) do
    [
      &Placeholders.card_collection/1,
      &equipment_briefs/1,
      &Placeholders.kq_team_type/1,
      # the sight exchange 0x1C07 / 0x1C09 of the players and NPCs; mobs: milestone 4
      fn _player -> sight_packets end,
      # absent: the abstates 0x242A / 0x1C18 (345, 291 with its reset after 5 s; 728 after the burst), milestone 4
      &Placeholders.stat_points/1,
      &move_speed/1,
      &Placeholders.booth_size/1,
      &can_use_revive_item/1,
      &connect_from/1,
      # absent: the auto-pick state 0x10BD, milestone 9
      &Placeholders.minimon_info/1,
      # absent: the title abstates 0x1C18 / 0x2429, milestone 4
      &rest_minute/1,
      # absent: the prison state 0x7C05, milestone 11
      &admin_level/1,
      &Placeholders.item_action_cooltime/1,
      &Placeholders.mystery_vault/1,
      &field_attribute/1,
      &field_type/1,
      &Placeholders.parameter_refresh/1
    ]
  end

  defp base(%Zone.Player{character: c} = p) do
    [
      %CharClientBaseCmd{
        chrregnum: c.id,
        name: c.name,
        slot: c.slot,
        level: c.level,
        exp: c.exp,
        power_stones: 0,
        guard_stones: 0,
        hp_stones: c.hp_stones,
        sp_stones: c.sp_stones,
        hp: c.hp,
        sp: c.sp,
        lp: 0,
        fame: 0,
        money: c.money,
        map: p.map,
        x: p.x,
        y: p.y,
        dir: p.dir,
        stat_distribute: <<0::48>>,
        pk_yellow_time: 0,
        pk_count: 0,
        prison_minutes: 0,
        admin_level: p.admin_level,
        flags: 0
      }
    ]
  end

  defp shape(%Zone.Player{character: c}),
    do: [
      %CharClientShapeCmd{
        gender: c.gender,
        chrclass: c.class,
        race: c.race,
        hairtype: c.hair,
        haircolor: c.hair_color,
        faceshape: c.face
      }
    ]

  defp map_login_ack(%Zone.Player{} = p),
    do: [%MapLoginAck{handle: p.handle, param: Placeholders.parameters(p), x: p.x, y: p.y}]

  # Every slot is cleared first, then each worn item is shown by its ItemInfo class (Z04 §1, Z18 §4.3).
  defp equipment_briefs(%Zone.Player{handle: h, equipment: equipment}) do
    for(slot <- 1..29, do: %BriefinfoUnequipCmd{handle: h, slot: slot}) ++ Enum.flat_map(equipment, &brief(h, &1))
  end

  # Z18-B10: the original leaves the slot of 0x1C05 unwritten; we write the slot.
  defp brief(h, %{class: 5} = i),
    do: [
      %BriefinfoChangeweaponCmd{
        handle: h,
        item: i.item_id,
        upgrade: i.upgrade,
        slot: i.slot,
        current_mob_id: 0xFFFF,
        current_kill_level: 0xFF
      }
    ]

  defp brief(h, %{class: class} = i) when class in [6, 7, 8],
    do: [%BriefinfoChangeupgradeCmd{handle: h, item: i.item_id, upgrade: i.upgrade, slot: i.slot}]

  defp brief(h, %{class: class} = i) when class in [10, 26, 37],
    do: [%BriefinfoChangedecorateCmd{handle: h, item: i.item_id, slot: i.slot}]

  # amulet and bracelet: not shown on the character
  defp brief(_h, %{class: class}) when class in [4, 38], do: []
  defp brief(h, i), do: [%BriefinfoUnequipCmd{handle: h, slot: i.slot}]

  defp move_speed(%Zone.Player{} = p), do: [%ActMovespeedCmd{walk: p.walk_speed, run: p.run_speed}]

  # 1 is the default of a field map; only scripts change it
  defp can_use_revive_item(%Zone.Player{}), do: [%MapCanUseReviveitemCmd{can_use: 1}]

  # Z09-B54: the first byte is unwritten in the original; we send 0.
  defp connect_from(%Zone.Player{admin_level: 0}), do: []
  defp connect_from(%Zone.Player{} = p), do: [%ActNoticeCmd{unused: 0, text: "From " <> p.address}]

  # 0x0810, the time limit of a map cluster, belongs to instance dungeons; only plain field maps run (milestone 2).
  defp rest_minute(%Zone.Player{}), do: []

  defp admin_level(%Zone.Player{admin_level: 0}), do: []
  defp admin_level(%Zone.Player{admin_level: level}), do: [%CharAdminLevelInformCmd{admin_level: level}]

  defp field_attribute(%Zone.Player{map_type: type}), do: [%MapFieldAttributeCmd{map_type: type}]

  # 0x182C, the field type below 3, belongs to instance dungeons; only plain field maps run (milestone 2).
  defp field_type(%Zone.Player{}), do: []
end
