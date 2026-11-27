defmodule GameData.MobInfo do
  @moduledoc """
  Schema of `MobInfo.shn` (client data table). An NPC is shown by the id of the row whose `InxName` is its mob name.
  """

  @behaviour GameData.Schema

  @enforce_keys [:id, :inx_name]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: integer(),
          inx_name: binary()
        }

  @impl GameData.Schema
  @spec __schema__() :: GameData.Schema.t()
  def __schema__ do
    %{
      source: {:shn, "shn/MobInfo.shn"},
      key: :id,
      columns: [
        id: {"ID", :integer},
        inx_name: {"InxName", :string}
      ],
      indexes: [:inx_name],
      references: []
    }
  end
end
