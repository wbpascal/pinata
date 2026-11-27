defmodule Mix.Tasks.Pinata.Migrate do
  @shortdoc "Runs the pending database migrations"
  @moduledoc """
  Runs the pending database migrations. Usage: `mix pinata.migrate`. See `docs/user/accounts.md` and `docs/user/operation.md`.
  """

  use Boundary, classify_to: Persistence
  use Mix.Task

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run([]) do
    Mix.Task.run("app.config")

    try do
      Persistence.Release.migrate()
    rescue
      error in RuntimeError -> Mix.raise(error.message)
    end
  end

  def run(_args), do: Mix.raise("Usage: mix pinata.migrate")
end
