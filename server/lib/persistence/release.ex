defmodule Persistence.Release do
  @moduledoc """
  Operator commands that need no Mix: `bin/pinata eval 'Persistence.Release.migrate()'` and the account commands.
  Every function returns `:ok` and raises `RuntimeError` with a readable message on failure; the crash is intended,
  so `mix` and `bin/pinata eval` both exit non-zero.
  """

  @spec migrate() :: :ok
  def migrate do
    with_repo(&Persistence.Migrations.run/1)
    IO.puts("Migrations are up to date.")
  end

  @spec create_account(String.t()) :: :ok
  def create_account(name) do
    ready(fn ->
      # shortcut: the password is echoed while typed, hide it when a terminal library is acceptable
      typed =
        case IO.gets("Password: ") do
          line when is_binary(line) -> line |> String.trim_trailing("\n") |> String.trim_trailing("\r")
          _eof_or_error -> ""
        end

      if typed == "", do: raise("No password given.")

      # The 2016 client sends the lower-case hex MD5 of the typed password; that is what is stored hashed.
      password = Base.encode16(:crypto.hash(:md5, typed), case: :lower)

      case Persistence.create_account(name, password) do
        {:ok, id} ->
          IO.puts("Account #{name} created, user number #{id}.")

        {:error, :name_taken} ->
          raise "An account named #{name} exists already."

        {:error, :database} ->
          raise "The database failed; see the log line above."

        {:error, :invalid_name} ->
          raise "#{name} is not a valid account name: 1 to 255 printable ASCII characters, no spaces."
      end
    end)
  end

  @spec block(String.t()) :: :ok
  def block(name), do: set_blocked(name, true, "blocked")

  @spec unblock(String.t()) :: :ok
  def unblock(name), do: set_blocked(name, false, "unblocked")

  defp set_blocked(name, value, word) do
    ready(fn ->
      case Persistence.set_blocked(name, value) do
        :ok -> IO.puts("Account #{name} #{word}.")
        {:error, :unknown} -> raise "No account named #{name}."
      end
    end)
  end

  defp ready(fun) do
    with_repo(fn repo ->
      case Persistence.Migrations.ensure(repo) do
        :ok -> fun.()
        {:error, message} -> raise message
      end
    end)
  end

  defp with_repo(fun) do
    settings =
      case Settings.load(System.get_env()) do
        {:ok, settings} -> settings
        {:error, problems} -> raise Enum.join(problems, "\n")
      end

    repo =
      case Persistence.Repo.configure(settings.database.url) do
        {:ok, repo} -> repo
        {:error, message} -> raise message
      end

    {:ok, _result, _apps} = Ecto.Migrator.with_repo(repo, fun)
    :ok
  end
end
