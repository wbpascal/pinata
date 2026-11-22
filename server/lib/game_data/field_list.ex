defmodule GameData.FieldList do
  @moduledoc """
  Schema of table `FieldList` of `World/Field.txt` (server data table): one row per map or sub-map range. The map name repeats (`Rou`), so the key is the row. `sub_from` / `sub_to` are `"-"` for a map without sub-map range. `chat` / `shout`: 1 = allowed on the map (Z02 §3).
  """

  @behaviour GameData.Schema

  @enforce_keys [:map_id_client, :sub_from, :sub_to, :serial, :map_name, :kq, :chat, :shout]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          map_id_client: binary(),
          sub_from: binary(),
          sub_to: binary(),
          serial: integer(),
          map_name: binary(),
          kq: integer(),
          chat: integer(),
          shout: integer()
        }

  @impl GameData.Schema
  @spec __schema__() :: GameData.Schema.t()
  def __schema__ do
    %{
      source: {:csv, "tables/World/Field/FieldList.csv"},
      key: :row,
      columns: [
        map_id_client: {"MapIDClient", :string},
        sub_from: {"SubFrom", :string},
        sub_to: {"SubTo", :string},
        serial: {"Serial", :integer},
        map_name: {"MapName", :string},
        kq: {"KQ", :integer},
        chat: {"Chat", :integer},
        shout: {"Shout", :integer}
      ],
      indexes: [:map_id_client],
      references: []
    }
  end
end
