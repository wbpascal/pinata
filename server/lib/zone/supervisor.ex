defmodule Zone.Supervisor do
  @moduledoc """
  Root supervisor of `Zone`: the map registry, the map supervisor, `Zone.Maps` and the client listener, in this order.

  The strategy is `:rest_for_one`: `Zone.Maps` must start again when the map supervisor does, to start the map
  instances again, and the listener starts last so the node listens only when its maps run.
  """

  use Supervisor

  @spec start_link(Settings.t()) :: Supervisor.on_start()
  def start_link(settings), do: Supervisor.start_link(__MODULE__, settings, name: __MODULE__)

  @impl Supervisor
  def init(settings) do
    children = [
      {Registry, keys: :unique, name: Zone.MapRegistry},
      # One map instance that keeps crashing must not take the other maps and the listener down; only a crash loop in
      # init/1 reaches the limit.
      {DynamicSupervisor, name: Zone.MapSupervisor, strategy: :one_for_one, max_restarts: 1000, max_seconds: 1},
      {Zone.Maps, settings},
      {Net.Listener, {"Zone", Zone.Handler, settings.zone.port, settings}}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
