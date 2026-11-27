defmodule Zone.PlacementTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias GameData.BlockData

  @ring1 [{25, 0}, {12, -21}, {-12, -21}, {-25, 0}, {-12, 21}, {12, 21}]
  @ring2 [{0, 42}, {36, 21}, {36, -21}, {0, -42}, {-36, -21}, {-36, 21}]

  # 64 x 64 cells = 400 x 400 units
  defp map(blocked?) do
    bits =
      for cy <- 0..63, byte <- 0..7, into: <<>> do
        <<Enum.sum(for i <- 0..7, blocked?.(byte * 8 + i, cy), do: 1 <<< i)>>
      end

    %BlockData{bytes_per_row: 8, rows: 64, bits: bits}
  end

  defp around(b, offsets) do
    assert {:ok, {x, y}} = Zone.Placement.place(b, {200, 200})
    refute BlockData.blocked?(b, x, y)
    assert {x - 200, y - 200} in offsets
  end

  test "a free point is returned unchanged" do
    assert Zone.Placement.place(map(fn _, _ -> false end), {200, 200}) == {:ok, {200, 200}}
  end

  test "a blocked point gives a point of ring 1" do
    around(map(&(&1 == 32 and &2 == 32)), @ring1)
  end

  test "with ring 1 blocked a point of ring 2" do
    around(map(&(&1 in 27..37 and &2 in 27..37)), @ring2)
  end

  test "a point outside the field and a fully blocked map are :error" do
    b = map(fn _, _ -> false end)
    for p <- [{-1, 0}, {401, 0}, {0, 401}], do: assert(Zone.Placement.place(b, p) == :error)
    assert Zone.Placement.place(map(fn _, _ -> true end), {200, 200}) == :error
  end

  test "the same seed gives the same point" do
    b = map(&(&1 == 32 and &2 == 32))
    Random.seed(1)
    first = Zone.Placement.place(b, {200, 200})
    Random.seed(1)
    assert Zone.Placement.place(b, {200, 200}) == first
  end
end
