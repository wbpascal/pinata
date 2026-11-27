defmodule Zone.GmCommandTest do
  use ExUnit.Case, async: true

  alias Zone.GmCommand

  describe "parse/1" do
    test "splits on spaces and drops empty tokens" do
      assert GmCommand.parse("&linkto  RouN   10 20 ") == {"&linkto", ["RouN", "10", "20"]}
      assert GmCommand.parse("&hide") == {"&hide", []}
    end

    test "quotes join spaces and are dropped; an unclosed quote runs to the end" do
      assert GmCommand.parse(~s(&kickout "a b" c"d e")) == {"&kickout", ["a b", "cd e"]}
      assert GmCommand.parse(~s(&kickout "a b c)) == {"&kickout", ["a b c"]}
      assert GmCommand.parse(~s(&kickout "" x)) == {"&kickout", ["x"]}
    end

    test "a backslash takes the next byte literally; a trailing one is dropped" do
      # the line: &kickout a\ b \"c\\ d\
      assert GmCommand.parse("&kickout a\\ b \\\"c\\\\ d\\") == {"&kickout", ["a b", "\"c\\", "d"]}
    end

    test "only the first 100 bytes count" do
      line = "&kickout " <> String.duplicate("a ", 45) <> "bcdefghij"
      assert byte_size(line) > 100
      {_word, args} = GmCommand.parse(line)
      # 9 + 90 bytes of "a " leave one byte of the last token
      assert List.last(args) == "a"
      # bytes 99 and 100 are "cd", the "e" is cut
      assert GmCommand.parse("&x" <> String.duplicate(" ", 96) <> "cde") == {"&x", ["cd"]}
    end

    test "at most 12 arguments, each cut at 32 bytes; the word cut at 20 bytes" do
      {"&a", args} = GmCommand.parse("&a " <> Enum.map_join(1..14, " ", &Integer.to_string/1))
      assert args == Enum.map(1..12, &Integer.to_string/1)

      {_word, [arg]} = GmCommand.parse("&a " <> String.duplicate("x", 40))
      assert arg == String.duplicate("x", 32)

      {word, []} = GmCommand.parse("&" <> String.duplicate("w", 30))
      assert word == "&" <> String.duplicate("w", 19)
    end
  end

  describe "lookup/2" do
    test "the level borders of each command" do
      for {word, level, handler} <- [
            {"&hide", 10, :hide},
            {"&show", 10, :show},
            {"&linkto", 10, :linkto},
            {"&kickout", 10, :kickout},
            {"&adminlevel", 1, :adminlevel},
            {"&dimension", 100, :dimension}
          ] do
        assert GmCommand.lookup(word, level) == {:ok, handler}
        assert GmCommand.lookup(word, 255) == {:ok, handler}
        assert GmCommand.lookup(word, level - 1) == :denied
      end
    end

    test "the Korean aliases (CP949)" do
      assert GmCommand.lookup(<<"&", 0xBC, 0xFB, 0xBE, 0xEE>>, 10) == {:ok, :hide}
      assert GmCommand.lookup(<<"&", 0xBA, 0xB8, 0xBF, 0xA9>>, 10) == {:ok, :show}
      assert GmCommand.lookup(<<"&", 0xC3, 0xDF, 0xB9, 0xE6>>, 10) == {:ok, :kickout}
      assert GmCommand.lookup(<<"&", 0xC0, 0xCC, 0xB5, 0xBF>>, 10) == {:ok, :linkto}
    end

    test "words are case-sensitive; an unknown word is unknown" do
      assert GmCommand.lookup("&Hide", 100) == :unknown
      assert GmCommand.lookup("&dimensio", 100) == :unknown
    end
  end

  test "number/1 reads as sscanf %d" do
    assert GmCommand.number("12") == 12
    assert GmCommand.number("  -5") == -5
    assert GmCommand.number("+7") == 7
    assert GmCommand.number("12x") == 12
    assert GmCommand.number("x12") == 0
    assert GmCommand.number("") == 0
    assert GmCommand.number("-") == 0
    assert GmCommand.number("--5") == 0
    assert GmCommand.number("99999999999") == 2_147_483_647
    assert GmCommand.number("-99999999999") == -2_147_483_648
  end
end
