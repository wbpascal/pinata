defmodule GameData.ImportTxtTest do
  use ExUnit.Case, async: true

  alias GameData.Import.Txt

  @file_one """
  ; a comment line
  #ignore\t\\o042
  #exchange\t#\t\\x20
  #table\tFirst\t; trailing comment
  #columntype\tIndex\tString[8]\tDwrd
  #columnname\tName\tText\tNum
  #record\t"A"\t"te#st"\t 12 
  #record\tB\tx\t-5
  #record\tC\ty\t0x10
  #table\tSecond
  #columntype\tByte
  #columnname\tV
  #recordin\tFirst\tD\tz\t7
  #recordin\tSecond\t3
  #end
  garbage here
  """

  test "reads two tables" do
    assert {:ok, [first, second], []} = Txt.parse(@file_one)

    assert first == %{
             name: "First",
             header: ["Name", "Text", "Num"],
             rows: [["A", "te st", "12"], ["B", "x", "-5"], ["C", "y", "16"], ["D", "z", "7"]]
           }

    assert second == %{name: "Second", header: ["V"], rows: [["3"]]}
  end

  test "a delimiter changes the tokens" do
    text = "#delimiter\t\\x20\n#table T\n#columntype index string[3]\n#columnname A B\n#record  a   b\n"
    assert {:ok, [%{rows: [["a", "b"]]}], []} = Txt.parse(text)
  end

  test "errors carry line numbers" do
    text =
      "#table\tT\n#columntype\tindex\tdwrd\n#columnname\tA\tB\n#record\tx\n#recordin\tNope\t1\t2\n#record\tx\tabc\n#columntype\tfoo\n"

    assert {:error, errors} = Txt.parse(text)
    assert "line 4: expected 2 values, got 1" in errors
    assert "line 5: #recordin: unknown table Nope" in errors
    assert Enum.any?(errors, &(&1 =~ ~r/^line 6: column "B": not a number/))
    assert "line 7: bad column type in #columntype" in errors
  end

  test "a table name that is not a plain file name is refused" do
    assert {:error, errors} = Txt.parse("#table\t../x\n#columntype\tindex\n")
    assert "line 1: invalid table name \"../x\"" in errors
  end

  test "#table without a name is reported as such" do
    assert {:error, errors} = Txt.parse("#table\n")
    assert "line 1: #table needs a name" in errors
  end

  test "an explicit T.2 is not overwritten by a later second T" do
    text =
      "#table\tT\n#columntype\tindex\n#columnname\ta\n#table\tT.2\n#columntype\tindex\n#columnname\ta\n#table\tT\n#columntype\tindex\n#columnname\ta\n"

    assert {:ok, tables, _warnings} = Txt.parse(text)
    assert Enum.map(tables, & &1.name) == ["T", "T.2", "T.3"]
  end

  test "warnings: a table declared twice and a real extra value" do
    text =
      "#table\tT\n#columntype\tindex\n#columnname\tA\n#record\ta\t  \n#record\tb\textra\n#table\tT\n#columntype\tindex\n#columnname\tA\n"

    assert {:ok, [%{name: "T"}, %{name: "T.2"}], warnings} = Txt.parse(text)
    assert Enum.any?(warnings, &(&1 =~ "line 6" and &1 =~ "T.2"))
    assert Enum.any?(warnings, &(&1 =~ "line 5"))
    refute Enum.any?(warnings, &(&1 =~ "line 4"))
  end

  test "table_file?" do
    assert Txt.table_file?("  #TABLE x\n")
    refute Txt.table_file?("Fighter 1\r\n")
  end
end
