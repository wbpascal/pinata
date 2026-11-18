defmodule GameData.CharDefaultItem do
  @moduledoc """
  Schema of the `ITEM` rows of `DefaultCharacterData.txt` (server data table). Read by character creation (D02 §3.3).
  """

  @behaviour GameData.Schema

  @enforce_keys [:class, :item_id, :lot]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          class: integer(),
          item_id: integer(),
          lot: integer()
        }

  @impl GameData.Schema
  @spec __schema__() :: GameData.Schema.t()
  def __schema__ do
    %{
      source: {:csv, "tables/DefaultCharacterData/ITEM.csv"},
      key: :row,
      columns: [
        class: {"Class", :integer},
        item_id: {"ItemID", :integer},
        lot: {"Lot", :integer}
      ],
      indexes: [:class],
      references: [item_id: GameData.ItemInfo]
    }
  end
end
