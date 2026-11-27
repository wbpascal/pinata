defmodule GameData.ImportTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @source Path.expand("../../original-data/9Data/Shine", __DIR__)
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

  test "GameData.Release.import_data/2 raises with the problems", %{tmp_dir: tmp_dir} do
    assert_raise RuntimeError, ~r/Shine/, fn -> GameData.Release.import_data(tmp_dir, Path.join(tmp_dir, "out")) end
  end

  # A Shine folder under `dir`/src with the given files; returns the 9Data folder.
  defp source(dir, files) do
    Enum.each(files, fn {rel, content} ->
      file = Path.join([dir, "src", "Shine", rel])
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, content)
    end)

    Path.join(dir, "src")
  end

  defp tree(dir) do
    dir |> Path.join("**/*") |> Path.wildcard() |> Enum.map(&Path.relative_to(&1, dir)) |> Enum.sort()
  end

  defp windows?, do: match?({:win32, _}, :os.type())

  # On Windows the 9Data path is given with backslashes. Elsewhere a backslash is a character of a file name, so the
  # folder name carries one. To Path.wildcard/2 a backslash is an escape in both cases, as `[` and `{` are syntax.
  test "a source path with backslashes or pattern characters imports the same files", %{tmp_dir: tmp_dir} do
    files = [
      {"ItemInfo.shn", "shn"},
      {"View/ItemViewInfo.shn", "view"},
      {"World/ChrCommon.txt", File.read!(Path.join(@source, "World/ChrCommon.txt"))},
      {"LuaScript/A.lua", "lua"},
      {"AbState/Left.txt", "left out"}
    ]

    plain = source(Path.join(tmp_dir, "plain"), files)
    assert {:ok, expected} = GameData.Import.run(plain, Path.join(tmp_dir, "out-plain"))
    assert %{copied: 3, tables: tables, skipped: ["AbState/Left.txt"]} = expected
    assert tables > 0

    odd = source(Path.join(tmp_dir, if(windows?(), do: "odd [a] {b,c}", else: "odd \\ [a] {b,c}")), files)
    odd = if windows?(), do: String.replace(odd, "/", "\\"), else: odd

    assert {:ok, ^expected} = GameData.Import.run(odd, Path.join(tmp_dir, "out-odd"))
    assert tree(Path.join(tmp_dir, "out-odd")) == tree(Path.join(tmp_dir, "out-plain"))
  end

  test "an import with nothing to write fails and creates nothing", %{tmp_dir: tmp_dir} do
    src = source(tmp_dir, [{"AbState/X.txt", "x"}, {"Thing.xls", "x"}])
    out = Path.join(tmp_dir, "out")

    assert {:error, [message]} = GameData.Import.run(src, out)
    assert message =~ "nothing to import"
    refute File.exists?(out)

    assert_raise RuntimeError, ~r/nothing to import/, fn -> GameData.Release.import_data(src, out) end
    assert_raise Mix.Error, ~r/nothing to import/, fn -> Mix.Tasks.Pinata.ImportData.run([src, out]) end
    refute File.exists?(out)
  end

  # Excluded where this OS user cannot create symlinks (test_helper.exs).
  @tag :symlink
  test "symlinks in the source are not followed", %{tmp_dir: tmp_dir} do
    src = source(tmp_dir, [{"Real.shn", "real"}])
    shine = Path.join(src, "Shine")
    File.write!(Path.join(tmp_dir, "secret.shn"), "secret")
    File.ln_s!(Path.join(tmp_dir, "secret.shn"), Path.join(shine, "Link.shn"))
    out = Path.join(tmp_dir, "out")

    assert {:ok, %{copied: 1}} = GameData.Import.run(src, out)
    assert File.exists?(Path.join(out, "shn/Real.shn"))
    refute File.exists?(Path.join(out, "shn/Link.shn"))

    File.mkdir_p!(Path.join(tmp_dir, "outside"))
    File.write!(Path.join(tmp_dir, "outside/X.shn"), "x")
    File.ln_s!(Path.join(tmp_dir, "outside"), Path.join(shine, "View"))
    File.rm_rf!(out)
    assert {:ok, %{copied: 1}} = GameData.Import.run(src, out)
    refute File.exists?(Path.join(out, "shn/View/X.shn"))
  end

  # Excluded on Windows (test_helper.exs): File.chmod/2 cannot take away the read right there.
  @tag :unix_file_modes
  test "an unreadable file in the source fails the import", %{tmp_dir: tmp_dir} do
    src = source(tmp_dir, [{"Real.shn", "real"}, {"World/Bad.txt", "#table\tT\n"}])
    File.chmod!(Path.join(src, "Shine/World/Bad.txt"), 0)
    out = Path.join(tmp_dir, "out")

    assert {:error, [message]} = GameData.Import.run(src, out)
    assert message =~ "World/Bad.txt: cannot read"
    refute File.exists?(out)
  end
end
