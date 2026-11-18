defmodule Random.Rand do
  @moduledoc "The default `Random` source: `:rand`."

  @behaviour Random.Source

  @impl Random.Source
  def uniform(n), do: :rand.uniform(n)
end
