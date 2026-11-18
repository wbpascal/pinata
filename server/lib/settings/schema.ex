defmodule Settings.Schema do
  @moduledoc "The one schema of the settings file. `Settings.Doc` renders the reference from it."

  @port [type: {:in, 1..65_535}, type_doc: "integer 1 to 65535"]

  @schema [
    data_dir: [type: :string, default: "./data", doc: "The data directory."],
    public_host: [type: :string, default: "127.0.0.1", doc: "The address the client is told to connect to."],
    client_version_key: [
      type: :string,
      default: "20151116141627",
      doc: "The version key a client must send at login. The default is the key of the 2016 client."
    ],
    login: [
      type: :keyword_list,
      keys: [
        port: @port ++ [default: 9010, doc: "Client listener of the Login part."],
        auto_create_accounts: [
          type: :boolean,
          doc:
            "Create an account at the first login with an unknown name. " <>
              "Default: `true` when all parts run on this node and `cluster.nodes` is empty, else `false`."
        ]
      ]
    ],
    world_manager: [
      type: :keyword_list,
      keys: [port: @port ++ [default: 9110, doc: "Client listener of the WorldManager part."]]
    ],
    zone: [
      type: :keyword_list,
      keys: [port: @port ++ [default: 9210, doc: "Client listener of the Zone part, one per Zone node."]]
    ],
    world: [
      type:
        {:list,
         {:keyword_list,
          [
            number: [type: :non_neg_integer, default: 0, doc: "World number."],
            name: [type: :string, default: "INITIO", doc: "World name."]
          ]}},
      default: [[number: 0, name: "INITIO"]],
      doc: "The worlds, one `[[world]]` table each."
    ],
    database: [
      type: :keyword_list,
      keys: [
        url: [
          type: :string,
          doc:
            "Database URL: `sqlite:<path>` or `postgres://user:password@host/database`. Default: the SQLite file `pinata.db` in `data_dir`. The environment variable `DATABASE_URL` overrides it."
        ]
      ]
    ],
    cluster: [
      type: :keyword_list,
      keys: [
        nodes: [
          type: {:list, :string},
          default: [],
          doc: "Names of the other nodes (`name@host`). Empty means single-node mode."
        ]
      ]
    ],
    data: [
      type: :keyword_list,
      keys: [
        strict_references: [
          type: :boolean,
          default: true,
          doc: "Refuse to start when a data table refers to a row that does not exist."
        ]
      ]
    ]
  ]

  @doc "The NimbleOptions schema."
  @spec schema() :: keyword()
  def schema, do: @schema

  @doc "Checks a decoded TOML file. Returns the values with defaults filled in and every problem found."
  @spec validate(map()) :: {map(), [String.t()]}
  def validate(file), do: table(@schema, file, "")

  defp table(schema, map, path) do
    names = Enum.map(schema, fn {key, _spec} -> Atom.to_string(key) end)
    unknown = for name <- Map.keys(map), name not in names, do: "#{path}#{name}: unknown key"

    {values, problems} =
      Enum.map_reduce(schema, unknown, fn {key, spec}, problems ->
        {value, found} = entry(key, spec, Map.fetch(map, Atom.to_string(key)), path <> Atom.to_string(key))
        {{key, value}, problems ++ found}
      end)

    {for({key, {:ok, value}} <- values, into: %{}, do: {key, value}), problems}
  end

  defp entry(key, spec, given, path) do
    case {spec[:type], given} do
      {:keyword_list, {:ok, %{} = map}} ->
        ok(table(spec[:keys], map, path <> "."))

      {:keyword_list, :error} ->
        ok(table(spec[:keys], %{}, path <> "."))

      {{:list, {:keyword_list, keys}}, {:ok, [%{} | _] = rows}} ->
        rows(keys, rows, path)

      {{:list, {:keyword_list, _keys}}, :error} ->
        {{:ok, Enum.map(spec[:default], &Map.new/1)}, []}

      {{:list, {:keyword_list, _keys}}, {:ok, other}} ->
        {:error, ["#{path}: expected a list of tables, got: #{inspect(other)}"]}

      {:keyword_list, {:ok, other}} ->
        {:error, ["#{path}: expected a table, got: #{inspect(other)}"]}

      {_leaf, given} ->
        leaf(key, spec, given, path)
    end
  end

  defp ok({value, problems}), do: {{:ok, value}, problems}

  defp rows(keys, rows, path) do
    {values, problems} =
      rows
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {%{} = row, index} -> [table(keys, row, "#{path}[#{index}].")]
        {row, index} -> [{nil, ["#{path}[#{index}]: expected a table, got: #{inspect(row)}"]}]
      end)
      |> Enum.unzip()

    values = Enum.reject(values, &is_nil/1)

    {{:ok, values}, Enum.concat(problems)}
  end

  # A leaf goes through NimbleOptions on its own, so that one bad value does not hide the next.
  defp leaf(key, spec, given, path) do
    options =
      case given do
        {:ok, value} -> [{key, value}]
        :error -> []
      end

    case NimbleOptions.validate(options, [{key, spec}]) do
      {:ok, validated} -> {Keyword.fetch(validated, key), []}
      {:error, %NimbleOptions.ValidationError{message: message}} -> {:error, ["#{path}: #{message}"]}
    end
  end
end
