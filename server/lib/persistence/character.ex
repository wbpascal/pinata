defmodule Persistence.Character do
  @moduledoc "Private to `Persistence`: the `characters` table. `name` and `name_key` are bytes; the key has ASCII letters lower-cased."

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "characters" do
    field :world_id, :integer
    field :account_id, :integer
    field :slot, :integer
    field :name, :binary
    field :name_key, :binary
    field :level, :integer
    field :login_map, :string
    field :race, :integer
    field :class, :integer
    field :gender, :integer
    field :hair, :integer
    field :hair_color, :integer
    field :face, :integer
    field :kq_map, :string
    field :kq_x, :integer
    field :kq_y, :integer
    field :kq_date, :utc_datetime
    field :tutorial_state, :integer
    field :tutorial_step, :integer
    field :exp, :integer, default: 0
    field :login_x, :integer, default: 0
    field :login_y, :integer, default: 0
    field :hp, :integer, default: 0
    field :sp, :integer, default: 0
    field :money, :integer, default: 0
    field :hp_stones, :integer, default: 0
    field :sp_stones, :integer, default: 0
  end

  @doc "The unique key of a name: ASCII letters lower-cased, byte-wise (the name is not UTF-8 in general)."
  @spec name_key(binary()) :: binary()
  def name_key(name), do: for(<<b <- name>>, into: <<>>, do: <<if(b in ?A..?Z, do: b + 32, else: b)>>)
end
