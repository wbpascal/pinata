defmodule Persistence.Repo do
  @moduledoc """
  Private to `Persistence`: picks the repo module and its configuration from `database.url`.
  The configuration goes into the application environment because `Ecto.Migrator.with_repo/3` starts a repo from there.
  """

  @type t :: Persistence.Repo.Postgres | Persistence.Repo.SQLite

  @spec configure(String.t()) :: {:ok, t()} | {:error, String.t()}
  def configure("sqlite:" <> path) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok ->
        put(Persistence.Repo.SQLite, database: path, log: false, default_transaction_mode: :immediate)

      {:error, reason} ->
        {:error, "database.url: cannot create the directory of #{path} (#{:file.format_error(reason)})"}
    end
  end

  def configure("postgres://" <> _ = url), do: put(Persistence.Repo.Postgres, url: url, log: false)
  def configure("postgresql://" <> _ = url), do: put(Persistence.Repo.Postgres, url: url, log: false)

  # The URL of a PostgreSQL form holds the password: it is never printed.
  def configure(url) do
    scheme = url |> String.split(":", parts: 2) |> hd()

    {:error,
     "database.url: unknown scheme in #{inspect(scheme)}, expected sqlite:<path> or postgres://user:password@host/database"}
  end

  @spec active() :: t()
  def active, do: Application.fetch_env!(:pinata, :persistence_repo)

  defp put(repo, config) do
    Application.put_env(:pinata, repo, config)
    Application.put_env(:pinata, :persistence_repo, repo)
    {:ok, repo}
  end
end
