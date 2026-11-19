defmodule Persistence.Repo.Migrations.CreateCharacters do
  use Ecto.Migration

  @characters [
    id: "id BETWEEN 1 AND 4294967295",
    world_id: "world_id BETWEEN 0 AND 255",
    slot: "slot BETWEEN 0 AND 5",
    name: "length(name) BETWEEN 1 AND 20",
    level: "level BETWEEN 1 AND 255",
    login_map: "length(login_map) BETWEEN 1 AND 12",
    race: "race BETWEEN 0 AND 3",
    class: "class BETWEEN 0 AND 31",
    gender: "gender BETWEEN 0 AND 1",
    hair: "hair BETWEEN 0 AND 255",
    hair_color: "hair_color BETWEEN 0 AND 255",
    face: "face BETWEEN 0 AND 255",
    kq_map: "length(kq_map) <= 12",
    kq_x: "kq_x BETWEEN 0 AND 4294967295",
    kq_y: "kq_y BETWEEN 0 AND 4294967295",
    tutorial_state: "tutorial_state BETWEEN 0 AND 3",
    tutorial_step: "tutorial_step BETWEEN 0 AND 255"
  ]

  @items [
    storage: "storage BETWEEN 0 AND 255",
    slot: "slot BETWEEN 0 AND 255",
    item_id: "item_id BETWEEN 0 AND 65535",
    upgrade: "upgrade BETWEEN 0 AND 255"
  ]

  def change do
    create table(:characters, primary_key: [check: check(:characters, :id, @characters)]) do
      add :world_id, :integer, null: false, check: check(:characters, :world_id, @characters)

      add :account_id, references(:accounts, on_delete: :delete_all), null: false
      add :slot, :integer, null: false, check: check(:characters, :slot, @characters)
      add :name, :binary, null: false, check: check(:characters, :name, @characters)
      add :name_key, :binary, null: false
      add :level, :integer, null: false, default: 1, check: check(:characters, :level, @characters)
      add :login_map, :string, null: false, check: check(:characters, :login_map, @characters)
      add :race, :integer, null: false, check: check(:characters, :race, @characters)
      add :class, :integer, null: false, check: check(:characters, :class, @characters)
      add :gender, :integer, null: false, check: check(:characters, :gender, @characters)
      add :hair, :integer, null: false, check: check(:characters, :hair, @characters)
      add :hair_color, :integer, null: false, check: check(:characters, :hair_color, @characters)
      add :face, :integer, null: false, check: check(:characters, :face, @characters)
      add :kq_map, :string, null: false, default: "", check: check(:characters, :kq_map, @characters)
      add :kq_x, :bigint, null: false, default: 0, check: check(:characters, :kq_x, @characters)
      add :kq_y, :bigint, null: false, default: 0, check: check(:characters, :kq_y, @characters)
      add :kq_date, :utc_datetime, null: false
      add :tutorial_state, :integer, null: false, check: check(:characters, :tutorial_state, @characters)
      add :tutorial_step, :integer, null: false, default: 0, check: check(:characters, :tutorial_step, @characters)
    end

    constraints(:characters, @characters)

    create unique_index(:characters, [:world_id, :account_id, :slot])
    create unique_index(:characters, [:world_id, :name_key])

    create table(:items, primary_key: false) do
      add :character_id, references(:characters, on_delete: :delete_all), null: false
      add :storage, :integer, null: false, check: check(:items, :storage, @items)
      add :slot, :integer, null: false, check: check(:items, :slot, @items)
      add :item_id, :integer, null: false, check: check(:items, :item_id, @items)
      add :upgrade, :integer, null: false, default: 0, check: check(:items, :upgrade, @items)
    end

    constraints(:items, @items)

    create unique_index(:items, [:character_id, :storage, :slot])
  end

  # SQLite takes a check only as a column option, PostgreSQL ignores that option and takes a separate constraint.
  defp check(table, column, list), do: %{name: name(table, column), expr: Keyword.fetch!(list, column)}

  defp name(table, column), do: "#{table}_#{column}_check"

  defp constraints(table, list) do
    if repo().__adapter__() == Ecto.Adapters.Postgres do
      for {column, expr} <- list, do: create(constraint(table, name(table, column), check: expr))
    end
  end
end
