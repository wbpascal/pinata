defmodule Settings do
  @moduledoc "The settings of this node: one TOML file, checked against `Settings.Schema`."

  use Boundary, deps: []

  alias Settings.Schema

  @parts [:login, :world_manager, :zone]

  @type part :: :login | :world_manager | :zone
  @type world :: %{number: non_neg_integer(), name: String.t()}
  @type t :: %{
          parts: [part()],
          data_dir: String.t(),
          public_host: String.t(),
          client_version_key: String.t(),
          login: %{port: pos_integer(), auto_create_accounts: boolean()},
          world_manager: %{port: pos_integer()},
          zone: %{port: pos_integer()},
          world: [world()],
          database: %{url: String.t()},
          cluster: %{nodes: [String.t()]},
          data: %{strict_references: boolean()}
        }

  @doc "Reads and checks the settings. `env` is the process environment (`System.get_env/0`)."
  @spec load(%{optional(String.t()) => String.t()}) :: {:ok, t()} | {:error, [String.t(), ...]}
  def load(env) do
    {file, file_problems} = read_file(env)
    {values, value_problems} = Schema.validate(file)
    {parts, part_problems} = parts(env)

    case file_problems ++ value_problems ++ part_problems do
      [] -> {:ok, values |> Map.put(:parts, parts) |> derive(env)}
      [_ | _] = problems -> {:error, problems}
    end
  end

  # Only the default path may be missing: a path the administrator named must exist.
  defp read_file(env) do
    path = Map.get(env, "FIESTA_CONFIG", "fiesta.toml")

    case File.read(path) do
      {:ok, text} -> decode(path, text)
      {:error, :enoent} when not is_map_key(env, "FIESTA_CONFIG") -> {%{}, []}
      {:error, reason} -> {%{}, ["#{path}: cannot read the settings file (#{:file.format_error(reason)})"]}
    end
  end

  defp decode(path, text) do
    case Toml.decode(text) do
      {:ok, file} -> {file, []}
      {:error, {:invalid_toml, message}} -> {%{}, ["#{path}: not valid TOML (#{message})"]}
    end
  end

  defp parts(env) do
    names = env |> Map.get("FIESTA_PARTS", "login,world_manager,zone") |> String.split(",", trim: true)
    known = Map.new(@parts, &{Atom.to_string(&1), &1})
    unknown = Enum.reject(names, &is_map_key(known, &1))

    {for(part <- @parts, Atom.to_string(part) in names, do: part),
     Enum.map(unknown, &"FIESTA_PARTS: unknown part #{inspect(&1)}, expected login, world_manager or zone")}
  end

  defp derive(settings, env) do
    single_node? = settings.parts == @parts and settings.cluster.nodes == []
    default_url = "sqlite:" <> Path.join(settings.data_dir, "pinata.db")

    settings
    |> Map.update!(:login, &Map.put_new(&1, :auto_create_accounts, single_node?))
    |> Map.update!(:database, &Map.put_new(&1, :url, default_url))
    |> then(fn settings ->
      case env do
        %{"DATABASE_URL" => url} -> put_in(settings.database.url, url)
        %{} -> settings
      end
    end)
  end
end
