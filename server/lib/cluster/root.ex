defmodule Cluster.Root do
  @moduledoc """
  Root supervisor of `Cluster`: the `:pg` scope of the registry and, in multi-node mode, libcluster.

  It is not named `Cluster.Supervisor` because libcluster owns that module name.
  """

  use Supervisor

  @spec start_link(Settings.t()) :: Supervisor.on_start()
  def start_link(settings), do: Supervisor.start_link(__MODULE__, settings, name: __MODULE__)

  @impl Supervisor
  def init(settings), do: Supervisor.init(children(settings.cluster.nodes), strategy: :one_for_one)

  @doc "The children for a node list from `cluster.nodes`. An empty list starts no topology."
  @spec children([String.t()]) :: [Supervisor.child_spec() | {module(), term()}]
  def children(nodes) do
    pg = %{id: :pg, start: {:pg, :start_link, [Cluster.Registry.scope()]}}

    case nodes do
      [] -> [pg]
      [_ | _] -> [pg, {Cluster.Supervisor, [topology(nodes), [name: Cluster.Libcluster]]}]
    end
  end

  # The names come from the administrator's settings file, so the number of atoms is bounded.
  defp topology(nodes),
    do: [pinata: [strategy: Cluster.Strategy.Epmd, config: [hosts: Enum.map(nodes, &String.to_atom/1)]]]
end
