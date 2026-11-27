defmodule GameData.ImportCslTest do
  use ExUnit.Case, async: true

  alias GameData.Import.Csl

  @script """
  #DEFINE CHARACTER
  <INTEGER> ; Class
  <STRING>
  <INTEGER>
  <INTEGER>
  <INTEGER>
  <INTEGER>
  <INTEGER>
  <INTEGER>
  <INTEGER>
  <INTEGER>
  <STRING>
  #ENDDEFINE
  #DEFINE ITEM
  <INTEGER>
  <INTEGER>
  <INTEGER>
  #ENDDEFINE
  ;CHARACTER 2, "X", 1, 1, 1, 1, 1, 1, 1, 1, "1"
  	CHARACTER 1, "RouN", 6888, 7045, 52, 10, 15, 7, 0 1 "0",
  ITEM 1, 46003, 1
  ITEM 1 46004 2
  #END
  ITEM garbage
  """

  test "reads rows with the odd separators of the original" do
    assert {:ok, [character, item]} = Csl.parse(@script)
    assert character.name == "CHARACTER"
    assert character.rows == [~w(1 RouN 6888 7045 52 10 15 7 0 1 0)]
    assert item.rows == [~w(1 46003 1), ~w(1 46004 2)]
  end

  test "errors" do
    assert {:error, [message]} = Csl.parse("#DEFINE ITEM\n<INTEGER>\n<INTEGER>\n<INTEGER>\n#ENDDEFINE\nITEM 1 2\n")
    assert message =~ "line 6"
    assert {:error, [message]} = Csl.parse("#DEFINE ITEM\n<INTEGER>\n<INTEGER>\n<INTEGER>\n#ENDDEFINE\nNOPE 1 2 3\n")
    assert message =~ "line 6"
    assert {:error, ["line 1: no column names known for #DEFINE X"]} = Csl.parse("#DEFINE X\n#ENDDEFINE\n")
  end
end
