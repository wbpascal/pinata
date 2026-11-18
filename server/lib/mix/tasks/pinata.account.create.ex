defmodule Mix.Tasks.Pinata.Account.Create do
  @shortdoc "Creates an account (asks for the password)"
  @moduledoc """
  Creates an account (asks for the password). Usage: `mix pinata.account.create <name>`. See `docs/user/accounts.md` and `docs/user/operation.md`.
  """

  use Boundary, classify_to: Persistence
  use Mix.Task

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run([name]) do
    Mix.Task.run("app.config")

    try do
      Persistence.Release.create_account(name)
    rescue
      error in RuntimeError -> Mix.raise(error.message)
    end
  end

  def run(_args), do: Mix.raise("Usage: mix pinata.account.create <name>")
end
