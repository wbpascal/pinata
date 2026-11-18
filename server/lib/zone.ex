defmodule Zone do
  @moduledoc "The Zone part."

  use Boundary, deps: [Proto, Persistence, Cluster, GameData, Settings, Clock, Random], exports: [Supervisor]
end
