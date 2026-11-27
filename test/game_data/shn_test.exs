defmodule GameData.ShnTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, bin: File.read!(Path.join(System.fetch_env!("PINATA_TEST_DATA_DIR"), "shn/SingleData.shn"))}
  end

  test "decodes columns and rows of an enciphered table", %{bin: bin} do
    assert {:ok, columns, rows} = GameData.Shn.decode(bin)

    assert [%{name: "SingleDataIDX", type: 9, size: 32}, %{name: "SingleDataValue", type: 2, size: 2}] =
             Enum.map(columns, &Map.take(&1, [:name, :type, :size]))

    assert hd(rows) == ["KQVote_VoteLimitTime", 60]
    assert ["ChrLevel_CanCreateSen", 60] in rows
  end

  test "short and cut files are errors, not crashes", %{bin: bin} do
    assert {:error, _message} = GameData.Shn.decode(<<0, 1, 2, 3, 4, 5, 6, 7, 8, 9>>)
    assert {:error, "truncated SHN file"} = GameData.Shn.decode(binary_part(bin, 0, div(byte_size(bin), 2)))
  end
end
