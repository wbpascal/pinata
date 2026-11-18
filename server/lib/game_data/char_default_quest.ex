defmodule GameData.CharDefaultQuest do
  @moduledoc """
  Schema of the `QUEST` rows of `DefaultCharacterData.txt` (server data table; the 2016 file has none). Read by character creation (D02 §3.3).
  """

  @behaviour GameData.Schema

  @enforce_keys [:class, :quest_id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          class: integer(),
          quest_id: integer()
        }

  @impl GameData.Schema
  @spec __schema__() :: GameData.Schema.t()
  def __schema__ do
    %{
      source: {:csv, "tables/DefaultCharacterData/QUEST.csv"},
      key: :row,
      columns: [
        class: {"Class", :integer},
        quest_id: {"QuestID", :integer}
      ],
      indexes: [:class],
      references: []
    }
  end
end
