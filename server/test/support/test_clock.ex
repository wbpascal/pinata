defmodule TestClock do
  @moduledoc "A `Clock.Source` the replay harness moves: one integer of microseconds, 0 until `set/1`. `local_time/1` is UTC+1."
  @behaviour Clock.Source

  @doc "Sets the current time in microseconds."
  @spec set(integer()) :: :ok
  def set(microseconds), do: :persistent_term.put({__MODULE__, :now}, microseconds)

  @impl Clock.Source
  def system_time(unit), do: now(unit)

  @impl Clock.Source
  def monotonic_time(unit), do: now(unit)

  # all captures were recorded at UTC+1
  @impl Clock.Source
  def local_time(seconds), do: :calendar.system_time_to_universal_time(seconds + 3600, :second)

  defp now(unit), do: System.convert_time_unit(:persistent_term.get({__MODULE__, :now}, 0), :microsecond, unit)
end
