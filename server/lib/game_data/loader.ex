defmodule GameData.Loader do
  @moduledoc """
  Parses and checks the tables of a data directory. Pure: no global storage, no logging (that is `GameData.load/3`).

  Every problem of every table is collected, so an administrator fixes them in one go.
  """

  @type table :: %{rows: %{term() => struct()}, indexes: %{atom() => %{term() => [struct()]}}}

  @spec parse(Path.t(), [module()], boolean()) ::
          {:ok, %{module() => table()}, [String.t()]} | {:error, [String.t(), ...]}
  def parse(data_dir, schemas, strict_references?) do
    all = expand(schemas, [])
    results = Enum.map(all, fn schema -> {schema, build(data_dir, schema)} end)
    built = for {schema, {:ok, table}} <- results, into: %{}, do: {schema, table}
    problems = Enum.flat_map(results, fn {_schema, result} -> elem_problems(result) end)
    references = Enum.flat_map(all, &reference_problems(&1, built))
    {reference_errors, warnings} = if strict_references?, do: {references, []}, else: {[], references}

    case problems ++ reference_errors do
      [] -> {:ok, built, warnings}
      all_problems -> {:error, all_problems}
    end
  end

  defp elem_problems({:error, problems}), do: problems
  defp elem_problems({:ok, _table}), do: []

  defp expand([], seen), do: Enum.reverse(seen)

  defp expand([schema | rest], seen) do
    if schema in seen do
      expand(rest, seen)
    else
      targets = Enum.map(schema.__schema__().references, fn {_field, target} -> target end)
      expand(rest ++ targets, [schema | seen])
    end
  end

  defp build(data_dir, schema) do
    spec = schema.__schema__()
    {format, rel} = spec.source

    case File.read(GameData.DataFile.path(data_dir, rel)) do
      {:error, :enoent} -> {:error, ["#{rel}: file not found"]}
      {:error, reason} -> {:error, ["#{rel}: #{:file.format_error(reason)}"]}
      {:ok, binary} -> binary |> read(format) |> table(schema, spec, rel)
    end
  end

  defp read(binary, :shn) do
    with {:ok, columns, rows} <- GameData.Shn.decode(binary) do
      {:ok, Enum.map(columns, & &1.name), Enum.map(columns, & &1.kind), rows}
    end
  end

  defp read(binary, :csv) do
    with {:ok, header, rows} <- GameData.Csv.decode(binary), do: {:ok, header, nil, rows}
  end

  defp table({:error, message}, _schema, _spec, rel), do: {:error, ["#{rel}: #{message}"]}

  defp table({:ok, header, kinds, rows}, schema, spec, rel) do
    positions = header |> Enum.with_index() |> Map.new()
    {columns, problems} = resolve(spec.columns, positions, kinds, rel)

    if problems == [] do
      build_rows(rows, schema, spec, columns, length(header), rel)
    else
      {:error, problems}
    end
  end

  # -> {[{field, position, type}], problems}
  defp resolve(columns, positions, kinds, rel) do
    {found, problems} =
      Enum.reduce(columns, {[], []}, fn {field, {name, type}}, {found, problems} ->
        case resolve_column(Map.fetch(positions, name), kinds, type) do
          {:ok, pos} -> {[{field, pos, type} | found], problems}
          {:error, text} -> {found, ["#{rel}: column #{inspect(name)}#{text}" | problems]}
        end
      end)

    {Enum.reverse(found), Enum.reverse(problems)}
  end

  defp resolve_column(:error, _kinds, _type), do: {:error, " is missing"}

  defp resolve_column({:ok, pos}, kinds, type) do
    case kind_problem(kinds && Enum.at(kinds, pos), type) do
      nil -> {:ok, pos}
      text -> {:error, ": " <> text}
    end
  end

  defp kind_problem(nil, _type), do: nil
  defp kind_problem(kind, kind), do: nil
  defp kind_problem(:string, :integer), do: "expected an integer, the file has a string column"
  defp kind_problem(_kind, :integer), do: "expected an integer, the file has no integer column"
  defp kind_problem(_kind, :string), do: "expected a string, the file has a non-string column"

  defp build_rows(rows, schema, spec, columns, width, rel) do
    {_n, keyed, ordered, problems} =
      Enum.reduce(rows, {1, %{}, [], []}, fn row, {n, keyed, ordered, problems} ->
        {keyed, ordered, problems} =
          add_row(build_row(spec, row, columns, width, n, rel), {schema, spec, n, rel}, {keyed, ordered, problems})

        {n + 1, keyed, ordered, problems}
      end)

    case problems do
      [] ->
        ordered = Enum.reverse(ordered)
        indexes = Map.new(spec.indexes, fn field -> {field, Enum.group_by(ordered, &Map.fetch!(&1, field))} end)
        {:ok, %{rows: keyed, indexes: indexes}}

      _problems ->
        {:error, Enum.reverse(problems)}
    end
  end

  defp add_row({:error, row_problems}, _context, {keyed, ordered, problems}),
    do: {keyed, ordered, Enum.reverse(row_problems, problems)}

  defp add_row({:ok, fields}, {schema, spec, n, rel}, {keyed, ordered, problems}) do
    key = if spec.key == :row, do: n, else: Map.fetch!(fields, spec.key)

    if Map.has_key?(keyed, key) do
      {keyed, ordered, ["#{rel} row #{n}: duplicate key #{inspect(key)}" | problems]}
    else
      row = struct!(schema, fields)
      {Map.put(keyed, key, row), [row | ordered], problems}
    end
  end

  defp build_row(_spec, row, _columns, width, n, rel) when length(row) != width,
    do: {:error, ["#{rel} row #{n}: expected #{width} cells, got #{length(row)}"]}

  defp build_row(spec, row, columns, _width, n, rel) do
    cells = List.to_tuple(row)
    names = spec.columns

    {fields, problems} =
      Enum.reduce(columns, {%{}, []}, fn {field, pos, type}, {fields, problems} ->
        case value(elem(cells, pos), type) do
          {:ok, value} ->
            {Map.put(fields, field, value), problems}

          :error ->
            {name, _type} = Keyword.fetch!(names, field)
            text = "#{rel} row #{n}: column #{inspect(name)}: expected an integer, got #{inspect(elem(cells, pos))}"
            {fields, [text | problems]}
        end
      end)

    if problems == [], do: {:ok, fields}, else: {:error, Enum.reverse(problems)}
  end

  defp value(cell, :integer) when is_integer(cell), do: {:ok, cell}

  defp value(cell, :integer) do
    if Regex.match?(~r/\A-?[0-9]+\z/, cell), do: {:ok, String.to_integer(cell)}, else: :error
  end

  # A copy, or each small string would keep the whole file binary alive in the stored table.
  defp value(cell, :string), do: {:ok, :binary.copy(cell)}

  defp reference_problems(schema, built) do
    case Map.fetch(built, schema) do
      {:ok, table} -> reference_problems(schema, schema.__schema__(), table, built)
      :error -> []
    end
  end

  defp reference_problems(_schema, spec, table, built) do
    {_format, source} = spec.source

    for {field, target} <- spec.references,
        {:ok, target_table} <- [Map.fetch(built, target)],
        {key, row} <- Enum.sort(table.rows),
        value = Map.fetch!(row, field),
        not Map.has_key?(target_table.rows, value) do
      {name, _type} = Keyword.fetch!(spec.columns, field)
      {_format, target_source} = target.__schema__().source

      "#{source} row key #{inspect(key)}: column #{inspect(name)} refers to #{inspect(value)}, which is not in #{target_source}"
    end
  end
end
