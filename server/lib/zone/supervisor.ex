defmodule Zone.Supervisor do
  @moduledoc "Root supervisor of `Zone`. It starts the client listener."

  use Supervisor

  @spec start_link(Settings.t()) :: Supervisor.on_start()
  def start_link(settings), do: Supervisor.start_link(__MODULE__, settings, name: __MODULE__)

  @impl Supervisor
  def init(settings),
    do: Supervisor.init([{Net.Listener, {Zone.Handler, settings.zone.port, settings}}], strategy: :one_for_one)
end
