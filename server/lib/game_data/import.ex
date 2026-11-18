defmodule GameData.Import do
  @moduledoc """
  Turns an original `9Data` folder into a data directory (ADR 0005). See `docs/technical/game-data.md` for the rules.
  """

  alias GameData.Import.{Csl, Txt}

  @type report :: %{
          copied: non_neg_integer(),
          tables: non_neg_integer(),
          skipped: [String.t()],
          warnings: [String.t()]
        }

  @table_dirs ~w(World MobRegen MobRoam MobAttackSequence NPCItemList MobSetting)
  @scripts ~w(DefaultCharacterData.txt TutorialCharacterData.txt)

  @spec run(Path.t(), Path.t()) :: {:ok, report()} | {:error, [String.t(), ...]}
  def run(source, target) do
    shine = Path.join(source, "Shine")

    cond do
      not File.dir?(shine) -> {:error, ["#{source}: no Shine folder, expected an original 9Data folder"]}
      not empty?(target) -> {:error, ["#{target}: exists and is not empty"]}
      true -> import_files(shine, target)
    end
  end

  defp empty?(target), do: File.ls(target) in [{:ok, []}, {:error, :enoent}]

  defp import_files(shine, target) do
    files = shine |> Path.join("**/*") |> Path.wildcard(match_dot: true) |> Enum.filter(&File.regular?/1) |> Enum.sort()
    items = Enum.map(files, fn file -> {file, Path.relative_to(file, shine)} end)
    results = Enum.map(items, fn {file, rel} -> {rel, convert(file, rel)} end)

    case for({rel, {:error, errors}} <- results, error <- errors, do: "#{rel}: #{error}") do
      [] ->
        writes =
          Enum.flat_map(results, fn
            {_rel, {:ok, writes, _warnings}} -> writes
            {_rel, :skip} -> []
          end)

        write(writes, target)

        warnings = for {rel, {:ok, _writes, warnings}} <- results, warning <- warnings, do: "#{rel}: #{warning}"
        skipped = for {rel, :skip} <- results, do: rel
        tables = Enum.count(writes, &match?({:csv, _, _, _}, &1))
        {:ok, %{copied: length(writes) - tables, tables: tables, skipped: skipped, warnings: warnings}}

      errors ->
        {:error, errors}
    end
  end

  defp write(writes, target) do
    Enum.each(writes, fn write ->
      dest = Path.join(target, elem(write, 1))
      File.mkdir_p!(Path.dirname(dest))

      case write do
        {:csv, _dest, header, rows} -> File.write!(dest, GameData.Csv.encode(header, rows))
        {:copy, _dest, file} -> File.cp!(file, dest)
      end
    end)
  end

  # -> :skip | {:ok, writes, warnings} | {:error, errors}
  defp convert(file, rel) do
    [first | _] = Path.split(rel)

    case plan(rel, first, rel |> Path.extname() |> String.downcase()) do
      :skip -> :skip
      :script -> script(file, rel)
      :table -> table(file, rel)
      {:copy, dest} -> copy(file, dest)
    end
  end

  defp plan("World/ExpRecalculation.txt", _first, _ext), do: :skip
  defp plan(rel, _first, _ext) when rel in @scripts, do: :script
  defp plan(_rel, first, ".txt") when first in @table_dirs, do: :table
  defp plan(rel, first, _ext) when first in ~w(LuaScript ScenarioBookShelf), do: {:copy, rel}
  defp plan(rel, "Script", ext) when ext != ".xls", do: {:copy, rel}
  defp plan(rel, "BlockInfo", ext) when ext in ~w(.shbd .aid .sbi .shab), do: {:copy, rel}
  defp plan(rel, "AreaBMP", ".bmp"), do: {:copy, rel}
  defp plan(rel, _first, ".shn"), do: if(Path.dirname(rel) in [".", "View"], do: {:copy, "shn/" <> rel}, else: :skip)
  defp plan(_rel, _first, _ext), do: :skip

  defp copy(file, dest), do: {:ok, [{:copy, dest, file}], []}

  defp script(file, rel) do
    base = Path.rootname(rel)

    with {:ok, tables} <- file |> File.read!() |> Csl.parse() do
      {:ok, Enum.map(tables, &{:csv, "tables/#{base}/#{&1.name}.csv", &1.header, &1.rows}), []}
    end
  end

  defp table(file, rel) do
    binary = File.read!(file)
    base = Path.rootname(rel)

    if Txt.table_file?(binary) do
      with {:ok, tables, warnings} <- Txt.parse(binary), do: {:ok, csv_writes(tables, base), warnings}
    else
      {:ok, [{:copy, "tables/" <> rel, file}], ["not a table, copied unchanged"]}
    end
  end

  defp csv_writes([one], base), do: [{:csv, "tables/#{base}.csv", one.header, one.rows}]
  defp csv_writes(many, base), do: Enum.map(many, &{:csv, "tables/#{base}/#{&1.name}.csv", &1.header, &1.rows})
end
