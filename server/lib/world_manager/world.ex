defmodule WorldManager.World do
  @moduledoc "The registered process of one world: its presence under `Cluster.Registry.world_manager/1` marks the world open."

  use GenServer

  @spec start_link(Settings.world()) :: GenServer.on_start()
  def start_link(world), do: GenServer.start_link(__MODULE__, world, name: Cluster.Registry.world_manager(world.number))

  @impl GenServer
  def init(world), do: {:ok, world}
end
