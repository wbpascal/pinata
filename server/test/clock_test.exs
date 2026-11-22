defmodule ClockTest do
  use ExUnit.Case, async: false

  defmodule Fixed do
    @behaviour Clock.Source

    @impl Clock.Source
    def system_time(_unit), do: 42

    @impl Clock.Source
    def monotonic_time(_unit), do: 7

    @impl Clock.Source
    def send_after(_pid, _message, _ms), do: :ok

    @impl Clock.Source
    def local_time(_seconds), do: {{2026, 1, 1}, {0, 0, 0}}
  end

  test "reads the system clock by default" do
    assert is_integer(Clock.system_time(:millisecond))
    assert is_integer(Clock.monotonic_time(:millisecond))
    assert {{_, _, _}, {_, _, _}} = Clock.local_time(0)
  end

  test "send_after delivers through the system source" do
    assert Clock.send_after(self(), :tick, 10) == :ok
    assert_receive :tick
  end

  test "reads the injected source" do
    Application.put_env(:pinata, :clock_source, Fixed)
    on_exit(fn -> Application.delete_env(:pinata, :clock_source) end)

    assert Clock.system_time(:millisecond) == 42
    assert Clock.monotonic_time(:millisecond) == 7
    assert Clock.local_time(0) == {{2026, 1, 1}, {0, 0, 0}}
  end
end
