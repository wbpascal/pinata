defmodule GameData.DataFileTest do
  use ExUnit.Case, async: true

  alias GameData.DataFile

  @moduletag :tmp_dir

  test "letter case is ignored", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "BlockInfo"))
    File.write!(Path.join(dir, "BlockInfo/wedding.shbd"), "x")
    assert DataFile.path(dir, "BlockInfo/Wedding.shbd") == Path.join(dir, "BlockInfo/wedding.shbd")
  end

  test "a folder in another case", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "blockinfo"))
    File.write!(Path.join(dir, "blockinfo/wedding.shbd"), "x")
    assert DataFile.path(dir, "BlockInfo/Wedding.shbd") |> String.ends_with?("blockinfo/wedding.shbd")
  end

  test "no match and exact match", %{tmp_dir: dir} do
    assert DataFile.path(dir, "a/B.txt") == Path.join(dir, "a/B.txt")
    File.write!(Path.join(dir, "B.txt"), "x")
    assert DataFile.path(dir, "B.txt") == Path.join(dir, "B.txt")
  end
end
