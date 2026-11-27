defmodule Zone.MoverTest do
  use ExUnit.Case, async: true

  alias Zone.Mover

  test "distance: rounded root, halved above 1024" do
    assert Mover.distance(8, 119) == 119
    assert Mover.distance(-1, 14) == 14
    assert Mover.distance(2, -250) == 250
    # 3000, 4000 halve twice to 750, 1000: 1250 * 4
    assert Mover.distance(3000, 4000) == 5000
    # 2049 halves to 1024 (div), 1 to 0: 1024 * 2
    assert Mover.distance(2049, 1) == 2048
  end

  test "direction: the three captured points of scenario 45 and the axes" do
    assert Mover.direction(1, 72) == 0
    assert Mover.direction(7, 121) == 2
    assert Mover.direction(-62, 79) == 161
    assert Mover.direction(0, -1) == 90
    assert Mover.direction(1, 0) == 45
    assert Mover.direction(-1, 0) == 135
  end

  test "the captured run of scenario 45 (file lines 1737 and 1739)" do
    m = Mover.start({6389, 9287}, {6381, 9168}, 127, 1000)
    assert m.duration == 937
    assert {378, {6386, 9239}} = List.last(Mover.slices(m, 1378))
  end

  test "slices of at most 100 ms, the goal exactly at the duration, done?" do
    m = Mover.start({0, 0}, {1270, 0}, 127, 0)
    assert m.duration == 10_000
    assert Mover.slices(m, 250) == [{100, {12, 0}}, {200, {25, 0}}, {250, {31, 0}}]
    assert Mover.slices(%{m | applied: 250}, 300) == [{300, {38, 0}}]
    # no time passed: one slice at the applied point
    assert Mover.slices(m, 0) == [{0, {0, 0}}]
    refute Mover.done?(m)

    # the elapsed time reaches the duration: every slice of that call is the goal
    late = %{m | applied: 9850}
    assert Mover.slices(late, 20_000) == [{9950, {1270, 0}}, {10_000, {1270, 0}}]
    assert Mover.done?(%{m | applied: 10_000})
  end

  test "a move towards smaller coordinates and a zero-length move" do
    m = Mover.start({1000, 1000}, {900, 1100}, 33, 0)
    assert [{100, {998, 1002}} | _] = Mover.slices(m, 100)
    assert %Mover{duration: 1} = Mover.start({5, 5}, {5, 5}, 33, 0)
  end
end
