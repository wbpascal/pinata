defmodule Persistence.MigrationsTest do
  # Tests of the inside of the boundary: they may call `Persistence.Repo.active/0`.
  # Stops and restarts the application and sets environment variables, so it cannot run async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tmp_dir
  @moduletag capture_log: true

  setup do
    url = System.get_env("DATABASE_URL")
    :ok = Application.stop(:pinata)
    unload_migrations()

    on_exit(fn ->
      System.put_env("DATABASE_URL", url)
      Application.delete_env(:pinata, :extra_migration_paths)
      _ = Application.stop(:pinata)
      :ok = Application.start(:pinata)
    end)

    %{url: url}
  end

  test "a pending migration", %{tmp_dir: tmp_dir, url: url} do
    File.write!(Path.join(tmp_dir, "29990101000000_probe.exs"), """
    defmodule Persistence.Repo.Migrations.Probe do
      use Ecto.Migration

      def change do
        create table(:migration_probe) do
          add :n, :integer
        end
      end
    end
    """)

    Application.put_env(:pinata, :extra_migration_paths, [tmp_dir])

    if String.starts_with?(url, "sqlite:") do
      System.put_env("DATABASE_URL", "sqlite:" <> Path.join(tmp_dir, "fresh.db"))
      assert :ok = Application.start(:pinata)
      assert {:ok, _} = Persistence.create_account("probe", "pw")
      assert %{rows: []} = Persistence.Repo.active().query!("SELECT * FROM migration_probe")
    else
      output = capture_io(:stderr, fn -> assert {:error, _} = Application.start(:pinata) end)
      assert output =~ "Persistence.Release.migrate()"
      assert output =~ "29990101000000"
    end
  end

  # ADR 0010: a database of a published version reaches the current one by its pending migrations.
  # shortcut: SQLite only, since the PostgreSQL test database is shared and already migrated; CI's test-postgres job runs the same migrations from empty.
  test "a database of version 0.1.0 upgrades", %{tmp_dir: tmp_dir, url: url} do
    if String.starts_with?(url, "sqlite:") do
      db_url = "sqlite:" <> Path.join(tmp_dir, "v0_1_0.db")
      System.put_env("DATABASE_URL", db_url)
      {:ok, repo} = Persistence.Repo.configure(db_url)
      migrations = Application.app_dir(:pinata, "priv/repo/migrations")

      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn repo ->
          # the last migration that version 0.1.0 contains
          Ecto.Migrator.run(repo, migrations, :up, to: 20_261_119_000_000)

          repo.query!("""
          INSERT INTO accounts (id, name, name_key, password_hash, password_salt, password_iterations)
          VALUES (7, 'Old', 'old', x'00', x'00', 1)
          """)

          repo.query!("""
          INSERT INTO characters (id, world_id, account_id, slot, name, name_key, login_map, race, class, gender,
                                  hair, hair_color, face, kq_date, tutorial_state)
          VALUES (1, 0, 7, 0, 'Oldie', 'oldie', 'Rou', 0, 1, 0, 0, 0, 0, '2026-11-21T00:00:00Z', 0)
          """)
        end)

      unload_migrations()
      assert :ok = Application.start(:pinata)
      assert {:ok, [%{name: "Oldie"}]} = Persistence.list_characters(0, 7)
      assert {:ok, %{name: "Oldie", login_map: "Rou", admin_level: 0}} = Persistence.load_character(0, 7, 1)
    end
  end

  test "an unknown URL scheme" do
    System.put_env("DATABASE_URL", "mysql://x")
    output = capture_io(:stderr, fn -> assert {:error, _} = Application.start(:pinata) end)
    assert output =~ "database.url"
  end

  # the restarted application compiles these migrations again; unload them to avoid the redefinition warning
  defp unload_migrations do
    alias Persistence.Repo.Migrations

    for module <-
          [Migrations.CreateAccounts, Migrations.CreateCharacters] ++
            [Migrations.AddCharacterPlayTime, Migrations.AddCharacterAdminLevel] do
      :code.purge(module)
      :code.delete(module)
    end
  end
end
