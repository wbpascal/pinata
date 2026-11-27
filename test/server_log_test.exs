defmodule ServerLogTest do
  # Raises the global Logger level while it captures.
  use ExUnit.Case, async: false

  require Logger

  test "a line is `date time [level] Part: message` in UTC" do
    assert Application.fetch_env!(:logger, :utc_log) == true

    # The handler that prints to the console, not the capture formatter.
    {:ok, %{formatter: {Logger.Formatter, f}}} = :logger.get_handler_config(:default)
    assert f.utc_log?

    log = TestLog.capture(fn -> Logger.info("Test: line") end)

    assert log =~ ~r/^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3} \[info\] \w+: /
    [date, time | _] = String.split(log, " ")
    stamp = NaiveDateTime.from_iso8601!(date <> " " <> time)
    now = Clock.system_time(:second) |> DateTime.from_unix!() |> DateTime.to_naive()
    assert abs(NaiveDateTime.diff(now, stamp)) <= 5
  end
end
