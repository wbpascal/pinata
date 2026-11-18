defmodule WorldManager.Supervisor do
  @moduledoc "Root supervisor of `WorldManager`. It starts the client listener."

  use Supervisor

  @spec start_link(Settings.t()) :: Supervisor.on_start()
  def start_link(settings), do: Supervisor.start_link(__MODULE__, settings, name: __MODULE__)

  @impl Supervisor
  def init(settings),
    do:
      Supervisor.init([{Net.Listener, {WorldManager.Handler, settings.world_manager.port, settings}}],
        strategy: :one_for_one
      )
end
