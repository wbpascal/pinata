defmodule WorldManager do
  @moduledoc "The WorldManager part."

  use Boundary, deps: [Net, Proto, Persistence, Cluster, GameData, Settings, Clock, Random], exports: [Supervisor]

  @doc "The data tables this part reads (ADR 0006)."
  @spec game_data() :: [module()]
  def game_data,
    do: [
      GameData.SingleData,
      GameData.BadNameFilter,
      GameData.MapInfo,
      GameData.ItemInfo,
      GameData.HairInfo,
      GameData.HairColorInfo,
      GameData.FaceInfo,
      GameData.CharDefault,
      GameData.CharDefaultItem,
      GameData.CharDefaultSkill,
      GameData.CharDefaultQuest,
      GameData.CharDefaultShortcut
    ]
end
