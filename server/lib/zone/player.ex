defmodule Zone.Player do
  @moduledoc """
  A player on a map instance: the loaded character, where it stands and the values the map-entry burst sends
  (`Zone.MapEntry`). Built by the Zone connection from the stored character and the session entry; the map
  instance sets `handle` and `mode` (0 after the entry, 1 after `0x1803`).

  `admin_level` is always 0 when loaded: the column is issue 116.
  """

  @type equipment :: %{
          slot: non_neg_integer(),
          item_id: non_neg_integer(),
          upgrade: non_neg_integer(),
          class: integer() | :unknown
        }

  @enforce_keys [:character, :world_no, :map, :x, :y, :walk_speed, :run_speed, :map_type, :equipment, :address]
  defstruct @enforce_keys ++ [handle: :none, conn: :none, mode: 0, admin_level: 0]

  @type t :: %__MODULE__{
          character: Persistence.loaded_character(),
          world_no: Cluster.Registry.world_id(),
          map: String.t(),
          x: non_neg_integer(),
          y: non_neg_integer(),
          walk_speed: non_neg_integer(),
          run_speed: non_neg_integer(),
          map_type: integer(),
          equipment: [equipment()],
          address: String.t(),
          handle: :none | 8000..9499,
          conn: :none | pid(),
          mode: 0 | 1,
          admin_level: non_neg_integer()
        }

  @doc """
  The player of a loaded character entering the map of the session entry. Speeds come from `ChrCommon`
  (`WalkSpeed`, `RunSpeed`), the map type from the first `FieldList` row of the map, the class of each worn item from
  `ItemInfo` (`:unknown` without a row). A missing `ChrCommon` or `FieldList` row is `{:error, :game_data}`.
  """
  @spec new(Persistence.loaded_character(), Cluster.Sessions.entry(), String.t(), pid()) ::
          {:ok, t()} | {:error, :game_data}
  def new(character, entry, address, conn) do
    with {:ok, %{argument: walk}} <- GameData.fetch(GameData.ChrCommon, "WalkSpeed"),
         {:ok, %{argument: run}} <- GameData.fetch(GameData.ChrCommon, "RunSpeed"),
         [field | _] <- GameData.lookup(GameData.FieldList, :map_id_client, entry.map) do
      {:ok,
       %__MODULE__{
         character: character,
         world_no: entry.world_no,
         map: entry.map,
         x: character.login_x,
         y: character.login_y,
         walk_speed: walk,
         run_speed: run,
         map_type: field.kq,
         equipment: Enum.map(character.equipment, &Map.put(&1, :class, class(&1.item_id))),
         address: address,
         conn: conn
       }}
    else
      _missing -> {:error, :game_data}
    end
  end

  defp class(item_id) do
    case GameData.fetch(GameData.ItemInfo, item_id) do
      {:ok, %{class: class}} -> class
      :error -> :unknown
    end
  end
end
