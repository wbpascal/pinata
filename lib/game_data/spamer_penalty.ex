defmodule GameData.SpamerPenalty do
  @moduledoc """
  Schema of `SpamerPenalty.shn` (server data table of the chat spam filter, Z02 §3.4).
  """

  @behaviour GameData.Schema

  @enforce_keys [:penalty_lv, :chat_block_time, :probate_time]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          penalty_lv: integer(),
          chat_block_time: integer(),
          probate_time: integer()
        }

  @impl GameData.Schema
  @spec __schema__() :: GameData.Schema.t()
  def __schema__ do
    %{
      source: {:shn, "shn/SpamerPenalty.shn"},
      key: :penalty_lv,
      columns: [
        penalty_lv: {"PenaltyLv", :integer},
        chat_block_time: {"ChatBlockTime", :integer},
        probate_time: {"ProbateTime", :integer}
      ],
      indexes: [],
      references: []
    }
  end
end
