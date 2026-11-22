defmodule GameData do
  @moduledoc """
  Client and server data tables, loaded once at start-up (ADR 0006).

  Text columns are raw bytes in the client's legacy code page. They are never converted to UTF-8 and are not valid
  UTF-8 in general; code that logs or compares such text converts at that point.

  This module is the only one that touches `persistent_term` (the key is `{GameData, schema}`).
  """

  use Boundary,
    deps: [Clock, Random],
    exports: [
      Schema,
      SingleData,
      BadNameFilter,
      MapInfo,
      ItemInfo,
      HairInfo,
      HairColorInfo,
      FaceInfo,
      CharDefault,
      CharDefaultItem,
      CharDefaultSkill,
      CharDefaultQuest,
      CharDefaultShortcut,
      FieldList,
      ShineNpc,
      LinkTable,
      ChrCommon,
      MobInfo,
      TownPortal,
      SpamerPenalty,
      SpamerPenaltyRule,
      BlockData,
      DataFile
    ]

  require Logger

  @doc """
  SHA-256 (lower-case hex) of every file of the data directory: relative path, size and content, in path order.
  The default SQLite files `pinata.db*` at the top level are left out. Symlinked directories are not entered.
  """
  @spec digest(Path.t()) :: String.t()
  def digest(data_dir) do
    ctx =
      data_dir
      |> files("")
      |> Enum.reject(&String.starts_with?(&1, "pinata.db"))
      |> Enum.sort()
      |> Enum.reduce(:crypto.hash_init(:sha256), fn rel, ctx ->
        path = Path.join(data_dir, rel)
        ctx = :crypto.hash_update(ctx, [rel, 0, <<File.stat!(path).size::64>>])
        path |> File.stream!(1_048_576) |> Enum.reduce(ctx, &:crypto.hash_update(&2, &1))
      end)

    ctx |> :crypto.hash_final() |> Base.encode16(case: :lower)
  end

  # Relative paths of the regular files below dir/rel; the top-level filter of digest/1 matches the first segment.
  defp files(dir, rel) do
    dir
    |> Path.join(rel)
    |> File.ls!()
    |> Enum.flat_map(fn name ->
      child = Path.join(rel, name)
      path = Path.join(dir, child)

      cond do
        # not entered: a link loop would never end
        File.lstat!(path).type == :symlink and File.dir?(path) -> []
        File.dir?(path) -> files(dir, child)
        true -> [child]
      end
    end)
  end

  @doc """
  Loads the tables of `schemas` (and the tables they refer to) from `data_dir`. All problems come back together.

  With `strict_references: false` a dangling reference is a logged warning, not an error.
  """
  @spec load(Path.t(), [module()], strict_references: boolean()) :: :ok | {:error, [String.t(), ...]}
  def load(data_dir, schemas, opts) do
    if File.dir?(data_dir) do
      started = Clock.monotonic_time(:millisecond)

      with {:ok, tables, warnings} <- GameData.Loader.parse(data_dir, schemas, Keyword.fetch!(opts, :strict_references)) do
        store(tables, warnings, Clock.monotonic_time(:millisecond) - started)
      end
    else
      {:error,
       [
         "#{data_dir}: data directory not found. Create it from an original 9Data folder with the release command " <>
           "bin/pinata eval \"GameData.Release.import_data(~s(<9Data folder>), ~s(#{data_dir}))\" " <>
           "or, from a source checkout, with mix pinata.import_data <9Data folder> #{data_dir}"
       ]}
    end
  end

  defp store(tables, warnings, took) do
    Enum.each(warnings, &Logger.warning("GameData: #{&1}"))
    # A second load in the same VM (an application restart in tests) puts equal terms, which persistent_term ignores.
    Enum.each(tables, fn {schema, table} -> :persistent_term.put({GameData, schema}, table) end)
    log(tables, took)
  end

  defp log(tables, took) do
    rows = tables |> Map.values() |> Enum.map(&map_size(&1.rows)) |> Enum.sum()
    bytes = :erts_debug.flat_size(tables) * :erlang.system_info(:wordsize)
    Logger.info("GameData: #{map_size(tables)} tables, #{rows} rows, #{took} ms, #{bytes} bytes")
  end

  @doc "The row of `schema` with this key. Raises when the table was not loaded (the part forgot to declare it)."
  @spec fetch(module(), term()) :: {:ok, struct()} | :error
  def fetch(schema, key), do: Map.fetch(table(schema).rows, key)

  @doc "The rows of `schema` whose indexed `field` equals `value`, in file order. Raises when the table was not loaded."
  @spec lookup(module(), atom(), term()) :: [struct()]
  def lookup(schema, field, value), do: table(schema).indexes |> Map.fetch!(field) |> Map.get(value, [])

  @doc "The row that `field` of `row` refers to. `:error` when it dangles (possible with `data.strict_references = false`)."
  @spec follow(struct(), atom()) :: {:ok, struct()} | :error
  def follow(%schema{} = row, field) do
    target = Keyword.fetch!(schema.__schema__().references, field)
    fetch(target, Map.fetch!(row, field))
  end

  @doc "The plain field maps: the `FieldList` rows with `KQ = 0` and no sub-map range, in file order. Raises when the table was not loaded."
  @spec plain_field_maps() :: [GameData.FieldList.t()]
  def plain_field_maps do
    for {_row, %{kq: 0, sub_from: "-", sub_to: "-"} = field} <- Enum.sort(table(GameData.FieldList).rows), do: field
  end

  defp table(schema), do: :persistent_term.get({GameData, schema})
end
