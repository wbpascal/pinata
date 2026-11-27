defmodule GameData.CharDefaultSkill do
  @moduledoc """
  Schema of the `SKILL` rows of `DefaultCharacterData.txt` (server data table). Read by character creation (D02 §3.3).
  """

  @behaviour GameData.Schema

  @enforce_keys [:class, :skill_id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          class: integer(),
          skill_id: integer()
        }

  @impl GameData.Schema
  @spec __schema__() :: GameData.Schema.t()
  def __schema__ do
    %{
      source: {:csv, "tables/DefaultCharacterData/SKILL.csv"},
      key: :row,
      columns: [
        class: {"Class", :integer},
        skill_id: {"SkillID", :integer}
      ],
      indexes: [:class],
      references: []
    }
  end
end
