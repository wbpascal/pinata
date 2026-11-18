defmodule Proto do
  @moduledoc "Client protocol: framing, cipher and packet definitions. Named `Proto` because `Protocol` is an Elixir core module."

  use Boundary, deps: [Clock, Random]
end
