defmodule GameData.SpamerPenaltyRule do
  @moduledoc """
  Schema of `SpamerPenaltyRule.shn` (server data table of the chat spam filter, Z02 §3.4); the table has one row.
  """

  @behaviour GameData.Schema

  @enforce_keys [:second_rule, :repeat_rule]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          second_rule: integer(),
          repeat_rule: integer()
        }

  @impl GameData.Schema
  @spec __schema__() :: GameData.Schema.t()
  def __schema__ do
    %{
      source: {:shn, "shn/SpamerPenaltyRule.shn"},
      key: :row,
      columns: [
        second_rule: {"SecondRule", :integer},
        repeat_rule: {"RepeatRule", :integer}
      ],
      indexes: [],
      references: []
    }
  end
end
