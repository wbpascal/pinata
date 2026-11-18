defmodule Zone do
  @moduledoc "The Zone part."

  use Boundary, deps: [Proto, Persistence, Cluster, GameData, Clock, Random]
end
