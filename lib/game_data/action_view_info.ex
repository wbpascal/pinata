defmodule GameData.ActionViewInfo do
  @moduledoc """
  Schema of `ActionViewInfo.shn` (client data table). Read by the emote handlers of Zone (Z02 §4): an emote id
  without a row is ignored. `action_type` is 0 (default), 1 (emotion) or 2 (charged, played through an item).
  """

  @behaviour GameData.Schema

  @enforce_keys [:index, :action_type]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          index: integer(),
          action_type: integer()
        }

  @impl GameData.Schema
  @spec __schema__() :: GameData.Schema.t()
  def __schema__ do
    %{
      source: {:shn, "shn/ActionViewInfo.shn"},
      key: :index,
      columns: [
        index: {"nIndex", :integer},
        action_type: {"eActionType", :integer}
      ],
      indexes: [],
      references: []
    }
  end
end
