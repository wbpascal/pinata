defmodule Zone.GridTest do
  use ExUnit.Case, async: true

  alias Zone.Grid

  defp grid(entries, cell \\ 100), do: Enum.reduce(entries, Grid.new(cell), fn {h, p}, g -> Grid.put(g, h, p) end)

  defp brute(entries, {x, y} = centre, r, from) do
    entries
    |> Enum.filter(fn {h, {ex, ey}} -> h != from and (ex - x) * (ex - x) + (ey - y) * (ey - y) < r * r end)
    |> Grid.walk_order(centre, from)
  end

  test "put, delete and query across cell borders; from is left out; dist² < r² is strict" do
    entries = [{1, {99, 99}}, {2, {100, 100}}, {3, {150, 100}}, {4, {200, 100}}, {5, {0, 0}}]
    g = grid(entries)
    assert Enum.sort(Grid.query(g, {100, 100}, 100, 2)) == [1, 3]
    assert Enum.sort(Grid.query(g, {100, 100}, 101, 9)) == [1, 2, 3, 4]
    assert Grid.query(g, {0, 0}, 1, 5) == []
    g = Grid.delete(g, 1, {99, 99})
    assert Enum.sort(Grid.query(g, {100, 100}, 100, 2)) == [3]
    assert Grid.delete(g, 1, {99, 99}) == g
    # a cell that gets empty is dropped
    assert Map.has_key?(g.cells, {2, 1})
    refute Map.has_key?(Grid.delete(g, 4, {200, 100}).cells, {2, 1})
  end

  test "a radius larger than the cell reads more cells" do
    g = grid([{1, {0, 0}}, {2, {450, 0}}, {3, {0, 499}}])
    assert Grid.query(g, {0, 0}, 500, 9) == [2, 1, 3]
    assert Grid.query(g, {0, 0}, 451, 9) == [2, 1]
  end

  test "walk order: below the centre descending, then above ascending, equal y by descending handle" do
    entries = [{1, {0, 90}}, {2, {0, 50}}, {3, {0, 110}}, {4, {0, 100}}, {9, {0, 100}}]
    assert Grid.walk_order(entries, {0, 100}, 5) == [9, 1, 2, 4, 3]
    # the capture order of the three NPCs at y 7862 of RouVal01, seen from y 7812
    entries = [{17_225, {0, 7862}}, {17_226, {0, 7862}}, {17_289, {0, 7862}}]
    assert Grid.walk_order(entries, {0, 7812}, 8000) == [17_289, 17_226, 17_225]
  end

  test "1500 players over one map: every query equals brute force, mean time bounded" do
    entries = for i <- 0..1499, do: {8000 + i, {rem(i * 7919, 20_000), rem(i * 104_729, 20_000)}}
    g = grid(entries, 1600)

    for {h, p} <- entries, do: assert(Grid.query(g, p, 1600, h) == brute(entries, p, 1600, h))

    {micros, _} = :timer.tc(fn -> for {h, p} <- entries, do: Grid.query(g, p, 1600, h) end)
    mean = micros / 1500
    if System.get_env("PINATA_BENCH"), do: IO.puts("range query, 1500 players: #{Float.round(mean, 1)} µs")
    assert mean < 1000
  end
end
