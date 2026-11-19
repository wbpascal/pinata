defmodule Clock.System do
  @moduledoc "The default `Clock` source: the system clock."

  @behaviour Clock.Source

  @impl Clock.Source
  def system_time(unit), do: System.system_time(unit)

  @impl Clock.Source
  def monotonic_time(unit), do: System.monotonic_time(unit)

  @impl Clock.Source
  def local_time(seconds), do: :calendar.system_time_to_local_time(seconds, :second)
end
