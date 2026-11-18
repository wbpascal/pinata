defmodule Zone do
  @moduledoc "The Zone part."

  use Boundary, deps: [Net, Proto, Persistence, Cluster, GameData, Settings, Clock, Random], exports: [Supervisor]
end
