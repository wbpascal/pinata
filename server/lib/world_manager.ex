defmodule WorldManager do
  @moduledoc "The WorldManager part."

  use Boundary, deps: [Net, Proto, Persistence, Cluster, GameData, Settings, Clock, Random], exports: [Supervisor]
end
