defmodule GameData.ImportTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @source Path.expand("../../../Files/Server/2016/9Data/Shine", __DIR__)
  @dir System.fetch_env!("PINATA_TEST_DATA_DIR")

  defp path(rel), do: Path.join(@dir, rel)
  defp wildcard(pattern), do: pattern |> path() |> Path.wildcard()

  test "SHN tables are copied unchanged" do
    assert File.read!(path("shn/ItemInfo.shn")) == File.read!(Path.join(@source, "ItemInfo.shn"))
    assert File.exists?(path("shn/View/ItemViewInfo.shn"))
  end

  test "TXT tables become CSV" do
    assert File.read!(path("tables/World/ChrCommon/Common.csv")) =~ ~r/\Akey,argument\nRunSpeed,127\n/

    assert File.read!(path("tables/MobRegen/RouN/MobRegenGroup.csv")) =~
             "GroupIndex,IsFamily,CenterX,CenterY,Width,Height,RangeDegree\n"

    assert File.exists?(path("tables/MobRegen/RouN/MobRegen.csv"))
    assert length(wildcard("tables/MobRoam/*.csv")) == 28
    assert File.exists?(path("tables/NPCItemList/HednisSkillGrunt/Tab08.2.csv"))
    assert File.exists?(path("tables/World/QuestParser.txt"))
  end

  test "character default scripts become CSV" do
    assert File.read!(path("tables/DefaultCharacterData/CHARACTER.csv")) =~
             "Class,StartMap,StartX,StartY,HP,SP,HPStone,SPStone,Money,InitLV,InitEXP\n1,RouN,6888,7045,52,10,15,7,0,1,0\n"

    assert File.exists?(path("tables/TutorialCharacterData/TUTORIAL_CHARACTER.csv"))
    assert File.exists?(path("tables/DefaultCharacterData/MAXSHAPE.csv"))
  end

  test "scripts and geometry are kept, dead files are left out" do
    assert length(wildcard("BlockInfo/*.shbd")) == 158
    assert wildcard("LuaScript/*") != []
    assert wildcard("ScenarioBookShelf/*") != []
    assert length(wildcard("Script/**/*.txt")) == 51

    for dir <- ~w(AbState AIScript MobBehaviorDescript ServerInfo), do: refute(File.exists?(path(dir)))
    assert wildcard("**/*.{bdt,shmd,shad,xls,db}") == []
    assert wildcard("tables/World/ExpRecalculation*") == []
  end

  test "every CSV decodes with as many cells as its header" do
    for file <- wildcard("tables/**/*.csv") do
      assert {:ok, header, rows} = file |> File.read!() |> GameData.Csv.decode()
      assert Enum.all?(rows, &(length(&1) == length(header))), file
    end
  end

  test "a target that is not empty is refused and left alone", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "keep"), "x")
    assert {:error, [message]} = GameData.Import.run(Path.dirname(@source), tmp_dir)
    assert message =~ "not empty"
    assert File.ls!(tmp_dir) == ["keep"]
  end

  test "a source without a Shine folder is refused", %{tmp_dir: tmp_dir} do
    assert {:error, _problems} = GameData.Import.run(tmp_dir, Path.join(tmp_dir, "out"))
  end

  test "symlinks and unreadable files in the source", %{tmp_dir: tmp_dir} do
    shine = Path.join([tmp_dir, "src", "Shine"])
    File.mkdir_p!(Path.join(shine, "World"))
    File.write!(Path.join(tmp_dir, "secret.shn"), "secret")
    File.ln_s!(Path.join(tmp_dir, "secret.shn"), Path.join(shine, "Link.shn"))
    out = Path.join(tmp_dir, "out")

    assert {:ok, %{copied: 0}} = GameData.Import.run(Path.join(tmp_dir, "src"), out)
    refute File.exists?(Path.join(out, "shn/Link.shn"))

    File.write!(Path.join(shine, "World/Bad.txt"), "#table\tT\n")
    File.chmod!(Path.join(shine, "World/Bad.txt"), 0)
    File.rm_rf!(out)
    assert {:error, [message]} = GameData.Import.run(Path.join(tmp_dir, "src"), out)
    assert message =~ "World/Bad.txt: cannot read"
  end
end
