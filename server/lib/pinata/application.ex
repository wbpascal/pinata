defmodule Pinata.Application do
  @moduledoc false

  use Boundary, top_level?: true, deps: [Login, WorldManager, Zone, Persistence, Cluster, Settings]
  use Application

  @impl Application
  def start(_type, _args) do
    case Settings.load(System.get_env()) do
      {:ok, settings} ->
        always = [{Persistence.Supervisor, settings}, {Cluster.Root, settings}]
        parts = Enum.map(settings.parts, &{part_supervisor(&1), settings})
        Supervisor.start_link(always ++ parts, strategy: :one_for_one, name: Pinata.Supervisor)

      {:error, problems} ->
        IO.puts(:stderr, Enum.join(["Invalid settings, the node does not start:" | problems], "\n  "))
        {:error, :invalid_settings}
    end
  end

  defp part_supervisor(:login), do: Login.Supervisor
  defp part_supervisor(:world_manager), do: WorldManager.Supervisor
  defp part_supervisor(:zone), do: Zone.Supervisor
end
