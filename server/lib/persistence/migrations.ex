defmodule Persistence.Migrations do
  @moduledoc """
  Private to `Persistence`. At start-up SQLite is migrated; PostgreSQL refuses to start while migrations are pending.
  """

  @spec ensure(Persistence.Repo.t()) :: :ok | {:error, String.t()}
  def ensure(Persistence.Repo.SQLite = repo), do: run(repo)

  def ensure(Persistence.Repo.Postgres = repo) do
    pending = for {:down, version, name} <- Ecto.Migrator.migrations(repo, paths()), do: "#{version}_#{name}"

    if pending == [] do
      :ok
    else
      {:error,
       """
       The database has #{length(pending)} pending migration(s): #{Enum.join(pending, ", ")}
       The node does not start. Run them with the release command
         bin/pinata eval "Persistence.Release.migrate()"
       or, from a source checkout, with `mix pinata.migrate`.\
       """}
    end
  end

  @spec run(Persistence.Repo.t()) :: :ok
  def run(repo) do
    _ = Ecto.Migrator.run(repo, paths(), :up, all: true)
    :ok
  end

  @spec start_link(Persistence.Repo.t()) :: :ignore | {:error, :pending_migrations}
  def start_link(repo) do
    case ensure(repo) do
      :ok ->
        :ignore

      {:error, message} ->
        IO.puts(:stderr, message)
        {:error, :pending_migrations}
    end
  end

  @spec child_spec(Persistence.Repo.t()) :: Supervisor.child_spec()
  def child_spec(repo), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [repo]}, restart: :temporary}

  # The extra paths exist only so a test can add a pending migration.
  defp paths do
    [Application.app_dir(:pinata, "priv/repo/migrations")] ++ Application.get_env(:pinata, :extra_migration_paths, [])
  end
end
