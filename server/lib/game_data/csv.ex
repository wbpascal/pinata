defmodule GameData.Csv do
  @moduledoc """
  CSV of the server data tables: RFC 4180 with comma separators, read and written byte for byte (the cells are not
  UTF-8, see `GameData`).
  """

  @spec decode(binary()) :: {:ok, [binary()], [[binary()]]} | {:error, String.t()}
  def decode(<<>>), do: {:error, "empty file"}

  def decode(file) do
    case rows(file, [], []) do
      {:ok, [header | rows]} -> {:ok, header, rows}
      {:error, _message} = error -> error
    end
  end

  @spec encode([binary()], [[binary()]]) :: [iolist()]
  def encode(header, rows),
    do: Enum.map([header | rows], fn row -> [Enum.intersperse(Enum.map(row, &cell/1), ","), "\n"] end)

  defp cell(value) do
    if :binary.match(value, [",", "\"", "\r", "\n"]) == :nomatch,
      do: value,
      else: ["\"", :binary.replace(value, "\"", "\"\"", [:global]), "\""]
  end

  defp rows(<<>>, [], acc), do: {:ok, Enum.reverse(acc)}

  defp rows(file, row, acc) do
    case field(file) do
      {:error, _message} = error -> error
      {cell, rest, :comma} -> rows(rest, [cell | row], acc)
      {cell, rest, :eol} -> rows(rest, [], [Enum.reverse([cell | row]) | acc])
      {cell, _rest, :eof} -> {:ok, Enum.reverse([Enum.reverse([cell | row]) | acc])}
    end
  end

  defp field(<<?", rest::binary>>), do: quoted(rest, [])

  defp field(file) do
    case :binary.match(file, [",", "\n"]) do
      :nomatch ->
        {file, <<>>, :eof}

      {pos, 1} ->
        <<cell::binary-size(^pos), sep, rest::binary>> = file
        if sep == ?,, do: {cell, rest, :comma}, else: {strip_cr(cell), rest, :eol}
    end
  end

  defp strip_cr(cell) do
    size = byte_size(cell) - 1

    case cell do
      <<cell::binary-size(^size), ?\r>> -> cell
      _other -> cell
    end
  end

  defp quoted(file, acc) do
    case :binary.match(file, "\"") do
      :nomatch ->
        {:error, "unterminated quote"}

      {pos, 1} ->
        <<text::binary-size(^pos), ?", rest::binary>> = file
        acc = [acc, text]

        case rest do
          <<?", rest::binary>> -> quoted(rest, [acc, "\""])
          <<?,, rest::binary>> -> {IO.iodata_to_binary(acc), rest, :comma}
          <<?\n, rest::binary>> -> {IO.iodata_to_binary(acc), rest, :eol}
          <<?\r, ?\n, rest::binary>> -> {IO.iodata_to_binary(acc), rest, :eol}
          <<>> -> {IO.iodata_to_binary(acc), <<>>, :eof}
          _other -> {:error, "unexpected character after a closing quote"}
        end
    end
  end
end
