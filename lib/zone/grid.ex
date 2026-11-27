defmodule Zone.Grid do
  @moduledoc """
  The uniform grid of a map instance (`docs/technical/sight.md`): object handles by square cell, so a range query
  reads only the cells around its centre. The cell size is the map's sight radius, so a query at the sight radius
  reads 3 × 3 cells. `query/4` is the only function that reads the cells.

  The result is sorted into the original's order (`walk_order/3`): the original walks its y-sorted object list from
  the centre object first towards smaller y, then towards larger y (`so_AllOfRangeNomal` @ FUN_0054c900,
  `so_AllInMapNomal` @ FUN_0054be00; confirmed by the 0x1C09 lists of capture `idle_in_world`). Objects with equal y
  are ordered by handle: the original's order of equal keys depends on the history of its list and cannot be
  reproduced.
  """

  @type handle :: non_neg_integer()
  @type point :: {x :: non_neg_integer(), y :: non_neg_integer()}
  @enforce_keys [:cell]
  defstruct [:cell, cells: %{}]
  @type t :: %__MODULE__{cell: pos_integer(), cells: %{{integer(), integer()} => %{handle() => point()}}}

  @doc "An empty grid with square cells of the given size."
  @spec new(pos_integer()) :: t()
  def new(cell) when is_integer(cell) and cell > 0, do: %__MODULE__{cell: cell}

  @doc "Puts a handle at a point."
  @spec put(t(), handle(), point()) :: t()
  def put(%__MODULE__{} = grid, handle, {_x, _y} = point) do
    cells = Map.update(grid.cells, key(grid, point), %{handle => point}, &Map.put(&1, handle, point))
    %{grid | cells: cells}
  end

  @doc "Removes a handle from the point it was put at; a cell that gets empty is dropped."
  @spec delete(t(), handle(), point()) :: t()
  def delete(%__MODULE__{} = grid, handle, point) do
    key = key(grid, point)

    case grid.cells do
      %{^key => entries} ->
        entries = Map.delete(entries, handle)
        cells = if entries == %{}, do: Map.delete(grid.cells, key), else: Map.put(grid.cells, key, entries)
        %{grid | cells: cells}

      %{} ->
        grid
    end
  end

  @doc "The handles other than `from` with `dist² < radius²` around the point, in walk order."
  @spec query(t(), point(), non_neg_integer(), handle()) :: [handle()]
  def query(%__MODULE__{cell: cell, cells: cells}, {x, y} = centre, radius, from) do
    r2 = radius * radius

    found =
      for cx <- Integer.floor_div(x - radius, cell)..Integer.floor_div(x + radius, cell),
          cy <- Integer.floor_div(y - radius, cell)..Integer.floor_div(y + radius, cell),
          {handle, {ex, ey} = point} <- Map.get(cells, {cx, cy}, %{}),
          handle != from,
          (ex - x) * (ex - x) + (ey - y) * (ey - y) < r2,
          do: {handle, point}

    walk_order(found, centre, from)
  end

  @doc """
  The original's walk order: with the key `{y, -handle}`, first the entries below the centre key `{centre y, -from}`
  in descending order, then the entries above it in ascending order. Equal y lie in descending handle order (the
  NPCs at y 7862 of RouVal01 in three captures: the original's list keeps a later insert before equal keys).
  """
  @spec walk_order([{handle(), point()}], point(), handle()) :: [handle()]
  def walk_order(entries, {_x, y}, from) do
    centre = {y, -from}
    keys = for {handle, {_ex, ey}} <- entries, do: {ey, -handle}
    {below, above} = keys |> Enum.reject(&(&1 == centre)) |> Enum.split_with(&(&1 < centre))
    for {_y, key} <- Enum.sort(below, :desc) ++ Enum.sort(above), do: -key
  end

  defp key(%__MODULE__{cell: cell}, {x, y}), do: {div(x, cell), div(y, cell)}
end
