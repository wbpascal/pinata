defmodule GameData.BadNameFilter do
  @moduledoc """
  Schema of `BadNameFilter.shn` (client data table). Read by WorldManager character creation (W01 §4.1, `GetIsBadName`).
  The names repeat, so the key is the row.
  """

  @behaviour GameData.Schema

  @enforce_keys [:bad_name, :type]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          bad_name: binary(),
          type: integer()
        }

  @impl GameData.Schema
  @spec __schema__() :: GameData.Schema.t()
  def __schema__ do
    %{
      source: {:shn, "shn/BadNameFilter.shn"},
      key: :row,
      columns: [
        bad_name: {"BadName", :string},
        type: {"Type", :integer}
      ],
      indexes: [:type],
      references: []
    }
  end
end
