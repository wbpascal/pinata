defmodule ClockTest do
  use ExUnit.Case, async: false

  defmodule Fixed do
    @behaviour Clock.Source

    @impl Clock.Source
    def system_time(_unit), do: 42

    @impl Clock.Source
    def monotonic_time(_unit), do: 7
  end

  test "reads the system clock by default" do
    assert is_integer(Clock.system_time(:millisecond))
    assert is_integer(Clock.monotonic_time(:millisecond))
  end

  test "reads the injected source" do
    Application.put_env(:fiesta, :clock_source, Fixed)
    on_exit(fn -> Application.delete_env(:fiesta, :clock_source) end)

    assert Clock.system_time(:millisecond) == 42
    assert Clock.monotonic_time(:millisecond) == 7
  end
end
