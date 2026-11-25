defmodule Zone.Player do
  @moduledoc """
  A player on a map instance: the loaded character, where it stands and the values the map-entry burst sends
  (`Zone.MapEntry`). Built by the Zone connection from the stored character and the session entry; the map
  instance sets `handle` and `mode` (0 after the entry, 1 after `0x1803`).

  `admin_level` is always 0 when loaded: the column is issue 116.

  `dir` is the direction the player faces (90 after the entry, the original's `0x1803` handler sets it; no column
  holds one). `dimension` and `sub_layer` decide with the sight radius who sees whom (`Zone.Sight`): objects see each
  other only in the same dimension or when one of them is in dimension -1, and the sub-layer (0 Base, 1 RangerStealth,
  2 Observer, 3 AdminHide, 4 GMDoor, 5 GMPlayer) decides one way whether an object is shown to another. Both are 0
  after the entry and are set by `Zone.MapInstance.set_layer/4`.

  Movement (`docs/technical/movement.md`): `mover` is the running move (`Zone.Mover`, `:none` while standing), `move`
  the last relayed move packet (`0x2018` / `0x201A`, sent again after an appear; `:none` after a stop), `last_good`
  the last position the block check accepted (the entry position at first), where a pull-back puts the player.

  `chat` is the state of the chat spam filter and the shout delay (`Zone.Chat`): empty at every entry into a map
  instance, never stored.
  """

  @type equipment :: %{
          slot: non_neg_integer(),
          item_id: non_neg_integer(),
          upgrade: non_neg_integer(),
          class: integer() | :unknown
        }

  @enforce_keys [
    :character,
    :world_no,
    :map,
    :x,
    :y,
    :walk_speed,
    :run_speed,
    :map_type,
    :equipment,
    :address,
    :last_good
  ]
  defstruct @enforce_keys ++
              [
                handle: :none,
                conn: :none,
                mode: 0,
                admin_level: 0,
                dir: 90,
                dimension: 0,
                sub_layer: 0,
                mover: :none,
                move: :none,
                chat: %{ring: [], block_until: :none, probation_until: :none, next_shout: :none}
              ]

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
          admin_level: non_neg_integer(),
          dir: 0..255,
          dimension: integer(),
          sub_layer: 0..5,
          last_good: Zone.Grid.point(),
          mover: :none | Zone.Mover.t(),
          move: :none | Proto.Packets.ActSomeonemovewalkCmd.t() | Proto.Packets.ActSomeonemoverunCmd.t(),
          chat: Zone.Chat.state()
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
         last_good: {character.login_x, character.login_y},
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
