defmodule Random do
  @moduledoc "The only way server code draws random numbers (ADR 0008). The source is the module in `config :fiesta, :random_source`, `Random.Rand` by default."

  use Boundary, exports: [Source]

  @spec uniform(pos_integer()) :: pos_integer()
  def uniform(n), do: Application.get_env(:fiesta, :random_source, Random.Rand).uniform(n)
end
