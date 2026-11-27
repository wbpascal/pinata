defmodule GameData.MapInfo do
  @moduledoc """
  Schema of `MapInfo.shn` (client data table). Target of the start map of `GameData.CharDefault` (D02 §3.3), the sight radius of a map (`Sight`, `Zone.MapInstance`) the shown name of a map (`Name`, the title of a gate's menu) and the point of `&linkto <map>` (`RegenX`, `RegenY`).
  """

  @behaviour GameData.Schema

  @enforce_keys [:id, :map_name, :name, :sight, :regen_x, :regen_y]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: integer(),
          map_name: binary(),
          name: binary(),
          sight: integer(),
          regen_x: integer(),
          regen_y: integer()
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
        sight: {"Sight", :integer},
        regen_x: {"RegenX", :integer},
        regen_y: {"RegenY", :integer}
      ],
      indexes: [],
      references: []
    }
  end
end
