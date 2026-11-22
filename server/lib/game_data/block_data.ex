defmodule GameData.BlockData do
  @moduledoc """
  Block data of one map: `BlockInfo/<Map>.shbd` with `BlockInfo/<Map>.shab` OR-ed in (only the merged bitmap is kept;
  `.sbi` and `.aid` are not read). A set bit is a blocked cell of 6.25 x 6.25 units. Both files are
  `u32 bytes_per_row, u32 rows` (little-endian) followed by `rows * bytes_per_row` bytes.

  Nothing is cached here and no `Logger` is called; the caller keeps the struct and logs.
  """

  import Bitwise

  @enforce_keys [:bytes_per_row, :rows, :bits]
  defstruct @enforce_keys

  @type t :: %__MODULE__{bytes_per_row: pos_integer(), rows: pos_integer(), bits: binary()}
  @type point :: {integer(), integer()}

  @doc "Checks that the `.shbd` of the map exists and has a well-formed header (for the node start). The `.shab` is not looked at. A name that is not made of letters, digits, `_` and `-` is refused with an error before any file is touched."
  @spec check(Path.t(), binary()) :: :ok | {:error, String.t()}
  def check(data_dir, map_name), do: with(:ok <- map_name(map_name), do: do_check(data_dir, map_name))

  defp do_check(data_dir, map_name) do
    path = file_path(data_dir, map_name, ".shbd")
    file = name(path)

    with {:ok, %{size: size}} <- File.stat(path) |> read_error(file),
         {:ok, head} <- File.open(path, [:read, :binary], &IO.binread(&1, 8)) |> read_error(file),
         {:ok, _dims} <- header(head, size, file) do
      :ok
    else
      {:error, message} -> {:error, message}
    end
  end

  @doc "Loads the block data of the map: the `.shbd` with the `.shab` OR-ed in; a missing `.shab` is not an error. A name that is not made of letters, digits, `_` and `-` is refused with an error before any file is touched."
  @spec load(Path.t(), binary()) :: {:ok, t()} | {:error, String.t()}
  def load(data_dir, map_name), do: with(:ok <- map_name(map_name), do: do_load(data_dir, map_name))

  defp do_load(data_dir, map_name) do
    path = file_path(data_dir, map_name, ".shbd")
    file = name(path)

    with {:ok, binary} <- File.read(path) |> read_error(file),
         {:ok, {bpr, rows} = dims} <- header(binary, byte_size(binary), file),
         {:ok, bits} <-
           add_attack(binary_part(binary, 8, bpr * rows), dims, file, file_path(data_dir, map_name, ".shab")) do
      {:ok, %__MODULE__{bytes_per_row: bpr, rows: rows, bits: bits}}
    end
  end

  defp add_attack(bits, dims, shbd_file, path) do
    file = name(path)

    case File.read(path) do
      {:error, :enoent} ->
        {:ok, bits}

      other ->
        with {:ok, binary} <- read_error(other, file),
             {:ok, shab_dims} <- header(binary, byte_size(binary), file),
             :ok <- same_dims(shab_dims, dims, file, shbd_file) do
          {:ok, merge(bits, binary_part(binary, 8, byte_size(bits)), [])}
        end
    end
  end

  # 64 bits at a time; the sizes are bytes_per_row * rows, so a tail of single bytes is possible
  defp merge(<<x::64, a::binary>>, <<y::64, b::binary>>, acc), do: merge(a, b, [<<Bitwise.bor(x, y)::64>> | acc])
  defp merge(<<x, a::binary>>, <<y, b::binary>>, acc), do: merge(a, b, [<<Bitwise.bor(x, y)>> | acc])
  defp merge(<<>>, <<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp same_dims(dims, dims, _file, _other), do: :ok

  defp same_dims({a, b}, {c, d}, file, other),
    do: {:error, "#{file}: damaged block data (header #{a} x #{b}, #{other} has #{c} x #{d})"}

  defp header(<<bpr::little-32, rows::little-32, _rest::binary>>, size, _file)
       when bpr > 0 and rows > 0 and size == 8 + bpr * rows,
       do: {:ok, {bpr, rows}}

  defp header(<<bpr::little-32, rows::little-32, _rest::binary>>, size, file),
    do: {:error, "#{file}: damaged block data (header #{bpr} x #{rows}, #{size} bytes)"}

  defp header(_short, size, file), do: {:error, "#{file}: damaged block data (#{size} bytes, no header)"}

  defp read_error({:error, :enoent}, file), do: {:error, "#{file}: file not found"}
  defp read_error({:error, reason}, file), do: {:error, "#{file}: #{:file.format_error(reason)}"}
  defp read_error({:ok, value}, _file), do: {:ok, value}

  defp name(path), do: "BlockInfo/" <> Path.basename(path)

  # Every map name is checked here before file_path/3 makes it a path. One segment of letters, digits, `_` and `-`: no `..`, no separator, no
  # NUL, no drive, so a name from a client cannot leave BlockInfo/. Every name of the 2016 tables passes.
  defp map_name(name) do
    if name =~ ~r/\A[A-Za-z0-9_-]+\z/,
      do: :ok,
      else: {:error, "BlockInfo: #{inspect(name)} is not a map name"}
  end

  # The name on disk when found, the asked name when not.
  defp file_path(data_dir, map_name, ext), do: GameData.DataFile.path(data_dir, "BlockInfo/" <> map_name <> ext)

  # Cell of a coordinate. mbi_IsMoveBlock FUN_0049df70: u32 arithmetic of the original, so a negative or huge
  # coordinate lands outside the map.
  defp cell(v), do: div(band(v * 8, 0xFFFFFFFF), 50)

  defp inside?(%__MODULE__{bytes_per_row: bpr, rows: rows}, cx, cy),
    do: cx >= 0 and cy >= 0 and cx < bpr * 8 and cy < rows

  defp bit(%__MODULE__{bytes_per_row: bpr, bits: bits} = b, cx, cy) do
    inside?(b, cx, cy) and (:binary.at(bits, bpr * cy + (cx >>> 3)) &&& 1 <<< (cx &&& 7)) != 0
  end

  @doc "True when the cell of (`x`, `y`) is blocked; outside the map counts as blocked. Original: `mbi_IsMoveBlock` FUN_0049df70."
  @spec blocked?(t(), integer(), integer()) :: boolean()
  def blocked?(%__MODULE__{} = b, x, y) do
    cx = cell(x)
    cy = cell(y)
    not inside?(b, cx, cy) or bit(b, cx, cy)
  end

  @doc """
  True when any of the 3 x 3 cells around (`x`, `y`) is inside the map and free.
  Original: `mbi_OccupCellCheck` FUN_0049e230 with r = 1 (Z02 CellFree).
  """
  @spec free_cell?(t(), integer(), integer()) :: boolean()
  def free_cell?(%__MODULE__{} = b, x, y) do
    cx = cell(x)
    cy = cell(y)
    Enum.any?(for(i <- -1..1, j <- -1..1, do: {cx + i, cy + j}), fn {a, c} -> inside?(b, a, c) and not bit(b, a, c) end)
  end

  @doc """
  True when `need` consecutive inner steps of the line are blocked; the end points are never tested.
  Original: `sp_MovePathBlockCheck` FUN_00456a70 (Z02 LineBlocked). The original interpolates with x87 floats; floats
  and `round/1` here differ only on an exact .5 tie, by one unit (a cell is 6.25 units).
  """
  @spec line_blocked?(t(), point(), point(), pos_integer()) :: boolean()
  def line_blocked?(%__MODULE__{} = b, from, to, need \\ 2) do
    steps = steps(from, to)
    run(b, steps, 0, need)
  end

  defp steps({ax, ay} = from, {bx, by} = to) when (ax - bx) * (ax - bx) <= (ay - by) * (ay - by) do
    if ay == by do
      []
    else
      {{x0, y0}, {x1, y1}} = if ay < by, do: {from, to}, else: {to, from}
      for y <- (y0 + 1)..(y1 - 1)//1, do: {round((y - y0) * ((x1 - x0) / (y1 - y0)) + x0), y}
    end
  end

  defp steps({ax, _ay} = from, {bx, _by} = to) do
    {{x0, y0}, {x1, y1}} = if ax < bx, do: {from, to}, else: {to, from}
    for x <- (x0 + 1)..(x1 - 1)//1, do: {x, round((x - x0) * ((y1 - y0) / (x1 - x0)) + y0)}
  end

  defp run(b, steps, count, need) do
    Enum.reduce_while(steps, count, fn {x, y}, n ->
      n = if step_blocked?(b, x, y), do: n + 1, else: 0
      if n >= need, do: {:halt, :blocked}, else: {:cont, n}
    end) == :blocked
  end

  defp step_blocked?(b, x, y) do
    not free_cell?(b, x, y) and blocked?(b, x + 10, y) and blocked?(b, x - 10, y) and blocked?(b, x, y + 10) and
      blocked?(b, x, y - 10)
  end
end
