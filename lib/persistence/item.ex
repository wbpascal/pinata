defmodule Persistence.Item do
  @moduledoc "Private to `Persistence`: the `items` table. `storage` 8 is the equipment of a character, `slot` the `ItemEquipEnum` number."

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key false
  schema "items" do
    field :character_id, :integer
    field :storage, :integer
    field :slot, :integer
    field :item_id, :integer
    field :upgrade, :integer
    field :lot, :integer, default: 1
  end
end
