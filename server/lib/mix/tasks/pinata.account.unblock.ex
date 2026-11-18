defmodule Mix.Tasks.Pinata.Account.Unblock do
  @shortdoc "Unblocks an account"
  @moduledoc """
  Unblocks an account. Usage: `mix pinata.account.unblock <name>`. See `docs/user/accounts.md` and `docs/user/operation.md`.
  """

  use Boundary, classify_to: Persistence
  use Mix.Task

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run([name]) do
    Mix.Task.run("app.config")

    try do
      Persistence.Release.unblock(name)
    rescue
      error in RuntimeError -> Mix.raise(error.message)
    end
  end

  def run(_args), do: Mix.raise("Usage: mix pinata.account.unblock <name>")
end
