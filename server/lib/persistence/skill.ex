defmodule Persistence.Skill do
  @moduledoc "Private to `Persistence`: the `character_skills` table, the skills a character has learnt."

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key false
  schema "character_skills" do
    field :character_id, :integer
    field :skill_id, :integer
  end
end
