defmodule GameData.CsvTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias GameData.Csv

  test "decodes quotes, CRLF and raw bytes" do
    text = "a,b\r\n\"x,y\",\"say \"\"hi\"\"\"\r\n\"line\nbreak\",\xE9\n"
    assert {:ok, ["a", "b"], [["x,y", "say \"hi\""], ["line\nbreak", <<0xE9>>]]} = Csv.decode(text)
  end

  test "a missing final newline is fine" do
    assert {:ok, ["a"], [["1"]]} = Csv.decode("a\n1")
  end

  test "an empty file and an unterminated quote are errors" do
    assert {:error, "empty file"} = Csv.decode("")
    assert {:error, _message} = Csv.decode("a\n\"b")
  end

  test "encode then decode returns the cells" do
    header = ["a", "b,c"]
    rows = [["x\"y", "line\r\nbreak"], [<<0xE9>>, ""]]
    assert {:ok, ^header, ^rows} = header |> Csv.encode(rows) |> IO.iodata_to_binary() |> Csv.decode()
  end

  property "encode then decode is the identity" do
    check all(cells <- list_of(binary(), min_length: 1, max_length: 5), rows <- list_of(constant(cells), max_length: 3)) do
      assert {:ok, ^cells, ^rows} = cells |> Csv.encode(rows) |> IO.iodata_to_binary() |> Csv.decode()
    end
  end
end
