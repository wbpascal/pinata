defmodule GameData.Import.Csl do
  @moduledoc """
  Reader of the `#DEFINE` scripts `DefaultCharacterData.txt` and `TutorialCharacterData.txt`. The scripts have no
  column names; they come from a fixed map of this module.
  """

  @headers %{
    "CHARACTER" => ~w(Class StartMap StartX StartY HP SP HPStone SPStone Money InitLV InitEXP),
    "TUTORIAL_CHARACTER" => ~w(Class StartMap StartX StartY HP SP HPStone SPStone Money),
    "ITEM" => ~w(Class ItemID Lot),
    "DEFAULT_ITEM" => ~w(Class ItemID Lot),
    "TUTORIAL_ITEM" => ~w(Class ItemID Lot),
    "SKILL" => ~w(Class SkillID),
    "QUEST" => ~w(Class QuestID),
    "MAXSHAPE" => ~w(Class MaxFace MaxHair MaxHairColor),
    "SHORTCUT" => ~w(Class SlotNo CodeNo Value)
  }

  @doc "One table per `#DEFINE` in file order, also when it has no rows."
  @spec parse(binary()) :: {:ok, [GameData.Import.Txt.table()]} | {:error, [String.t(), ...]}
  def parse(file) do
    init = %{open: nil, defined: %{}, order: [], rows: %{}, errors: []}

    state =
      file
      |> :binary.split("\n", [:global])
      |> Enum.with_index(1)
      |> Enum.reduce_while(init, fn {line, n}, state -> line(state, line |> cut() |> tokens([]), n) end)

    case state do
      %{errors: [], open: nil} -> {:ok, Enum.map(Enum.reverse(state.order), &table(state, &1))}
      %{errors: [], open: {name, _types, n}} -> {:error, ["line #{n}: #DEFINE #{name} has no #ENDDEFINE"]}
      %{errors: errors} -> {:error, Enum.reverse(errors)}
    end
  end

  defp table(state, name) do
    %{name: name, header: Map.fetch!(@headers, name), rows: state.rows |> Map.fetch!(name) |> Enum.reverse()}
  end

  defp cut(line), do: hd(:binary.split(line, ";"))

  defp tokens(<<>>, acc), do: Enum.reverse(acc)
  defp tokens(<<c, rest::binary>>, acc) when c <= 0x20 or c == ?,, do: tokens(rest, acc)

  defp tokens(<<?", rest::binary>>, acc) do
    case :binary.split(rest, "\"") do
      [token, rest] -> tokens(rest, [token | acc])
      [_unterminated] -> Enum.reverse([:unterminated | acc])
    end
  end

  defp tokens(line, acc) do
    size = token_size(line, 0)
    <<token::binary-size(^size), rest::binary>> = line
    tokens(rest, [token | acc])
  end

  defp token_size(<<c, rest::binary>>, n) when c > 0x20 and c != ?,, do: token_size(rest, n + 1)
  defp token_size(_rest, n), do: n

  defp line(state, [], _n), do: {:cont, state}
  defp line(state, tokens, n), do: check(tokens, state, n)

  defp check(tokens, state, n) do
    if :unterminated in tokens, do: {:cont, error(state, n, "unterminated string")}, else: dispatch(state, tokens, n)
  end

  defp dispatch(%{open: nil} = state, [first | rest], n) do
    case {upcase(first), rest} do
      {"#END", _} -> {:halt, state}
      {"#DEFINE", [name | _]} -> {:cont, define(state, name, n)}
      _other -> {:cont, row(state, [first | rest], n)}
    end
  end

  defp dispatch(%{open: {name, types, start}} = state, [first | _], n) do
    case upcase(first) do
      "#END" ->
        {:halt, state}

      "#ENDDEFINE" ->
        {:cont, close(state, name, Enum.reverse(types), start)}

      "<INTEGER>" ->
        {:cont, %{state | open: {name, [:integer | types], start}}}

      "<STRING>" ->
        {:cont, %{state | open: {name, [:string | types], start}}}

      _other ->
        {:cont, error(state, n, "unexpected line inside #DEFINE #{name}")}
    end
  end

  defp define(state, name, n) do
    state = %{state | open: {name, [], n}}
    if Map.has_key?(@headers, name), do: state, else: error(state, n, "no column names known for #DEFINE #{name}")
  end

  defp close(state, name, _types, _n) when not is_map_key(@headers, name), do: %{state | open: nil}

  defp close(state, name, types, n) do
    if length(Map.fetch!(@headers, name)) == length(types) do
      %{
        state
        | open: nil,
          defined: Map.put(state.defined, name, types),
          order: [name | state.order],
          rows: Map.put(state.rows, name, [])
      }
    else
      error(
        %{state | open: nil},
        n,
        "#DEFINE #{name} has #{length(types)} columns, expected #{length(Map.fetch!(@headers, name))}"
      )
    end
  end

  defp row(state, [name | values], n) do
    case Map.fetch(state.defined, name) do
      :error ->
        error(state, n, "unknown row name #{inspect(name)}")

      {:ok, types} when length(types) != length(values) ->
        error(state, n, "#{name}: expected #{length(types)} values, got #{length(values)}")

      {:ok, types} ->
        check_values(state, name, Enum.zip(types, values), values, n)
    end
  end

  defp check_values(state, name, typed, values, n) do
    case Enum.find(typed, fn {type, value} -> type == :integer and not integer?(value) end) do
      nil -> %{state | rows: Map.update!(state.rows, name, &[values | &1])}
      {_type, value} -> error(state, n, "#{name}: not an integer: #{inspect(value)}")
    end
  end

  defp integer?(value), do: Regex.match?(~r/\A-?[0-9]+\z/, value)
  defp upcase(token), do: String.upcase(token, :ascii)
  defp error(state, n, message), do: %{state | errors: ["line #{n}: #{message}" | state.errors]}
end
