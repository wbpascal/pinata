defmodule Login.Supervisor do
  @moduledoc "Root supervisor of `Login`. It starts the token process, then the client listener."

  use Supervisor

  @spec start_link(Settings.t()) :: Supervisor.on_start()
  def start_link(settings), do: Supervisor.start_link(__MODULE__, settings, name: __MODULE__)

  @impl Supervisor
  def init(settings),
    do:
      Supervisor.init([Login.Tokens, {Net.Listener, {Login.Handler, settings.login.port, settings}}],
        strategy: :one_for_one
      )
end
