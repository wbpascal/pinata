defmodule Persistence do
  @moduledoc "Database access: one function per business operation (ADR 0004)."

  use Boundary, deps: [Settings, Clock, Random], exports: [Supervisor, Release]

  import Ecto.Query

  alias Persistence.Account
  alias Persistence.Password
  alias Persistence.Repo

  @spec create_account(binary(), binary()) :: {:ok, pos_integer()} | {:error, :invalid_name | :name_taken}
  def create_account(name, password) do
    with true <- Account.valid_name?(name),
         {:ok, key} <- Account.name_key(name) do
      {hash, salt, iterations} = Password.hash(password)

      fields = [
        name: name,
        name_key: key,
        password_hash: hash,
        password_salt: salt,
        password_iterations: iterations
      ]

      repo = Repo.active()
      repo.transact(fn -> insert(repo, fields) end)
    else
      _ -> {:error, :invalid_name}
    end
  end

  defp insert(repo, fields) do
    changeset = %Account{} |> Ecto.Changeset.change(fields) |> Ecto.Changeset.unique_constraint(:name_key)

    case repo.insert(changeset) do
      {:ok, account} -> {:ok, account.id}
      # Leaves the transaction: on PostgreSQL a failed statement aborts it.
      {:error, _changeset} -> {:error, :name_taken}
    end
  end

  @spec check_login(binary(), binary()) ::
          {:ok, pos_integer()} | {:error, :unknown | :wrong_password | :blocked | :not_login_able}
  def check_login(name, password) do
    repo = Repo.active()
    {:ok, result} = repo.transact(fn -> {:ok, do_check_login(repo, name, password)} end)
    result
  end

  defp do_check_login(repo, name, password) do
    with {:ok, key} <- Account.name_key(name),
         %Account{} = account <- repo.one(from(a in Account, where: a.name_key == ^key)) do
      verified? = Password.verify?(password, account.password_hash, account.password_salt, account.password_iterations)

      cond do
        not verified? -> {:error, :wrong_password}
        account.blocked -> {:error, :blocked}
        not account.login_able -> {:error, :not_login_able}
        true -> {:ok, account.id}
      end
    else
      _ ->
        # An unknown name costs the same time as a known one.
        _ =
          Password.verify?(
            password,
            <<0::256>>,
            <<0::128>>,
            Application.get_env(:pinata, :password_iterations, 600_000)
          )

        {:error, :unknown}
    end
  end

  @spec set_blocked(binary(), boolean()) :: :ok | {:error, :unknown}
  def set_blocked(name, value) when is_boolean(value), do: set(name, blocked: value)

  @spec set_login_able(binary(), boolean()) :: :ok | {:error, :unknown}
  def set_login_able(name, value) when is_boolean(value), do: set(name, login_able: value)

  defp set(name, changes) do
    case Account.name_key(name) do
      {:ok, key} ->
        repo = Repo.active()
        {:ok, result} = repo.transact(fn -> {:ok, guarded_update(repo, key, changes)} end)
        result

      :error ->
        {:error, :unknown}
    end
  end

  defp guarded_update(repo, key, changes) do
    case repo.update_all(from(a in Account, where: a.name_key == ^key), set: changes) do
      {1, _} -> :ok
      {0, _} -> {:error, :unknown}
    end
  end
end
