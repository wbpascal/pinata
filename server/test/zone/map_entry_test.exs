defmodule Zone.MapEntryTest do
  use ExUnit.Case, async: true

  defp player(fields \\ %{}) do
    character = %{
      id: 2,
      slot: 0,
      name: "Test1235",
      level: 120,
      exp: 10,
      login_map: "RouN",
      login_x: 6477,
      login_y: 9844,
      hp: 3043,
      sp: 2851,
      money: 99_999_634_524,
      hp_stones: 386,
      sp_stones: 364,
      race: 2,
      class: 11,
      gender: 1,
      hair: 4,
      hair_color: 0,
      face: 0,
      equipment: []
    }

    struct!(
      %Zone.Player{
        character: character,
        world_no: 0,
        map: "RouN",
        x: 6477,
        y: 9844,
        walk_speed: 33,
        run_speed: 127,
        map_type: 0,
        equipment: [],
        address: "172.16.42.231",
        handle: 8000
      },
      fields
    )
  end

  defp opcodes(packets), do: Enum.map(packets, & &1.__struct__.opcode())
  defp hex(packet), do: packet |> Proto.encode() |> Base.encode16(case: :lower)

  test "login/1: the first burst in wire order" do
    packets = Zone.MapEntry.login(player())

    assert opcodes(packets) ==
             [0x1038, 0x1039, 0x103A, 0x103B, 0x10CE, 0x10D7, 0x103D, 0x103E] ++
               [0x1047, 0x1047, 0x1047, 0x1047, 0x1049, 0x104A, 0x1048, 0x10DE, 0x441E, 0x1802]

    # the captured 0x1038 of 26_11_15_idle_in_world with fame, stat distribution and admin level 0
    assert hex(hd(packets)) ==
             "3810" <>
               "02000000546573743132333500000000000000000000000000780a000000000000000000000082016c01e30b0000230b" <>
               "000000000000000000005c54714817000000526f754e00000000000000004d190000742600005a0000000000000000" <>
               "00000000000000000000"

    assert hex(Enum.at(packets, 1)) == "3910ae040000"
    assert hex(Enum.at(packets, 2)) == "3a10020000000100"
    assert hex(Enum.at(packets, 3)) == "3b100200000000000c0000000000"
    assert Enum.map(Enum.slice(packets, 8, 4), &hex/1) == ["4710000901", "4710000801", "4710000c01", "4710000f01"]
    assert hex(Enum.at(packets, 14)) == "4810ffffffff"
    assert hex(Enum.at(packets, 15)) == "de10000000000000000040420f0000000000"

    ack = List.last(packets)
    assert %Proto.Packets.MapLoginAck{handle: 8000, x: 6477, y: 9844} = ack
    assert %{max_hp: 3043, max_sp: 2851, prev_exp: 0, max_lp: 0} = ack.param
    assert byte_size(Proto.encode(ack)) == 2 + 242
  end

  test "login_complete/1: the second burst in wire order" do
    p = player(%{equipment: [%{slot: 8, item_id: 35_740, upgrade: 0, class: 10}]})
    packets = Zone.MapEntry.login_complete(p)

    assert opcodes(packets) ==
             [0x10E4, 0x10E7, 0x10EA] ++
               List.duplicate(0x1C04, 29) ++
               [0x1C02, 0x583A, 0x105B, 0x203E, 0x9010, 0x182B, 0x1123, 0x482C, 0x10D4, 0x1827] ++
               [0x1035, 0x240E, 0x240F, 0x245F]

    assert Enum.map(Enum.slice(packets, 3, 2), &hex/1) == ["041c401f01", "041c401f02"]
    # the captured 0x1C02
    assert hex(Enum.at(packets, 32)) == "021c401f9c8b08"
    assert hex(Enum.at(packets, 35)) == "3e2021007f00"

    assert hex(Enum.at(packets, 38)) ==
             "2311" <> "0000" <> String.duplicate("ff", 48)

    refresh = Enum.at(packets, 42)
    assert length(refresh.params) == 26
    assert hd(refresh.params) == %Proto.Packets.ParamChange{flag: 0x10, value: 3043}
    assert Enum.at(refresh.params, 1) == %Proto.Packets.ParamChange{flag: 0x11, value: 2851}
    assert Enum.all?(Enum.drop(refresh.params, 2), &(&1.value == 0))
    # the captured 0x240E, 0x240F and 0x245F
    assert Enum.map(Enum.take(packets, -3), &hex/1) == ["0e24e30b00000100", "0f24230b0000", "5f2400000000"]
  end

  test "an admin level sends 0x2011 and 0x10C6 at their positions" do
    packets = Zone.MapEntry.login_complete(player(%{admin_level: 100}))
    ops = opcodes(packets)

    assert Enum.slice(ops, -12, 12) ==
             [0x9010, 0x182B, 0x2011, 0x1123, 0x10C6, 0x482C, 0x10D4, 0x1827] ++
               [0x1035, 0x240E, 0x240F, 0x245F]

    # "From 172.16.42.231" as captured, with the unwritten first byte (Z09-B54) as 0
    assert hex(Enum.find(packets, &match?(%Proto.Packets.ActNoticeCmd{}, &1))) ==
             "1120" <> "00" <> "12" <> Base.encode16("From 172.16.42.231", case: :lower)

    assert hex(Enum.find(packets, &match?(%Proto.Packets.CharAdminLevelInformCmd{}, &1))) == "c61064"
    assert Enum.at(Zone.MapEntry.login(player(%{admin_level: 100})), 0).admin_level == 100
  end

  test "one worn item per class group" do
    equipment = [
      %{slot: 10, item_id: 1250, upgrade: 2, class: 5},
      %{slot: 11, item_id: 1500, upgrade: 1, class: 7},
      %{slot: 12, item_id: 35_740, upgrade: 0, class: 26},
      %{slot: 13, item_id: 7000, upgrade: 0, class: 4},
      %{slot: 14, item_id: 9999, upgrade: 0, class: :unknown}
    ]

    briefs = player(%{equipment: equipment}) |> Zone.MapEntry.login_complete() |> Enum.slice(32, 4)

    assert Enum.map(briefs, &hex/1) == [
             # weapon: upgrade, slot (Z18-B10: written), no licence mob
             "051c401fe20402" <> "0a" <> "ffffff",
             "031c401fdc05010b",
             "021c401f9c8b0c",
             # the amulet sends nothing; an unknown class shows an empty slot
             "041c401f0e"
           ]
  end

  test "placeholder answers of the login-time requests" do
    assert hex(Zone.MapEntry.Placeholders.reward_inventory()) == "2d300000"
    assert hex(Zone.MapEntry.Placeholders.charged_inventory()) == "2130411003" <> "0000"
  end
end
