defmodule WorldManager do
  @moduledoc "The WorldManager part."

  use Boundary, deps: [Proto, Persistence, Cluster, GameData, Clock, Random]
end
