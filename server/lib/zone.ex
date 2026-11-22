defmodule Zone do
  @moduledoc "The Zone part."

  use Boundary, deps: [Net, Proto, Persistence, Cluster, GameData, Settings, Clock, Random], exports: [Supervisor]

  @doc """
  The start-up check of ADR 0006 for every plain field map: the `.shbd` file exists (name matched without case) and
  its header is valid. The content is read at the first entry (`Zone.MapInstance`).
  """
  @spec check_maps(Path.t()) :: :ok | {:error, [String.t(), ...]}
  def check_maps(data_dir) do
    problems =
      for %{map_id_client: name} <- GameData.plain_field_maps(),
          {:error, message} <- [GameData.BlockData.check(data_dir, name)],
          do: "map #{name}: #{message}"

    case problems do
      [] -> :ok
      [_ | _] -> {:error, problems}
    end
  end

  @doc "The data tables this part reads (ADR 0006)."
  @spec game_data() :: [module()]
  def game_data do
    [
      GameData.FieldList,
      GameData.ShineNpc,
      GameData.LinkTable,
      GameData.ChrCommon,
      GameData.MobInfo,
      GameData.TownPortal,
      GameData.SpamerPenalty,
      GameData.SpamerPenaltyRule
    ]
  end
end
