defmodule Zone do
  @moduledoc "The Zone part."

  use Boundary, deps: [Net, Proto, Persistence, Cluster, GameData, Settings, Clock, Random], exports: [Supervisor]

  @doc "The data tables this part reads (ADR 0006)."
  @spec game_data() :: [module()]
  def game_data, do: []
end
