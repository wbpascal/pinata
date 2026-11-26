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
      password = password!()

      case Persistence.create_account(name, password) do
        {:ok, id} ->
          IO.puts("Account #{name} created, user number #{id}.")

        {:error, :name_taken} ->
          raise "An account named #{name} exists already."

        {:error, :database} ->
          raise "The database failed; see the log line above."

        {:error, :invalid_name} ->
          raise invalid_name(name)
      end
    end)
  end

  defp create_one(name, password) do
    case Persistence.create_account(name, password) do
      {:ok, _id} -> :created
      {:error, :name_taken} -> :existing
      {:error, :database} -> raise "The database failed; see the log line above."
      {:error, :invalid_name} -> raise invalid_name(name)
    end
  end

  defp invalid_name(name), do: "#{name} is not a valid account name: 1 to 255 printable ASCII characters, no spaces."

  defp password! do
    # shortcut: the password is echoed while typed, hide it when a terminal library is acceptable
    typed =
      case IO.gets("Password: ") do
        line when is_binary(line) -> line |> String.trim_trailing("\n") |> String.trim_trailing("\r")
        _eof_or_error -> ""
      end

    if typed == "", do: raise("No password given.")

    # The 2016 client sends the lower-case hex MD5 of the typed password; that is what is stored hashed.
    Base.encode16(:crypto.hash(:md5, typed), case: :lower)
  end

  @doc "Creates the accounts `<prefix>0001` to `<prefix><count>` with one password, asked once; existing names are counted, not changed."
  @spec create_accounts(String.t(), pos_integer()) :: :ok
  def create_accounts(prefix, count) do
    ready(fn ->
      if not (is_integer(count) and count in 1..9999), do: raise("The count must be 1 to 9999.")
      password = password!()
      names = for i <- 1..count, do: prefix <> String.pad_leading(Integer.to_string(i), 4, "0")

      # Sequential on purpose: each account hashes its password with its own salt.
      {created, existing} = names |> Enum.map(&create_one(&1, password)) |> Enum.split_with(&(&1 == :created))
      {created, existing} = {length(created), length(existing)}

      IO.puts("Created #{created} accounts, #{existing} existed already: #{hd(names)} to #{List.last(names)}.")
    end)
  end

  @doc """
  Sets the stored map and position of characters from `name,map,x,y` lines on standard input (the load run). All or
  nothing; a character in the world overwrites the values when it is saved.
  """
  @spec place_characters(non_neg_integer()) :: :ok
  def place_characters(world \\ 0) do
    ready(fn ->
      lines =
        case IO.read(:stdio, :eof) do
          text when is_binary(text) ->
            text |> String.split("\n") |> Enum.map(&String.trim_trailing(&1, "\r")) |> Enum.with_index(1)

          _eof_or_error ->
            []
        end

      lines = Enum.reject(lines, fn {line, _n} -> line == "" end)
      if lines == [], do: raise("No placement lines given.")
      entries = Enum.map(lines, &placement!/1)

      case Persistence.place_characters(world, entries) do
        :ok -> IO.puts("Placed #{length(entries)} characters.")
        {:error, {:no_character, name}} -> raise "No character named #{name} in world #{world}; nothing was placed."
        {:error, :database} -> raise "The database failed; see the log line above."
      end
    end)
  end

  defp placement!({line, n}) do
    with [name, map, x, y] <- String.split(line, ","),
         true <- byte_size(name) in 1..20 and map =~ ~r/\A[A-Za-z0-9_-]{1,12}\z/,
         {x, ""} when x in 0..0x7FFFFFFF <- Integer.parse(x),
         {y, ""} when y in 0..0x7FFFFFFF <- Integer.parse(y) do
      %{name: name, map: map, x: x, y: y}
    else
      _ -> raise "Line #{n} is not <character name>,<map>,<x>,<y>: #{inspect(line)}"
    end
  end

  @doc """
  Sets the admin level (0 to 255) of a character, its name without regard to ASCII letter case. `world` is a
  configured world number; `:default` is allowed only with exactly one world configured. Only the database changes.
  """
  @spec set_admin_level(String.t(), integer(), non_neg_integer() | :default) :: :ok
  def set_admin_level(name, level, world \\ :default) do
    ready(fn ->
      if not (is_integer(level) and level in 0..255), do: raise("The level must be 0 to 255.")
      world = world!(world)

      case Persistence.set_admin_level(world, name, level) do
        :ok ->
          IO.puts(
            "Admin level of #{name} in world #{world} set to #{level}. Only the database was changed: " <>
              "a character in the world keeps its old level until its next login."
          )

        {:error, :unknown} ->
          raise "No character named #{name} in world #{world}."

        {:error, :database} ->
          raise "The database failed; see the log line above."
      end
    end)
  end

  defp world!(world) do
    # with_repo/1 loaded the same settings a moment before, so this cannot fail.
    {:ok, settings} = Settings.load(System.get_env())
    numbers = Enum.map(settings.world, & &1.number)

    case {world, numbers} do
      {:default, [number]} ->
        number

      {:default, _several} ->
        raise "More than one world is configured (#{Enum.join(numbers, ", ")}): name the world with --world <n>."

      {number, _} ->
        if number in numbers, do: number, else: raise("World #{number} is not configured.")
    end
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
