defmodule TestRandomSpot do
  @moduledoc """
  Test-only `Random.Source` for the replay of scenario 14: the two draws of the free spot of `&linkto` without
  argument (`Zone.MapInstance.free_spot/1`) give the captured point x 4975, y 5825 (index 10774). It alternates per
  calling process (the map instance): x, then y. The connection seed (`uniform(499)`) and `bytes/1` use `Random.Rand`.
  Required on the peers like `test_clock.ex`.
  """

  @behaviour Random.Source

  @point {4975, 5825}

  @impl Random.Source
  def uniform(499), do: Random.Rand.uniform(499)

  def uniform(_n) do
    {x, y} = @point

    case Process.delete(__MODULE__) do
      :x_drawn ->
        y + 1

      nil ->
        Process.put(__MODULE__, :x_drawn)
        x + 1
    end
  end

  @impl Random.Source
  def bytes(n), do: Random.Rand.bytes(n)
end
