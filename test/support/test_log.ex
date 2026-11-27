defmodule TestLog do
  @moduledoc """
  Captures the server log at level `:debug`. The test VM logs at `:warning` (the test settings), so a test that
  asserts on `info` or `debug` lines raises the level only for the captured function; sockets that close after the
  test stay quiet. See `docs/technical/testing.md`.
  """

  @spec capture((-> term())) :: String.t()
  def capture(fun) do
    Logger.configure(level: :debug)

    try do
      ExUnit.CaptureLog.capture_log(fun)
    after
      Logger.configure(level: :warning)
    end
  end
end
