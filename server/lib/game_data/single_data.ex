defmodule GameData.SingleData do
  @moduledoc """
  Schema of `SingleData.shn` (client data table). Read by WorldManager character creation (W01 §4.1): the row `ChrLevel_CanCreateSen`.
  """

  @behaviour GameData.Schema

  @enforce_keys [:name, :value]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          name: binary(),
          value: integer()
        }

  @impl GameData.Schema
  @spec __schema__() :: GameData.Schema.t()
  def __schema__ do
    %{
      source: {:shn, "shn/SingleData.shn"},
      key: :name,
      columns: [
        name: {"SingleDataIDX", :string},
        value: {"SingleDataValue", :integer}
      ],
      indexes: [],
      references: []
    }
  end
end
