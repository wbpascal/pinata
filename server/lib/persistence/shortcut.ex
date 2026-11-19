defmodule Persistence.Shortcut do
  @moduledoc "Private to `Persistence`: the `character_shortcuts` table, the shortcut bar of a character."

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key false
  schema "character_shortcuts" do
    field :character_id, :integer
    field :slot, :integer
    field :code, :integer
    field :value, :integer
  end
end
