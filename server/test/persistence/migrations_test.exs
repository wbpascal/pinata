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

  test "an unknown URL scheme" do
    System.put_env("DATABASE_URL", "mysql://x")
    output = capture_io(:stderr, fn -> assert {:error, _} = Application.start(:pinata) end)
    assert output =~ "database.url"
  end
end
