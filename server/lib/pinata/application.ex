defmodule Pinata.Application do
  @moduledoc false

  use Boundary, top_level?: true, deps: [Login, WorldManager, Zone, Persistence, Cluster, Settings, GameData]
  use Application

  @impl Application
  def start(_type, _args) do
    case Settings.load(System.get_env()) do
      {:ok, settings} ->
        tables = settings.parts |> Enum.flat_map(&part(&1).game_data()) |> Enum.uniq()

        case GameData.load(settings.data_dir, tables, strict_references: settings.data.strict_references) do
          :ok ->
            always = [{Persistence.Supervisor, settings}, {Cluster.Root, settings}]
            parts = Enum.map(settings.parts, &{part_supervisor(&1), settings})
            Supervisor.start_link(always ++ parts, strategy: :one_for_one, name: Pinata.Supervisor)

          {:error, problems} ->
            IO.puts(:stderr, Enum.join(["Invalid game data, the node does not start:" | problems], "\n  "))
            {:error, :invalid_game_data}
        end

      {:error, problems} ->
        IO.puts(:stderr, Enum.join(["Invalid settings, the node does not start:" | problems], "\n  "))
        {:error, :invalid_settings}
    end
  end

  defp part(:login), do: Login
  defp part(:world_manager), do: WorldManager
  defp part(:zone), do: Zone

  defp part_supervisor(:login), do: Login.Supervisor
  defp part_supervisor(:world_manager), do: WorldManager.Supervisor
  defp part_supervisor(:zone), do: Zone.Supervisor
end
