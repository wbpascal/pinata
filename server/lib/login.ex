defmodule Login do
  @moduledoc "The Login part."

  use Boundary, deps: [Proto, Persistence, Cluster, GameData, Settings, Clock, Random], exports: [Supervisor]
end
