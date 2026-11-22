defmodule Persistence do
  @moduledoc "Database access: one function per business operation (ADR 0004)."

  use Boundary, deps: [Settings, Clock, Random], exports: [Supervisor, Release]

  import Ecto.Query

  require Logger

  alias Persistence.Account
  alias Persistence.Character
  alias Persistence.Item
  alias Persistence.Password
  alias Persistence.Repo
  alias Persistence.Shortcut
  alias Persistence.Skill

  @equipped 8

  @type equipped :: %{slot: non_neg_integer(), item_id: non_neg_integer(), upgrade: non_neg_integer()}
  @type character :: %{
          id: pos_integer(),
          slot: 0..5,
          name: binary(),
          level: pos_integer(),
          login_map: String.t(),
          race: non_neg_integer(),
          class: non_neg_integer(),
          gender: 0..1,
          hair: non_neg_integer(),
          hair_color: non_neg_integer(),
          face: non_neg_integer(),
          kq_map: String.t(),
          kq_x: non_neg_integer(),
          kq_y: non_neg_integer(),
          kq_date: DateTime.t(),
          tutorial_state: 0..3,
          tutorial_step: non_neg_integer(),
          equipment: [equipped()]
        }

  @type new_character :: %{
          world_id: non_neg_integer(),
          account_id: pos_integer(),
          slot: 0..5,
          name: binary(),
          level: pos_integer(),
          exp: non_neg_integer(),
          login_map: String.t(),
          login_x: non_neg_integer(),
          login_y: non_neg_integer(),
          hp: non_neg_integer(),
          sp: non_neg_integer(),
          hp_stones: non_neg_integer(),
          sp_stones: non_neg_integer(),
          money: non_neg_integer(),
          race: non_neg_integer(),
          class: non_neg_integer(),
          gender: 0..1,
          hair: non_neg_integer(),
          hair_color: non_neg_integer(),
          face: non_neg_integer(),
          tutorial_state: 0..3,
          items: [
            %{storage: non_neg_integer(), slot: non_neg_integer(), item_id: non_neg_integer(), lot: pos_integer()}
          ],
          skills: [non_neg_integer()],
          shortcuts: [%{slot: non_neg_integer(), code: non_neg_integer(), value: non_neg_integer()}]
        }

  @character_keys [
    :id,
    :slot,
    :name,
    :level,
    :login_map,
    :race,
    :class,
    :gender,
    :hair,
    :hair_color,
    :face,
    :kq_map,
    :kq_x,
    :kq_y,
    :kq_date,
    :tutorial_state,
    :tutorial_step
  ]

  @doc "The characters of an account in a world, ordered by slot, each with its equipped items."
  @spec list_characters(non_neg_integer(), pos_integer()) :: {:ok, [character()]} | {:error, :database}
  def list_characters(world_id, user_no) do
    repo = Repo.active()

    transact(repo, "list_characters", fn ->
      characters =
        repo.all(from(c in Character, where: c.world_id == ^world_id and c.account_id == ^user_no, order_by: c.slot))

      items =
        from(i in Item,
          join: c in Character,
          on: i.character_id == c.id,
          where: c.world_id == ^world_id and c.account_id == ^user_no and i.storage == @equipped,
          order_by: [i.character_id, i.slot]
        )
        |> repo.all()
        |> Enum.group_by(& &1.character_id, &Map.take(&1, [:slot, :item_id, :upgrade]))

      {:ok, Enum.map(characters, &(&1 |> Map.take(@character_keys) |> Map.put(:equipment, Map.get(items, &1.id, []))))}
    end)
  end

  @doc "Creates a character with its starting items, skills and shortcuts in one transaction."
  @spec create_character(new_character()) :: {:ok, character()} | {:error, :slot_in_use | :name_taken | :database}
  def create_character(attrs) do
    repo = Repo.active()
    {related, fields} = Map.split(attrs, [:items, :skills, :shortcuts])

    fields =
      Map.merge(fields, %{
        name_key: Character.name_key(fields.name),
        kq_map: "",
        kq_x: 0,
        kq_y: 0,
        kq_date: DateTime.from_unix!(Clock.system_time(:second)),
        tutorial_step: 0
      })

    transact(repo, "create_character", fn ->
      slot_taken? =
        repo.exists?(
          from(c in Character,
            where: c.world_id == ^fields.world_id and c.account_id == ^fields.account_id and c.slot == ^fields.slot
          )
        )

      if slot_taken?, do: {:error, :slot_in_use}, else: insert_character(repo, fields, related)
    end)
  end

  defp insert_character(repo, fields, related) do
    changeset =
      %Character{}
      |> Ecto.Changeset.change(fields)
      |> Ecto.Changeset.unique_constraint(:slot, name: :characters_world_id_account_id_slot_index)
      |> Ecto.Changeset.unique_constraint(:name_key, name: :characters_world_id_name_key_index)
      |> Ecto.Changeset.foreign_key_constraint(:account_id)

    case repo.insert(changeset) do
      {:ok, character} -> insert_related(repo, character, related)
      # Leaves the transaction: on PostgreSQL a failed statement aborts it (D02-B2 fixed).
      {:error, changeset} -> {:error, insert_error(changeset)}
    end
  end

  defp insert_error(%{errors: errors}) do
    cond do
      Keyword.has_key?(errors, :name_key) -> :name_taken
      Keyword.has_key?(errors, :slot) -> :slot_in_use
      true -> :database
    end
  end

  defp insert_related(repo, character, related) do
    id = character.id

    rows = [
      {Item, Enum.map(related.items, &Map.put(&1, :character_id, id))},
      {Skill, Enum.map(related.skills, &%{character_id: id, skill_id: &1})},
      {Shortcut, Enum.map(related.shortcuts, &Map.put(&1, :character_id, id))}
    ]

    if Enum.all?(rows, fn {schema, list} -> inserted?(repo, schema, list) end) do
      equipment =
        for %{storage: @equipped} = i <- related.items, do: %{slot: i.slot, item_id: i.item_id, upgrade: 0}

      {:ok, character |> Map.take(@character_keys) |> Map.put(:equipment, Enum.sort_by(equipment, & &1.slot))}
    else
      {:error, :database}
    end
  end

  defp inserted?(_repo, _schema, []), do: true

  defp inserted?(repo, schema, list) do
    n = length(list)
    match?({^n, _}, repo.insert_all(schema, list))
  end

  @doc """
  Deletes the character in a slot of an account and world, with its items, skills and shortcuts (the foreign keys
  cascade), in one transaction (D02-B4 fixed). `:guild_master` is for the guild milestone; nothing returns it yet.
  """
  @spec delete_character(non_neg_integer(), pos_integer(), non_neg_integer()) ::
          :ok | {:error, :not_found | :guild_master | :database}
  def delete_character(world_id, account_id, slot) do
    repo = Repo.active()

    result =
      transact(repo, "delete_character", fn ->
        query = from(c in Character, where: c.world_id == ^world_id and c.account_id == ^account_id and c.slot == ^slot)

        case repo.delete_all(query) do
          {1, _} -> {:ok, :deleted}
          {0, _} -> {:error, :not_found}
        end
      end)

    with {:ok, :deleted} <- result, do: :ok
  end

  @doc """
  Renames the character in a slot of an account and world. The name is unique per world without regard to ASCII
  letter case (P02-B42 fixed).
  """
  @spec rename_character(non_neg_integer(), pos_integer(), non_neg_integer(), binary()) ::
          :ok | {:error, :not_found | :name_taken | :database}
  def rename_character(world_id, account_id, slot, name) do
    repo = Repo.active()

    result =
      transact(repo, "rename_character", fn ->
        query = from(c in Character, where: c.world_id == ^world_id and c.account_id == ^account_id and c.slot == ^slot)

        case repo.one(query) do
          nil -> {:error, :not_found}
          character -> update_name(repo, character, name)
        end
      end)

    with {:ok, :renamed} <- result, do: :ok
  end

  defp update_name(repo, character, name) do
    changeset =
      character
      |> Ecto.Changeset.change(name: name, name_key: Character.name_key(name))
      |> Ecto.Changeset.unique_constraint(:name_key, name: :characters_world_id_name_key_index)

    # stale_error_field: a row deleted since the read is a refusal, not a crash
    case repo.update(changeset, stale_error_field: :id) do
      {:ok, _character} ->
        {:ok, :renamed}

      # Leaves the transaction: on PostgreSQL a failed statement aborts it.
      {:error, %{errors: errors}} ->
        {:error, if(Keyword.has_key?(errors, :name_key), do: :name_taken, else: :not_found)}
    end
  end

  @spec create_account(binary(), binary()) :: {:ok, pos_integer()} | {:error, :invalid_name | :name_taken | :database}
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
      transact(repo, "create_account", fn -> insert(repo, fields) end)
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
          {:ok, pos_integer()} | {:error, :unknown | :wrong_password | :blocked | :not_login_able | :database}
  def check_login(name, password) do
    repo = Repo.active()

    case transact(repo, "check_login", fn -> {:ok, find(repo, name)} end) do
      # Hashing stays outside the transaction: it would hold the SQLite write lock or a pool connection.
      {:ok, account} -> verify(account, password)
      {:error, :database} -> {:error, :database}
    end
  end

  # A database failure raises inside repo.transact; callers get a value so that no caller crashes with a password in scope.
  defp transact(repo, operation, fun) do
    repo.transact(fun)
  rescue
    e in [DBConnection.ConnectionError, Postgrex.Error, Exqlite.Error] ->
      Logger.error("Persistence: the database failed in #{operation}: #{inspect(e.__struct__)} #{Exception.message(e)}")
      {:error, :database}
  end

  defp find(repo, name) do
    with {:ok, key} <- Account.name_key(name) do
      repo.one(from(a in Account, where: a.name_key == ^key))
    end
  end

  defp verify(%Account{} = account, password) do
    verified? = Password.verify?(password, account.password_hash, account.password_salt, account.password_iterations)

    cond do
      not verified? -> {:error, :wrong_password}
      account.blocked -> {:error, :blocked}
      not account.login_able -> {:error, :not_login_able}
      true -> {:ok, account.id}
    end
  end

  defp verify(_none, password) do
    # An unknown name costs the same time as a known one.
    _ = Password.verify?(password, <<0::256>>, <<0::128>>, Application.get_env(:pinata, :password_iterations, 600_000))
    {:error, :unknown}
  end

  @doc "Bans or unbans an account. A blocked account gets `:blocked` from `check_login/2` (client: \"The ID has been blocked.\")."
  @spec set_blocked(binary(), boolean()) :: :ok | {:error, :unknown}
  def set_blocked(name, value) when is_boolean(value), do: set(name, blocked: value)

  @doc "Lets an account in or keeps it out without banning it. `false` gives `:not_login_able` from `check_login/2` (client: \"The World Servers are down for maintenance.\")."
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
