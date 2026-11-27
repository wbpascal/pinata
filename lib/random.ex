defmodule Random do
  @moduledoc "The only way server code draws random numbers (ADR 0008). The source is the module in `config :pinata, :random_source`, `Random.Rand` by default."

  use Boundary, exports: [Source]

  @spec uniform(pos_integer()) :: pos_integer()
  def uniform(n), do: Application.get_env(:pinata, :random_source, Random.Rand).uniform(n)

  @spec bytes(non_neg_integer()) :: binary()
  def bytes(n), do: Application.get_env(:pinata, :random_source, Random.Rand).bytes(n)

  @doc "Seeds the generator of the calling process, so that its draws from the default source repeat (the load run). An injected source ignores it."
  @spec seed(integer()) :: :ok
  def seed(n) do
    _ = :rand.seed(:exsss, n)
    :ok
  end
end
