defmodule GameData.ShineNpc do
  @moduledoc """
  Schema of table `ShineNPC` of `World/NPC.txt`. `map` is not a strict reference to `FieldList` (a row on a map that does not run is skipped by the reader). `mob_name` is `MobInfo.inx_name`; one row of the 2016 data has none.
  """

  @behaviour GameData.Schema

  @enforce_keys [:mob_name, :map, :x, :y, :direct, :npc_menu, :role, :role_arg]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          mob_name: binary(),
          map: binary(),
          x: integer(),
          y: integer(),
          direct: integer(),
          npc_menu: integer(),
          role: binary(),
          role_arg: binary()
        }

  @impl GameData.Schema
  @spec __schema__() :: GameData.Schema.t()
  def __schema__ do
    %{
      source: {:csv, "tables/World/NPC/ShineNPC.csv"},
      key: :row,
      columns: [
        mob_name: {"MobName", :string},
        map: {"Map", :string},
        x: {"Coord-X", :integer},
        y: {"Coord-Y", :integer},
        direct: {"Direct", :integer},
        npc_menu: {"NPCMenu", :integer},
        role: {"Role", :string},
        role_arg: {"RoleArg0", :string}
      ],
      indexes: [:map],
      references: []
    }
  end
end
