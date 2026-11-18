defmodule Clock do
  @moduledoc "The only way server code reads time (ADR 0008). The source is the module in `config :fiesta, :clock_source`, `Clock.System` by default."

  use Boundary, exports: [Source]

  @spec system_time(System.time_unit()) :: integer()
  def system_time(unit), do: source().system_time(unit)

  @spec monotonic_time(System.time_unit()) :: integer()
  def monotonic_time(unit), do: source().monotonic_time(unit)

  @spec source() :: module()
  defp source, do: Application.get_env(:fiesta, :clock_source, Clock.System)
end
