defmodule Mix.Tasks.Pinata.Account.Block do
  @shortdoc "Blocks an account"
  @moduledoc """
  Blocks an account. Usage: `mix pinata.account.block <name>`. See `docs/user/accounts.md` and `docs/user/operation.md`.
  """

  use Boundary, classify_to: Persistence
  use Mix.Task

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run([name]) do
    Mix.Task.run("app.config")

    try do
      Persistence.Release.block(name)
    rescue
      error in RuntimeError -> Mix.raise(error.message)
    end
  end

  def run(_args), do: Mix.raise("Usage: mix pinata.account.block <name>")
end
