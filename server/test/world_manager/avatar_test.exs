defmodule WorldManager.AvatarTest do
  use ExUnit.Case, async: false

  setup do
    Application.put_env(:pinata, :clock_source, TestClock)
    on_exit(fn -> Application.delete_env(:pinata, :clock_source) end)
  end

  test "the Kingdom Quest date of a character is packed in local time" do
    character = %{
      id: 2,
      slot: 0,
      name: "Test1235",
      level: 120,
      login_map: "RouN",
      race: 2,
      class: 11,
      gender: 1,
      hair: 4,
      hair_color: 0,
      face: 0,
      kq_map: "RouN",
      kq_x: 6477,
      kq_y: 9844,
      kq_date: ~U[2026-11-13 11:57:15Z],
      tutorial_state: 2,
      tutorial_step: 0,
      equipment: []
    }

    avatar = WorldManager.Avatar.from_character(character)
    assert avatar.kq_date == <<0xBA, 0x8D, 0xE5>>
    assert avatar.kq_date_sec == 15
    assert avatar.equip == List.duplicate(0xFFFF, 20)
    assert Proto.Packets.Avatar.__packet__().size == 130
  end
end
