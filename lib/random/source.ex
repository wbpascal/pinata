defmodule Random.Source do
  @moduledoc "What a random source for `Random` implements."

  @callback uniform(pos_integer()) :: pos_integer()
  @callback bytes(non_neg_integer()) :: binary()
end
