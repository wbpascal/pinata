defmodule Login do
  @moduledoc "The Login part."

  use Boundary, deps: [Proto, Persistence, Cluster, GameData, Clock, Random]
end
