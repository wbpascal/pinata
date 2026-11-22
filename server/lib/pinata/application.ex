defmodule Pinata.Application do
  @moduledoc false

  use Boundary, top_level?: true, deps: [Login, WorldManager, Zone, Persistence, Cluster, Settings, GameData]
  use Application

  require Logger

  @impl Application
  def start(_type, _args) do
    case Settings.load(System.get_env()) do
      {:ok, settings} ->
        Logger.configure(level: settings.log.level)
        # Mix starts Logger before it reads config/config.exs: re-apply the formatter.
        # No default handler exists in some runs (tests), so the result is ignored.
        _ = :logger.update_handler_config(:default, :formatter, Logger.default_formatter())
        tables = settings.parts |> Enum.flat_map(&part(&1).game_data()) |> Enum.uniq()

        with :ok <- GameData.load(settings.data_dir, tables, strict_references: settings.data.strict_references),
             :ok <- check_maps(settings) do
          start_tree(settings)
        else
          {:error, problems} ->
            IO.puts(:stderr, Enum.join(["Invalid game data, the node does not start:" | problems], "\n  "))
            {:error, :invalid_game_data}
        end

      {:error, problems} ->
        IO.puts(:stderr, Enum.join(["Invalid settings, the node does not start:" | problems], "\n  "))
        {:error, :invalid_settings}
    end
  end

  defp check_maps(settings), do: if(:zone in settings.parts, do: Zone.check_maps(settings.data_dir), else: :ok)

  defp start_tree(settings) do
    always = [{Persistence.Supervisor, settings}, {Cluster.Root, settings}] ++ digest_check(settings)
    parts = Enum.map(settings.parts, &{part_supervisor(&1), settings})

    with {:ok, pid} <- Supervisor.start_link(always ++ parts, strategy: :one_for_one, name: Pinata.Supervisor) do
      started(settings)
      {:ok, pid}
    end
  end

  defp started(settings) do
    mode = if Settings.single_node?(settings), do: "single-node", else: "multi-node"
    database = if String.starts_with?(settings.database.url, "sqlite:"), do: "sqlite", else: "postgres"
    parts = Enum.join(settings.parts, ", ")
    Logger.info("Pinata: node started, parts #{parts}, #{mode} mode, database #{database}")
  end

  # Only in multi-node mode (ADR 0006): single-node mode hashes nothing.
  defp digest_check(settings) do
    if Settings.single_node?(settings) do
      []
    else
      digest = GameData.digest(settings.data_dir)
      Logger.info("GameData: data directory digest #{digest}")
      [{Cluster.DataDigest, digest: digest, authority?: :world_manager in settings.parts}]
    end
  end

  defp part(:login), do: Login
  defp part(:world_manager), do: WorldManager
  defp part(:zone), do: Zone

  defp part_supervisor(:login), do: Login.Supervisor
  defp part_supervisor(:world_manager), do: WorldManager.Supervisor
  defp part_supervisor(:zone), do: Zone.Supervisor
end
