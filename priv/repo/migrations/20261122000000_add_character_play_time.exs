defmodule Persistence.Repo.Migrations.AddCharacterPlayTime do
  use Ecto.Migration

  @check "play_minutes >= 0"

  def change do
    alter table(:characters) do
      # SQLite takes a check only as a column option, PostgreSQL ignores that option and takes a separate constraint.
      add :play_minutes, :bigint,
        null: false,
        default: 0,
        check: %{name: "characters_play_minutes_check", expr: @check}

      # nil: the character never left the world
      add :logout_at, :utc_datetime
    end

    if repo().__adapter__() == Ecto.Adapters.Postgres do
      create constraint(:characters, "characters_play_minutes_check", check: @check)
    end
  end
end
