defmodule GameData.CharDefaultShortcut do
  @moduledoc """
  Schema of the `SHORTCUT` rows of `DefaultCharacterData.txt` (server data table). Read by character creation (D02 §3.3).
  """

  @behaviour GameData.Schema

  @enforce_keys [:class, :slot_no, :code_no, :value]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          class: integer(),
          slot_no: integer(),
          code_no: integer(),
          value: integer()
        }

  @impl GameData.Schema
  @spec __schema__() :: GameData.Schema.t()
  def __schema__ do
    %{
      source: {:csv, "tables/DefaultCharacterData/SHORTCUT.csv"},
      key: :row,
      columns: [
        class: {"Class", :integer},
        slot_no: {"SlotNo", :integer},
        code_no: {"CodeNo", :integer},
        value: {"Value", :integer}
      ],
      indexes: [:class],
      references: []
    }
  end
end
