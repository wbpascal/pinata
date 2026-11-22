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

  describe "digest/1" do
    @describetag :tmp_dir

    defp make(dir, files) do
      Enum.each(files, fn {name, content} ->
        File.mkdir_p!(Path.dirname(Path.join(dir, name)))
        File.write!(Path.join(dir, name), content)
      end)

      dir
    end

    # Excluded where this OS user cannot create symlinks (test_helper.exs).
    @tag :symlink
    test "does not enter symlinked directories", %{tmp_dir: tmp} do
      files = [{"a.txt", "one"}, {"sub/b.txt", "two"}]
      base = GameData.digest(make(Path.join(tmp, "a"), files))
      loop = make(Path.join(tmp, "loop"), files)
      File.ln_s!(loop, Path.join(loop, "self"))
      File.ln_s!(loop, Path.join(loop, "sub/up"))
      assert GameData.digest(loop) == base
    end

    test "depends on content, names and the file set", %{tmp_dir: tmp} do
      files = [{"a.txt", "one"}, {"sub/b.txt", "two"}]
      base = GameData.digest(make(Path.join(tmp, "a"), files))
      assert base =~ ~r/^[0-9a-f]{64}$/
      assert GameData.digest(make(Path.join(tmp, "same"), files)) == base
      refute GameData.digest(make(Path.join(tmp, "byte"), [{"a.txt", "onf"}, {"sub/b.txt", "two"}])) == base
      refute GameData.digest(make(Path.join(tmp, "name"), [{"c.txt", "one"}, {"sub/b.txt", "two"}])) == base
      refute GameData.digest(make(Path.join(tmp, "extra"), [{"x", ""} | files])) == base
    end

    test "leaves out the top-level SQLite files", %{tmp_dir: tmp} do
      files = [{"a.txt", "one"}]
      base = GameData.digest(make(Path.join(tmp, "a"), files))
      assert GameData.digest(make(Path.join(tmp, "b"), [{"pinata.db", "x"}, {"pinata.db-wal", "y"} | files])) == base
    end
  end

  test "the tables of the Zone part load without warnings" do
    assert {:ok, tables, []} = GameData.Loader.parse(@dir, Zone.game_data(), true)
    assert map_size(tables) == 10
    assert {:ok, %{sight: 1600}} = GameData.fetch(GameData.MapInfo, "RouN")

    counts = %{
      GameData.FieldList => 153,
      GameData.ShineNpc => 537,
      GameData.LinkTable => 236,
      GameData.ChrCommon => 15,
      GameData.MobInfo => 2842,
      GameData.TownPortal => 8,
      GameData.SpamerPenalty => 10,
      GameData.SpamerPenaltyRule => 1
    }

    for {schema, count} <- counts, do: assert(map_size(tables[schema].rows) == count)
  end

  test "plain field maps" do
    maps = GameData.plain_field_maps()
    names = Enum.map(maps, & &1.map_id_client)
    assert length(maps) == 88
    assert GameData.count(GameData.FieldList) == 153
    assert Enum.uniq(names) == names
    for name <- ["Linkfield01", "Linkfield02", "Wedding", "RouN"], do: assert(name in names)
    refute "GuildT01" in names
    assert %{map_id_client: "Rou", map_name: "Roumen", chat: 1, shout: 1} = hd(maps)
  end

  test "map table samples" do
    assert [
             %{
               mob_name: "RouSmithJames",
               x: 5645,
               y: 8824,
               direct: -62,
               npc_menu: 1,
               role: "Merchant",
               role_arg: "Weapon"
             }
             | _
           ] =
             GameData.lookup(GameData.ShineNpc, :map, "RouN")

    assert [%{map_server: "RouCos02", map_client: "RouCos02", x: 17_418, y: 13_832, direct: 80, party: 1}] =
             GameData.lookup(GameData.LinkTable, :argument, "GateRou1")

    assert {:ok, %{argument: 5}} = GameData.fetch(GameData.ChrCommon, "ShoutLevel")
    assert {:ok, %{argument: 2}} = GameData.fetch(GameData.ChrCommon, "ShoutDelay")
    assert [%{id: 0}] = GameData.lookup(GameData.MobInfo, :inx_name, "Slime")
    assert {:ok, %{min_level: 1, group: 0, map_name: "RouN", x: 5874, y: 6530}} = GameData.fetch(GameData.TownPortal, 0)
    assert {:ok, %{chat_block_time: 10, probate_time: 15}} = GameData.fetch(GameData.SpamerPenalty, 1)
    assert {:ok, %{second_rule: 3000, repeat_rule: 3}} = GameData.fetch(GameData.SpamerPenaltyRule, 1)
  end
end
