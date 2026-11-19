defmodule Login.WorldStatusTest do
  use ExUnit.Case, async: true

  test "not registered" do
    assert Login.WorldStatus.status(false, 0) == 0
    assert Login.WorldStatus.status(false, 3000) == 0
  end

  test "band edges" do
    for {count, status} <- [
          {0, 6},
          {124, 6},
          {125, 7},
          {199, 7},
          {200, 8},
          {249, 8},
          {250, 9},
          {749, 9},
          {750, 10},
          {2374, 10},
          {2375, 5},
          {2500, 5}
        ] do
      assert Login.WorldStatus.status(true, count) == status, "count #{count}"
    end
  end
end
