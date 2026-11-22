defmodule GameData.DataFile do
  @moduledoc """
  Finds a data file whatever the letter case of its name (ADR 0006, Consequences: the original runs on Windows, and
  the data has `linkfield01.shbd` for the map `Linkfield01`). The import never renames files.
  """

  @doc """
  The path of `rel` below `data_dir`. Per segment: an entry with exactly that name wins, else the first entry of the
  sorted listing that matches without regard to ASCII letter case, else the segment as written (the caller's read then
  fails with `:enoent`).
  """
  @spec path(Path.t(), Path.t()) :: Path.t()
  def path(data_dir, rel) do
    rel |> Path.split() |> Enum.reduce(data_dir, fn segment, dir -> Path.join(dir, entry(dir, segment)) end)
  end

  defp entry(dir, segment) do
    case File.ls(dir) do
      {:ok, names} ->
        lower = String.downcase(segment, :ascii)

        if segment in names,
          do: segment,
          else: names |> Enum.sort() |> Enum.find(segment, &(String.downcase(&1, :ascii) == lower))

      {:error, _reason} ->
        segment
    end
  end
end
