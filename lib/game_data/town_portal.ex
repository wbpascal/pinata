defmodule GameData.TownPortal do
  @moduledoc """
  Schema of `TownPortal.shn` (client data table): the destination of the town portal request `0x181A`.
  """

  @behaviour GameData.Schema

  @enforce_keys [:index, :min_level, :group, :map_name, :x, :y]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          index: integer(),
          min_level: integer(),
          group: integer(),
          map_name: binary(),
          x: integer(),
          y: integer()
        }

  @impl GameData.Schema
  @spec __schema__() :: GameData.Schema.t()
  def __schema__ do
    %{
      source: {:shn, "shn/TownPortal.shn"},
      key: :index,
      columns: [
        index: {"Index", :integer},
        min_level: {"MinLevel", :integer},
        group: {"TP_GroupNo", :integer},
        map_name: {"MapName", :string},
        x: {"X", :integer},
        y: {"Y", :integer}
      ],
      indexes: [],
      references: []
    }
  end
end
