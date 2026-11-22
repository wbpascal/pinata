defmodule Clock do
  @moduledoc "The only way server code reads time (ADR 0008). The source is the module in `config :pinata, :clock_source`, `Clock.System` by default."

  use Boundary, exports: [Source]

  @spec system_time(System.time_unit()) :: integer()
  def system_time(unit), do: source().system_time(unit)

  @spec monotonic_time(System.time_unit()) :: integer()
  def monotonic_time(unit), do: source().monotonic_time(unit)

  @doc "Local wall-clock time of a Unix time in seconds; the system source uses the time zone of the operating system."
  @spec local_time(integer()) :: :calendar.datetime()
  def local_time(seconds), do: source().local_time(seconds)

  @doc """
  Sends `message` to `pid` after `milliseconds`. Only the tick of a map instance is scheduled this way, so the test
  clock can fire it at a captured time; heartbeat, game time and auto-save stay real timers (ADR 0008).
  """
  @spec send_after(pid(), term(), non_neg_integer()) :: :ok
  def send_after(pid, message, milliseconds), do: source().send_after(pid, message, milliseconds)

  @spec source() :: module()
  defp source, do: Application.get_env(:pinata, :clock_source, Clock.System)
end
