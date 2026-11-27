defmodule Proto.FramingTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Proto.Framing

  test "short and long form" do
    assert {:ok, <<255, _::binary-size(255)>>} = Framing.frame(:binary.copy(<<1>>, 255))
    assert {:ok, <<0, 0, 1, _::binary-size(256)>>} = Framing.frame(:binary.copy(<<1>>, 256))
  end

  test "send limit" do
    assert {:ok, _} = Framing.frame(:binary.copy(<<1>>, 0x1FFD))
    assert {:error, :too_large} = Framing.frame(:binary.copy(<<1>>, 0x1FFE))
  end

  test "incomplete buffers" do
    for buf <- [<<>>, <<0>>, <<0, 5>>, <<3, 1, 2>>, <<0, 5, 0, 1>>], do: assert(Framing.split(buf) == :more)
  end

  test "two frames in one buffer" do
    assert {:ok, <<1, 2>>, rest} = Framing.split(<<2, 1, 2, 1, 9>>)
    assert Framing.split(rest) == {:ok, <<9>>, <<>>}
  end

  property "split never raises" do
    check all buf <- StreamData.binary() do
      assert match?({:ok, _, _}, Framing.split(buf)) or Framing.split(buf) == :more
    end
  end

  property "frame then split" do
    check all body <- StreamData.binary(min_length: 2, max_length: 600), tail <- StreamData.binary() do
      {:ok, f} = Framing.frame(body)
      assert Framing.split(f <> tail) == {:ok, body, tail}
    end
  end
end
