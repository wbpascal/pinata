defmodule Login.Supervisor do
  @moduledoc "Root supervisor of `Login`. It starts the token process, in multi-node mode the world watch, then the client listener."

  use Supervisor

  @spec start_link(Settings.t()) :: Supervisor.on_start()
  def start_link(settings), do: Supervisor.start_link(__MODULE__, settings, name: __MODULE__)

  @impl Supervisor
  def init(settings) do
    watch = if Settings.single_node?(settings), do: [], else: [{Login.WorldWatch, settings.world}]
    listener = {Net.Listener, {"Login", Login.Handler, settings.login.port, settings}}
    Supervisor.init([Login.Tokens] ++ watch ++ [listener], strategy: :one_for_one)
  end
end
