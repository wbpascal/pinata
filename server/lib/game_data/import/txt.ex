defmodule GameData.Import.Txt do
  @moduledoc """
  Reader of the `#`-command table format of the original TXT tables (`docs/pseudocode/zone/Z09-world.md` §28.6).

  Works on bytes: the files are in the client's legacy code page.
  """

  @type table :: %{name: binary(), header: [binary()], rows: [[binary()]]}

  @types ~w(index byte word dwrd dword)

  @doc "True when some line starts (after bytes up to 0x20) with `#table`, in any case."
  @spec table_file?(binary()) :: boolean()
  def table_file?(file), do: Regex.match?(~r/^[\x00-\x20]*#table/im, file)

  @doc "The tables of a file in file order, and warnings. All errors of the file are collected."
  @spec parse(binary()) :: {:ok, [table()], [String.t()]} | {:error, [String.t(), ...]}
  def parse(file) do
    init = %{delims: [], ignore: [], exchange: %{}, tables: %{}, order: [], current: nil, errors: [], warnings: []}

    state =
      file
      |> :binary.split("\n", [:global])
      |> Enum.with_index(1)
      |> Enum.reduce_while(init, fn {line, n}, state -> line(state, tokens(line, state.delims), n) end)

    state = finish(state)

    case state.errors do
      [] -> {:ok, Enum.map(Enum.reverse(state.order), &done(state.tables[&1])), Enum.reverse(state.warnings)}
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  defp done(table), do: %{name: table.name, header: table.header, rows: Enum.reverse(table.rows)}

  # A table must have names and types by the time the file ends.
  defp finish(state) do
    Enum.reduce(state.order, state, fn name, state ->
      table = state.tables[name]

      if table.header && table.types,
        do: state,
        else: error(state, table.line, "table #{name} has no #columnname or #columntype")
    end)
  end

  defp tokens(line, delims), do: tokens(line, delims, [])

  defp tokens(<<>>, _delims, acc), do: Enum.reverse(acc)

  defp tokens(<<c, rest::binary>> = line, delims, acc) do
    cond do
      separator?(c, delims) ->
        tokens(rest, delims, acc)

      # At the start of a token a `;` starts a comment; inside a token it is an ordinary byte.
      c == ?; ->
        Enum.reverse(acc)

      true ->
        size = token_size(line, delims, 0)
        <<token::binary-size(^size), rest::binary>> = line
        tokens(rest, delims, [token | acc])
    end
  end

  defp token_size(<<c, rest::binary>>, delims, n) do
    if separator?(c, delims), do: n, else: token_size(rest, delims, n + 1)
  end

  defp token_size(<<>>, _delims, n), do: n

  defp separator?(c, delims), do: c < 0x20 or c in delims

  defp line(state, [], _n), do: {:cont, state}

  defp line(state, [<<?#, command::binary>> | args], n) do
    command(state, ascii_downcase(command), args, n)
  end

  defp line(state, _tokens, n), do: {:cont, error(state, n, "# command expected")}

  defp command(state, "end", _args, _n), do: {:halt, state}

  defp command(state, "ignore", [arg | _], n),
    do: {:cont, with_char(state, arg, n, fn state, c -> %{state | ignore: [c | state.ignore]} end)}

  defp command(state, "delimiter", [arg | _], n),
    do: {:cont, with_char(state, arg, n, fn state, c -> %{state | delims: [c | state.delims]} end)}

  defp command(state, "exchange", [from, to | _], n) do
    state =
      with_char(state, from, n, fn state, f ->
        with_char(state, to, n, fn state, t -> %{state | exchange: Map.put(state.exchange, f, t)} end)
      end)

    {:cont, state}
  end

  defp command(state, "table", [], n), do: {:cont, %{error(state, n, "#table needs a name") | current: nil}}

  defp command(state, "table", [name | _], n) do
    name = clean(state, name)

    # Table names become file names, so a name that could leave the target directory is refused.
    if Regex.match?(~r/\A[A-Za-z0-9_][A-Za-z0-9_().-]*\z/, name),
      do: open_table(state, name, n),
      else: {:cont, %{error(state, n, "invalid table name #{inspect(name)}") | current: nil}}
  end

  defp command(state, "columntype", types, n) do
    types = Enum.map(types, &ascii_downcase/1)

    update_current(state, n, fn state, table ->
      cond do
        Enum.any?(types, &(not valid_type?(&1))) ->
          error(state, n, "bad column type in #columntype")

        table.header && length(table.header) != length(types) ->
          error(state, n, "#columntype has #{length(types)} types, #columnname has #{length(table.header)}")

        true ->
          put_table(state, %{table | types: Enum.map(types, &type_kind/1)})
      end
    end)
  end

  defp command(state, "columnname", names, n) do
    names = Enum.map(names, &clean(state, &1))

    update_current(state, n, fn state, table ->
      if table.types && length(table.types) != length(names) do
        error(state, n, "#columnname has #{length(names)} names, #columntype has #{length(table.types)}")
      else
        put_table(state, %{table | header: names})
      end
    end)
  end

  defp command(state, "record", values, n) do
    update_current(state, n, fn state, table -> record(state, table, values, n) end)
  end

  defp command(state, "recordin", [name | values], n) do
    name = clean(state, name)

    case Map.fetch(state.tables, name) do
      {:ok, table} -> {:cont, record(state, table, values, n)}
      :error -> {:cont, error(state, n, "#recordin: unknown table #{name}")}
    end
  end

  defp command(state, command, _args, n), do: {:cont, error(state, n, "undefined command ##{command}")}

  defp base(name), do: Regex.replace(~r/\.[0-9]+\z/, name, "")

  defp update_current(%{current: nil} = state, n, _fun), do: {:cont, error(state, n, "command before any #table")}
  defp update_current(state, _n, fun), do: {:cont, fun.(state, state.tables[state.current])}

  defp put_table(state, table), do: %{state | tables: Map.put(state.tables, table.name, table)}

  defp valid_type?(type), do: type in @types or Regex.match?(~r/\Astring\[[0-9]+\]\z/, type)
  defp type_kind(type), do: if(type == "index" or String.starts_with?(type, "string"), do: :text, else: :number)

  defp record(state, %{types: nil} = table, _values, n),
    do: error(state, n, "record in table #{table.name} before #columntype")

  defp record(state, %{header: nil} = table, _values, n),
    do: error(state, n, "record in table #{table.name} before #columnname")

  defp record(state, table, values, n) do
    values = Enum.map(values, &clean(state, &1))
    width = length(table.types)

    if length(values) < width do
      error(state, n, "expected #{width} values, got #{length(values)}")
    else
      {values, extra} = Enum.split(values, width)

      state =
        if Enum.all?(extra, &Regex.match?(~r/\A *\z/, &1)),
          do: state,
          else: warn(state, n, "#{length(extra)} extra values dropped")

      convert(state, table, values, n)
    end
  end

  defp convert(state, table, values, n) do
    results =
      Enum.zip_with([table.types, table.header, values], fn [type, name, value] -> number(type, name, value, n) end)

    case Enum.filter(results, &match?({:error, _}, &1)) do
      [] ->
        row = Enum.map(results, fn {:ok, value} -> value end)
        put_table(state, %{table | rows: [row | table.rows]})

      errors ->
        Enum.reduce(errors, state, fn {:error, message}, state -> error(state, n, message) end)
    end
  end

  defp number(:text, _name, value, _n), do: {:ok, value}

  defp number(:number, name, value, _n) do
    [_, trimmed] = Regex.run(~r/\A *(.*?) *\z/s, value)

    cond do
      Regex.match?(~r/\A-?[0-9]+\z/, trimmed) ->
        {:ok, trimmed}

      match = Regex.run(~r/\A(-?)0[xX]([0-9a-fA-F]+)\z/, trimmed) ->
        [_, sign, hex] = match
        {:ok, sign <> Integer.to_string(String.to_integer(hex, 16))}

      true ->
        {:error, "column #{inspect(name)}: not a number: #{inspect(value)}"}
    end
  end

  defp open_table(state, name, n) do
    count = Enum.count(state.order, fn existing -> base(existing) == name end)
    unique = unique_name(state, name, count)
    state = if count == 0, do: state, else: warn(state, n, "table #{name} is declared again, named #{unique}")
    table = %{name: unique, line: n, types: nil, header: nil, rows: []}
    {:cont, %{state | tables: Map.put(state.tables, unique, table), order: [unique | state.order], current: unique}}
  end

  # An explicit `T.2` earlier in the file must not be overwritten by the second `T`.
  defp unique_name(_state, name, 0), do: name

  defp unique_name(state, name, count) do
    candidate = "#{name}.#{count + 1}"
    if Map.has_key?(state.tables, candidate), do: unique_name(state, name, count + 1), else: candidate
  end

  # Value clean-up: drop the ignore bytes, then replace bytes through the exchange map.
  defp clean(state, value) do
    for <<b <- value>>, b not in state.ignore, into: <<>>, do: <<Map.get(state.exchange, b, b)>>
  end

  # One literal byte, or \dNNN (decimal), \oNNN (octal), \xNN (hex).
  defp with_char(state, arg, n, fun) do
    case char(arg) do
      {:ok, c} -> fun.(state, c)
      :error -> error(state, n, "bad character argument #{inspect(arg)}")
    end
  end

  defp char(<<?\\, kind, digits::binary>>) when kind in [?d, ?o, ?x] do
    base = %{?d => 10, ?o => 8, ?x => 16}[kind]

    case Integer.parse(digits, base) do
      {c, ""} when c in 0..255 -> {:ok, c}
      _other -> :error
    end
  end

  defp char(<<c>>), do: {:ok, c}
  defp char(_arg), do: :error

  defp ascii_downcase(value), do: for(<<c <- value>>, into: <<>>, do: <<if(c in ?A..?Z, do: c + 32, else: c)>>)

  defp error(state, n, message), do: %{state | errors: ["line #{n}: #{message}" | state.errors]}
  defp warn(state, n, message), do: %{state | warnings: ["line #{n}: #{message}" | state.warnings]}
end
