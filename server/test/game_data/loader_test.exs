defmodule GameData.LoaderTest do
  use ExUnit.Case, async: true

  alias GameData.Loader

  @moduletag :tmp_dir

  defmodule Mob do
    @behaviour GameData.Schema
    defstruct [:id, :name]

    @impl GameData.Schema
    def __schema__ do
      %{
        source: {:csv, "tables/t/mob.csv"},
        key: :id,
        columns: [id: {"ID", :integer}, name: {"Name", :string}],
        indexes: [],
        references: []
      }
    end
  end

  defmodule Drop do
    @behaviour GameData.Schema
    defstruct [:mob, :rate]

    @impl GameData.Schema
    def __schema__ do
      %{
        source: {:csv, "tables/t/drop.csv"},
        key: :row,
        columns: [mob: {"Mob", :integer}, rate: {"Rate", :integer}],
        indexes: [:mob],
        references: [mob: Mob]
      }
    end
  end

  defmodule Single do
    @behaviour GameData.Schema
    defstruct [:value, :nope]

    @impl GameData.Schema
    def __schema__ do
      %{
        source: {:shn, "shn/SingleData.shn"},
        key: :value,
        columns: [value: {"SingleDataValue", :string}, nope: {"Nope", :integer}],
        indexes: [],
        references: []
      }
    end
  end

  defp write(dir, name, text) do
    path = Path.join([dir, "tables/t", name])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
  end

  defp valid(dir) do
    write(dir, "mob.csv", "ID,Name,Extra\n1,Rat,x\n2,Bat,y\n")
    write(dir, "drop.csv", "Mob,Rate\n1,10\n1,20\n2,5\n")
  end

  test "valid files load, a reference pulls in its target", %{tmp_dir: dir} do
    valid(dir)
    assert {:ok, tables, []} = Loader.parse(dir, [Mob, Drop], true)
    assert %{rows: %{1 => %Mob{name: "Rat"}}} = tables[Mob]
    assert [%Drop{rate: 10}, %Drop{rate: 20}] = tables[Drop].indexes.mob[1]
    assert {:ok, %{Mob => _, Drop => _}, []} = Loader.parse(dir, [Drop], true)
  end

  test "a file whose name differs in letter case is found", %{tmp_dir: dir} do
    write(dir, "MOB.CSV", "ID,Name,Extra\n1,Rat,x\n2,Bat,y\n")
    assert {:ok, %{Mob => %{rows: rows}}, []} = Loader.parse(dir, [Mob], true)
    assert map_size(rows) == 2
  end

  test "a missing column", %{tmp_dir: dir} do
    valid(dir)
    write(dir, "mob.csv", "ID\n1\n")
    assert {:error, [message]} = Loader.parse(dir, [Mob], true)
    assert message =~ "tables/t/mob.csv" and message =~ "\"Name\""
  end

  test "a wrong type", %{tmp_dir: dir} do
    valid(dir)
    write(dir, "drop.csv", "Mob,Rate\n1,10\n1,abc\n")
    assert {:error, [message]} = Loader.parse(dir, [Drop], true)
    assert message == ~s|tables/t/drop.csv row 2: column "Rate": expected an integer, got "abc"|
  end

  test "a duplicate key", %{tmp_dir: dir} do
    valid(dir)
    write(dir, "mob.csv", "ID,Name\n1,Rat\n1,Bat\n")
    assert {:error, ["tables/t/mob.csv row 2: duplicate key 1"]} = Loader.parse(dir, [Mob], true)
  end

  test "a missing file", %{tmp_dir: dir} do
    assert {:error, ["tables/t/mob.csv: file not found"]} = Loader.parse(dir, [Mob], true)
  end

  test "problems of two tables come back together", %{tmp_dir: dir} do
    write(dir, "mob.csv", "ID\n1\n")
    write(dir, "drop.csv", "Mob,Rate\n1,abc\n")
    assert {:error, [one, two]} = Loader.parse(dir, [Mob, Drop], true)
    assert one =~ "mob.csv" and two =~ "drop.csv"
  end

  test "a dangling reference is an error when strict", %{tmp_dir: dir} do
    valid(dir)
    write(dir, "drop.csv", "Mob,Rate\n1,10\n7,5\n")

    assert {:error, [message]} = Loader.parse(dir, [Drop], true)
    assert message == ~s|tables/t/drop.csv row key 2: column "Mob" refers to 7, which is not in tables/t/mob.csv|
  end

  test "a dangling reference is a warning when lenient", %{tmp_dir: dir} do
    valid(dir)
    write(dir, "drop.csv", "Mob,Rate\n1,10\n7,5\n")

    assert {:ok, tables, [warning]} = Loader.parse(dir, [Drop], false)
    assert warning =~ "tables/t/drop.csv row key 2" and warning =~ "\"Mob\"" and warning =~ "7"
    assert map_size(tables[Drop].rows) == 2
  end

  test "an SHN column of the wrong type and a missing one are both reported" do
    dir = System.fetch_env!("PINATA_TEST_DATA_DIR")
    assert {:error, [one, two]} = Loader.parse(dir, [Single], true)
    assert one =~ "SingleDataValue" and one =~ "expected a string"
    assert two =~ "\"Nope\" is missing"
  end
end
