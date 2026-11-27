defmodule Zone.Placement do
  @moduledoc """
  The arrival placement of a player: the nearest free cell around a wanted point, searched on a spiral of 31 rings.

  Original: `FieldMap::fm_Marking` FUN_00452fd0 (Z09 §5.7) with the rings of `DropLocationManager::dlm_Load`
  FUN_00460980 (`sdc_Setsixpoint` FUN_004607f0), scaled by `sdc_Getdelta` FUN_00460910 and walked by `dlm_next`
  FUN_00460c20, which puts one random point of each ring first (Z09 §11.7). The original also refuses a cell within
  `spacing` of another object (`so_collesioncheck`); that test is not built (milestone 4).
  """

  alias GameData.BlockData

  # {cos, sin} × 1024 at 0°, 60°, … 300°
  @unit [{1024, 0}, {512, 886}, {-512, 886}, {-1024, 0}, {-512, -886}, {512, -886}]

  # sdc_Setsixpoint(a, b)
  six = fn a, b ->
    for {c, s} <- @unit, do: {div(s * b, 1024) + div(c * a, 1024), div(c * b, 1024) - div(s * a, 1024)}
  end

  @rings (for r <- 1..31 do
            if rem(r, 2) == 1 do
              six.(div(r + 1, 2) * 1024, 0)
            else
              k = div(r, 2)
              Enum.flat_map(0..(k - 1), fn i -> six.(-(k - 1) * 512 + i * 1024, div((k + 1) * 0x4400, 20)) end)
            end
          end)

  @doc """
  The wanted point when its cell is free (no random draw), else the first free point of the spiral around it with
  offsets in units of `spacing` / 1024. `:error` when the wanted point or a spiral point lies outside the map, or
  when no point of the 31 rings is free.
  """
  @spec place(BlockData.t(), {integer(), integer()}, pos_integer()) :: {:ok, Zone.Grid.point()} | :error
  def place(%BlockData{} = b, {x, y} = point, spacing \\ 25) do
    size = {b.bytes_per_row * 50, div(b.rows * 50, 8)}

    cond do
      outside?(size, point) -> :error
      not BlockData.blocked?(b, x, y) -> {:ok, point}
      true -> search(b, size, point, spacing, @rings)
    end
  end

  defp search(_b, _size, _point, _spacing, []), do: :error

  defp search(b, size, {x, y} = point, spacing, [ring | rest]) do
    i = Random.uniform(length(ring)) - 1
    first = Enum.at(ring, i)
    ring = ring |> List.replace_at(i, hd(ring)) |> List.replace_at(0, first)

    result =
      Enum.find_value(ring, fn {dx, dy} ->
        candidate = {coord(x, dx, spacing), coord(y, dy, spacing)}

        cond do
          outside?(size, candidate) -> :error
          BlockData.blocked?(b, elem(candidate, 0), elem(candidate, 1)) -> nil
          true -> {:ok, candidate}
        end
      end)

    if result, do: result, else: search(b, size, point, spacing, rest)
  end

  # sdc_Getdelta: a coordinate that comes out as exactly 0 keeps the wanted one
  defp coord(v, d, spacing) do
    case v + div(d * spacing, 1024) do
      0 -> v
      c -> c
    end
  end

  # the original compares size < coordinate on unsigned values, so a negative one is outside too
  defp outside?({w, h}, {x, y}), do: x < 0 or y < 0 or x > w or y > h
end
