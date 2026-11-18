defmodule GameData.ItemInfo do
  @moduledoc """
  Schema of `ItemInfo.shn` (client data table). Target of the starting items of `GameData.CharDefaultItem` (D02 §3.3).
  """

  @behaviour GameData.Schema

  @enforce_keys [:id, :inx_name, :class, :equip]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: integer(),
          inx_name: binary(),
          class: integer(),
          equip: integer()
        }

  @impl GameData.Schema
  @spec __schema__() :: GameData.Schema.t()
  def __schema__ do
    %{
      source: {:shn, "shn/ItemInfo.shn"},
      key: :id,
      columns: [
        id: {"ID", :integer},
        inx_name: {"InxName", :string},
        class: {"Class", :integer},
        equip: {"Equip", :integer}
      ],
      indexes: [],
      references: []
    }
  end
end
