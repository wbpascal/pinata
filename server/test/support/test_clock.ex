defmodule TestClock do
  @moduledoc """
  A `Clock.Source` the replay harness moves: one integer of microseconds, 0 until `set/1`. `local_time/1` is UTC+1.

  `send_after/3` keeps the timers in an `Agent` (started on the first call, not linked). `set/1` fires every timer
  that is due at the new time, earliest first, moving the clock to each due time, and waits for the receiver after
  each message with `:sys.get_state/2`: a receiver of a timer must be an OTP process, and a dead one is skipped.

  `tick_offset/1` (milliseconds, 0 or more) is added once, to a timer scheduled from outside a running tick (the
  first tick of a train). A timer scheduled while `set/1` is firing a tick gets no offset, so the period stays exact
  and the clock never runs backwards. `reset/0` erases the offset and delivers every pending timer at once without
  waiting, because a map instance that waits for a dropped tick would never tick again.
  """
  @behaviour Clock.Source

  @agent __MODULE__

  @doc "Sets the current time in microseconds and fires the timers that are due."
  @spec set(integer()) :: :ok
  def set(microseconds) do
    case pop_due(microseconds) do
      {:ok, {due, pid, message}} ->
        put_now(max(due, now_us()))
        send(pid, message)
        wait(pid)
        Agent.update(@agent, &%{&1 | firing?: false})
        set(microseconds)

      :none ->
        put_now(microseconds)
    end
  end

  @doc "Sets the offset in milliseconds added to the first tick of a train."
  @spec tick_offset(non_neg_integer()) :: :ok
  def tick_offset(ms) when is_integer(ms) and ms >= 0, do: :persistent_term.put({__MODULE__, :tick_offset}, ms)

  @doc "Erases the offset and delivers all pending timers at once."
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase({__MODULE__, :tick_offset})

    if Process.whereis(@agent) do
      timers = Agent.get_and_update(@agent, &{&1.timers, %{&1 | timers: [], firing?: false}})
      for {_due, pid, message} <- timers, do: send(pid, message)
    end

    :ok
  end

  @impl Clock.Source
  def send_after(pid, message, ms) do
    ensure_agent()
    offset = :persistent_term.get({__MODULE__, :tick_offset}, 0)

    Agent.update(@agent, fn %{timers: timers, firing?: firing?} = state ->
      due = now_us() + (ms + if(firing?, do: 0, else: offset)) * 1000
      %{state | timers: timers ++ [{due, pid, message}]}
    end)
  end

  @impl Clock.Source
  def system_time(unit), do: now(unit)

  @impl Clock.Source
  def monotonic_time(unit), do: now(unit)

  # all captures were recorded at UTC+1
  @impl Clock.Source
  def local_time(seconds), do: :calendar.system_time_to_universal_time(seconds + 3600, :second)

  defp ensure_agent do
    case Agent.start(fn -> %{timers: [], firing?: false} end, name: @agent) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  # the earliest timer with due <= time (the first of equals); firing and waiting happen in the caller
  defp pop_due(time) do
    if Process.whereis(@agent), do: Agent.get_and_update(@agent, &take_due(&1, time)), else: :none
  end

  defp take_due(%{timers: timers} = state, time) do
    case timers |> Enum.filter(&(elem(&1, 0) <= time)) |> Enum.min_by(&elem(&1, 0), fn -> nil end) do
      nil -> {:none, state}
      entry -> {{:ok, entry}, %{state | timers: List.delete(timers, entry), firing?: true}}
    end
  end

  defp wait(pid) do
    :sys.get_state(pid, 5_000)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp put_now(microseconds), do: :persistent_term.put({__MODULE__, :now}, microseconds)
  defp now_us, do: :persistent_term.get({__MODULE__, :now}, 0)
  defp now(unit), do: System.convert_time_unit(now_us(), :microsecond, unit)
end
