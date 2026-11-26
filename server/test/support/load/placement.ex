defmodule Load.Placement do
  @moduledoc """
  The placement list of a load run scenario (`docs/technical/load-run.md`, "Placement"): one `name,map,x,y` line per
  player on a random free cell. The caller seeds the process with `Random.seed/1` first.
  """

  @tries 1000

  @doc """
  The plain field maps of a data directory: the `FieldList` rows with `KQ = 0` and no sub-map range, in file order.
  """
  @spec maps(Path.t()) :: [String.t()]
  def maps(data_dir) do
    path = Path.join(data_dir, "tables/World/Field/FieldList.csv")

    with {:ok, file} <- File.read(path),
         {:ok, header, rows} <- GameData.Csv.decode(file) do
      [map, from, to, kq] = Enum.map(~w(MapIDClient SubFrom SubTo KQ), &column!(header, &1, path))

      for row <- rows,
          Enum.at(row, kq) == "0",
          Enum.at(row, from) == "-",
          Enum.at(row, to) == "-",
          do: Enum.at(row, map)
    else
      _error -> raise "#{data_dir} is not a data directory; make one with mix pinata.import_data"
    end
  end

  defp column!(header, name, path) do
    Enum.find_index(header, &(&1 == name)) || raise "#{path} has no column #{name}"
  end

  @doc "One `name,map,x,y` line per name, in order. Crowd: all on `crowd_map`; World: the maps round-robin."
  @spec list(:world | :crowd, [String.t()], Path.t(), String.t(), [String.t()]) :: [String.t()]
  def list(scenario, names, data_dir, crowd_map, maps) do
    if scenario == :crowd and crowd_map not in maps, do: raise("#{crowd_map} is not a plain field map")

    {lines, _blocks} =
      names
      |> Enum.with_index()
      |> Enum.map_reduce(%{}, fn {name, i}, blocks ->
        map = if scenario == :crowd, do: crowd_map, else: Enum.at(maps, rem(i, length(maps)))
        blocks = Map.put_new_lazy(blocks, map, fn -> block!(data_dir, map) end)
        {x, y} = free_point(blocks[map], map, @tries)
        {"#{name},#{map},#{x},#{y}", blocks}
      end)

    lines
  end

  @doc "The block data of `maps`, by map name."
  @spec blocks(Path.t(), [String.t()]) :: %{String.t() => GameData.BlockData.t()}
  def blocks(data_dir, maps), do: Map.new(maps, &{&1, block!(data_dir, &1)})

  defp block!(data_dir, map) do
    case GameData.BlockData.load(data_dir, map) do
      {:ok, block} -> block
      {:error, message} -> raise message
    end
  end

  defp free_point(_block, map, 0), do: raise("no free cell found on #{map} in #{@tries} draws")

  defp free_point(block, map, tries) do
    cx = Random.uniform(block.bytes_per_row * 8) - 1
    cy = Random.uniform(block.rows) - 1
    # the centre of the 6.25-unit cell
    {x, y} = {div((2 * cx + 1) * 25, 8), div((2 * cy + 1) * 25, 8)}
    if GameData.BlockData.blocked?(block, x, y), do: free_point(block, map, tries - 1), else: {x, y}
  end
end
