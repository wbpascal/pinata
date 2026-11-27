defmodule GameData.ChrCommon do
  @moduledoc """
  Schema of table `Common` of `World/ChrCommon.txt`: `ShoutLevel`, `ShoutDelay` (seconds).
  """

  @behaviour GameData.Schema

  @enforce_keys [:key, :argument]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          key: binary(),
          argument: integer()
        }

  @impl GameData.Schema
  @spec __schema__() :: GameData.Schema.t()
  def __schema__ do
    %{
      source: {:csv, "tables/World/ChrCommon/Common.csv"},
      key: :key,
      columns: [
        key: {"key", :string},
        argument: {"argument", :integer}
      ],
      indexes: [],
      references: []
    }
  end
end
