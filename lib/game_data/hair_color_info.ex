defmodule GameData.HairColorInfo do
  @moduledoc """
  Schema of `HairColorInfo.shn` (client data table). Read by character creation to check the hair colour (D02 §3.3).
  """

  @behaviour GameData.Schema

  @enforce_keys [:id, :grade]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: integer(),
          grade: integer()
        }

  @impl GameData.Schema
  @spec __schema__() :: GameData.Schema.t()
  def __schema__ do
    %{
      source: {:shn, "shn/HairColorInfo.shn"},
      key: :id,
      columns: [
        id: {"ID", :integer},
        grade: {"Grade", :integer}
      ],
      indexes: [],
      references: []
    }
  end
end
