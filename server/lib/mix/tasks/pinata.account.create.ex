defmodule Mix.Tasks.Pinata.Account.Create do
  @shortdoc "Creates an account or a batch of accounts (asks for the password)"
  @moduledoc """
  Creates an account (asks for the password). Usage: `mix pinata.account.create <name>`, or
  `mix pinata.account.create --count <n> --prefix <prefix>` for the accounts `<prefix>0001` to `<prefix><n>` with one
  password. See `docs/user/accounts.md` and `docs/user/operation.md`.
  """

  use Boundary, classify_to: Persistence
  use Mix.Task

  @usage "Usage: mix pinata.account.create <name> | --count <n> --prefix <prefix>"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    command =
      case OptionParser.parse(args, strict: [count: :integer, prefix: :string]) do
        {[], [name], []} -> fn -> Persistence.Release.create_account(name) end
        {options, [], []} -> batch(options)
        _invalid -> Mix.raise(@usage)
      end

    Mix.Task.run("app.config")

    try do
      command.()
    rescue
      error in RuntimeError -> Mix.raise(error.message)
    end
  end

  defp batch(options) do
    case {Keyword.fetch(options, :prefix), Keyword.fetch(options, :count)} do
      {{:ok, prefix}, {:ok, count}} -> fn -> Persistence.Release.create_accounts(prefix, count) end
      _missing -> Mix.raise(@usage)
    end
  end
end
