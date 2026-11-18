defmodule Persistence.Supervisor do
  @moduledoc """
  Root supervisor of `Persistence`. It starts the repo chosen by `database.url`, then the migration step
  (`Persistence.Migrations`), which ends the start of the node when PostgreSQL has pending migrations.
  """

  use Supervisor

  @spec start_link(Settings.t()) :: Supervisor.on_start()
  def start_link(settings) do
    case Persistence.Repo.configure(settings.database.url) do
      {:ok, repo} ->
        Supervisor.start_link(__MODULE__, repo, name: __MODULE__)

      {:error, message} ->
        IO.puts(:stderr, message)
        {:error, :invalid_database_url}
    end
  end

  @impl Supervisor
  def init(repo), do: Supervisor.init([repo, {Persistence.Migrations, repo}], strategy: :one_for_one)
end
