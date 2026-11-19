defmodule GameDataTest do
  use ExUnit.Case, async: true

  @dir System.fetch_env!("PINATA_TEST_DATA_DIR")

  test "the tables of the WorldManager part load without warnings" do
    assert {:ok, tables, []} = GameData.Loader.parse(@dir, WorldManager.game_data(), true)
    assert map_size(tables) == 12
  end

  test "bad names" do
    assert [%{bad_name: "GM"} | _] =
             Enum.filter(GameData.lookup(GameData.BadNameFilter, :type, 1), &(&1.bad_name == "GM"))
  end

  test "character defaults" do
    assert {:ok, one} = GameData.fetch(GameData.CharDefault, 1)
    assert %{start_map: "RouN", start_x: 6888, start_y: 7045, hp: 52, sp: 10, init_level: 1} = one

    assert {:ok, %{start_map: "Eld", start_x: 12_259, start_y: 13_434, init_level: 60, init_exp: 24_346_145}} =
             GameData.fetch(GameData.CharDefault, 26)

    assert GameData.fetch(GameData.CharDefault, 2) == :error
  end

  test "lookup by class" do
    assert [%{item_id: 46_003, lot: 1} = item] = GameData.lookup(GameData.CharDefaultItem, :class, 1)
    assert [first | _] = items = GameData.lookup(GameData.CharDefaultItem, :class, 26)
    assert length(items) == 12
    assert first.item_id == 62_923
    assert List.last(items).item_id == 46_012
    assert GameData.lookup(GameData.CharDefaultItem, :class, 99) == []

    assert {:ok, %GameData.ItemInfo{id: 46_003}} = GameData.follow(item, :item_id)
  end

  test "follow a reference" do
    {:ok, one} = GameData.fetch(GameData.CharDefault, 1)
    assert {:ok, %GameData.MapInfo{map_name: "RouN"}} = GameData.follow(one, :start_map)
  end

  test "client data tables" do
    assert {:ok, %{value: 60}} = GameData.fetch(GameData.SingleData, "ChrLevel_CanCreateSen")
    assert {:ok, %{grade: 0}} = GameData.fetch(GameData.HairInfo, 0)
    assert {:ok, %{grade: 255}} = GameData.fetch(GameData.FaceInfo, 1)
  end

  test "a missing data directory is reported with the import task" do
    assert {:error, [message]} = GameData.load("/nonexistent/pinata", [], strict_references: true)
    assert message =~ "mix pinata.import_data"
  end
end
