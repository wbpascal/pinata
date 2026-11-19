defmodule WorldManager.Avatar do
  @moduledoc false

  import Bitwise

  alias Proto.Packets.Avatar
  alias Proto.Packets.AvatarDeleteInfo

  # equipment slot (ItemEquipEnum) => index in AVATAR.equip
  @equip_index %{
    1 => 0,
    24 => 1,
    12 => 2,
    7 => 3,
    10 => 4,
    19 => 5,
    21 => 6,
    22 => 7,
    20 => 8,
    8 => 9,
    27 => 10,
    28 => 11,
    26 => 12,
    11 => 13,
    13 => 14,
    9 => 15,
    17 => 16,
    18 => 17,
    25 => 18,
    29 => 19
  }

  @spec from_character(Persistence.character()) :: Avatar.t()
  def from_character(c) do
    equip = Map.new(c.equipment, &{&1.slot, &1})
    {{y, mo, d}, {h, mi, s}} = Clock.local_time(DateTime.to_unix(c.kq_date))
    date = (y &&& 0xF) ||| mo <<< 4 ||| d <<< 8 ||| h <<< 13 ||| mi <<< 18

    %Avatar{
      chrregnum: c.id,
      name: c.name,
      level: c.level,
      slot: c.slot,
      # P02-B33 kept: a character that has not started the tutorial is sent to "RouT" (milestone 2)
      loginmap: if(c.tutorial_state == 0, do: "RouT", else: c.login_map),
      delinfo: %AvatarDeleteInfo{year: 0, month: 0, day: 0, hour: 0, min: 0},
      gender: c.gender,
      chrclass: c.class,
      race: c.race,
      hairtype: c.hair,
      haircolor: c.hair_color,
      faceshape: c.face,
      equip: for(slot <- equip_slots(), do: item_id(equip, slot)),
      upgrade_lefthand: upgrade(equip, 10),
      upgrade_righthand: upgrade(equip, 12),
      upgrade_body: upgrade(equip, 7),
      upgrade_leg: upgrade(equip, 19),
      upgrade_shoes: upgrade(equip, 21),
      upgrade_unused: 0xF,
      kq_handle: 0xFFFFFFFF,
      kq_map_name: c.kq_map,
      kq_x: c.kq_x,
      kq_y: c.kq_y,
      kq_date: <<date::little-24>>,
      kq_date_unused: 0,
      kq_date_sec: s,
      need_change_id: 0,
      change_id_init: 0x64,
      change_id_row_no: 0,
      tutorial_state: c.tutorial_state,
      tutorial_step: c.tutorial_step
    }
  end

  defp equip_slots, do: @equip_index |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))

  defp item_id(equip, slot) do
    case equip do
      %{^slot => %{item_id: id}} -> id
      _ -> 0xFFFF
    end
  end

  defp upgrade(equip, slot) do
    case equip do
      %{^slot => %{upgrade: u}} -> band(u, 0xF)
      _ -> 0
    end
  end
end
