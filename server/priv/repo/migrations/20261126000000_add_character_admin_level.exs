defmodule Persistence.Repo.Migrations.AddCharacterAdminLevel do
  use Ecto.Migration

  @check "admin_level >= 0 AND admin_level <= 255"

  def change do
    alter table(:characters) do
      # SQLite takes a check only as a column option, PostgreSQL ignores that option and takes a separate constraint.
      add :admin_level, :integer,
        null: false,
        default: 0,
        check: %{name: "characters_admin_level_check", expr: @check}
    end

    if repo().__adapter__() == Ecto.Adapters.Postgres do
      create constraint(:characters, "characters_admin_level_check", check: @check)
    end
  end
end
