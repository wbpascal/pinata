defmodule WorldManager.Supervisor do
  @moduledoc "Root supervisor of `WorldManager`. It has no children yet."

  use Supervisor

  @spec start_link(Settings.t()) :: Supervisor.on_start()
  def start_link(settings), do: Supervisor.start_link(__MODULE__, settings, name: __MODULE__)

  @impl Supervisor
  def init(_settings), do: Supervisor.init([], strategy: :one_for_one)
end
