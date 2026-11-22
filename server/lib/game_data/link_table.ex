defmodule GameData.LinkTable do
  @moduledoc """
  Schema of table `LinkTable` of `World/NPC.txt`: the destination of a Gate NPC (`ShineNpc.role_arg`). `argument` repeats in 7 cases, so the key is the row and the reader takes the first row of the index.
  """

  @behaviour GameData.Schema

  @enforce_keys [:argument, :map_server, :map_client, :x, :y, :direct, :party]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          argument: binary(),
          map_server: binary(),
          map_client: binary(),
          x: integer(),
          y: integer(),
          direct: integer(),
          party: integer()
        }

  @impl GameData.Schema
  @spec __schema__() :: GameData.Schema.t()
  def __schema__ do
    %{
      source: {:csv, "tables/World/NPC/LinkTable.csv"},
      key: :row,
      columns: [
        argument: {"argument", :string},
        map_server: {"MapServer", :string},
        map_client: {"MapClient", :string},
        x: {"Coord-X", :integer},
        y: {"Coord-Y", :integer},
        direct: {"Direct", :integer},
        party: {"Party", :integer}
      ],
      indexes: [:argument],
      references: []
    }
  end
end
