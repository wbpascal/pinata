defmodule Probe.TimeAndRandom do
  @moduledoc false

  @spec now() :: integer()
  def now, do: System.system_time(:millisecond)

  @spec roll() :: pos_integer()
  def roll, do: :rand.uniform(6)
end
