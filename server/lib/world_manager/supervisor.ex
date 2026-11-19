defmodule WorldManager.Supervisor do
  @moduledoc "Root supervisor of `WorldManager`. It starts one `WorldManager.World` per world, then the client listener."

  use Supervisor

  @spec start_link(Settings.t()) :: Supervisor.on_start()
  def start_link(settings), do: Supervisor.start_link(__MODULE__, settings, name: __MODULE__)

  @impl Supervisor
  def init(settings) do
    worlds =
      for world <- settings.world,
          do: Supervisor.child_spec({WorldManager.World, world}, id: {WorldManager.World, world.number})

    listener = {Net.Listener, {WorldManager.Handler, settings.world_manager.port, settings}}
    Supervisor.init(worlds ++ [listener], strategy: :one_for_one)
  end
end
