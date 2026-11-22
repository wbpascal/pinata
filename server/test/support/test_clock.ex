defmodule TestClock do
  @moduledoc """
  A `Clock.Source` the replay harness moves: one integer of microseconds, 0 until `set/1`. `local_time/1` is UTC+1.

  Timers (`Clock.send_after/3`) fire inside `set/1`, in due order, each one handled before the next.
  """
  @behaviour Clock.Source

  @doc "Sets the current time in microseconds and fires the timers that fall due."
  @spec set(integer()) :: :ok
  def set(target) do
    if Process.whereis(TestClock.Timers), do: fire(target), else: put_now(target)
  end

  @impl Clock.Source
  def system_time(unit), do: now(unit)

  @impl Clock.Source
  def monotonic_time(unit), do: now(unit)

  # all captures were recorded at UTC+1
  @impl Clock.Source
  def local_time(seconds), do: :calendar.system_time_to_universal_time(seconds + 3600, :second)

  @impl Clock.Source
  def send_after(pid, message, ms) do
    agent = timers()
    due = now(:microsecond) + ms * 1000
    Agent.update(agent, &[{due, System.unique_integer([:monotonic]), pid, message} | &1])
  end

  defp fire(target) do
    case Agent.get_and_update(TestClock.Timers, &pop_due(&1, target)) do
      {due, pid, message} ->
        put_now(max(due, now(:microsecond)))
        send(pid, message)

        try do
          _ = :sys.get_state(pid)
        catch
          :exit, _ -> :ok
        end

        fire(target)

      :none ->
        put_now(target)
    end
  end

  defp pop_due(list, target) do
    case Enum.min(list, fn -> nil end) do
      {due, _seq, pid, message} = timer when due <= target -> {{due, pid, message}, List.delete(list, timer)}
      _none -> {:none, list}
    end
  end

  defp timers do
    case Agent.start(fn -> [] end, name: TestClock.Timers) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  # shortcut: one persistent_term write per fired timer, move the time into :atomics when a long replay is slow
  defp put_now(microseconds), do: :persistent_term.put({__MODULE__, :now}, microseconds)

  defp now(unit), do: System.convert_time_unit(:persistent_term.get({__MODULE__, :now}, 0), :microsecond, unit)
end
