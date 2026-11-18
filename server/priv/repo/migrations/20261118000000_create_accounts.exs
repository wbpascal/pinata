defmodule Persistence.Repo.Migrations.CreateAccounts do
  use Ecto.Migration

  def change do
    create table(:accounts) do
      add :name, :string, null: false
      add :name_key, :string, null: false
      add :password_hash, :binary, null: false
      add :password_salt, :binary, null: false
      add :password_iterations, :integer, null: false
      add :blocked, :boolean, null: false, default: false
      add :login_able, :boolean, null: false, default: true
    end

    create unique_index(:accounts, [:name_key])
  end
end
