defmodule GameData.MapInfo do
  @moduledoc """
  Schema of `MapInfo.shn` (client data table). Target of the start map of `GameData.CharDefault` (D02 §3.3), the sight radius of a map (`Sight`, `Zone.MapInstance`) and the shown name of a map (`Name`, the title of a gate's menu).
  """

  @behaviour GameData.Schema

  @enforce_keys [:id, :map_name, :name, :sight]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: integer(),
          map_name: binary(),
          name: binary(),
          sight: integer()
        }

  @impl GameData.Schema
  @spec __schema__() :: GameData.Schema.t()
  def __schema__ do
    %{
      source: {:shn, "shn/MapInfo.shn"},
      key: :map_name,
      columns: [
        id: {"ID", :integer},
        map_name: {"MapName", :string},
        name: {"Name", :string},
        sight: {"Sight", :integer}
      ],
      indexes: [],
      references: []
    }
  end
end
