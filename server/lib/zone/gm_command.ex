defmodule Zone.GmCommand do
  @moduledoc """
  The GM command frame (`docs/technical/flows/gm-commands.md`): a `0x2001` chat line that starts with `&` is a
  command. `parse/1` splits the line, `lookup/2` finds its handler in the one command table and checks the admin
  level, `number/1` reads a numeric argument. The Zone connection (`Zone.Handler`) runs the handler.

  Source: `docs/pseudocode/zone/Z11-gm-commands.md` §1 (`so_ply_AdminCommand` @ FUN_00427a40, the argument split
  `ListIter_AmpCmdArgument` @ FUN_00427550). Fixed original-server bugs: every command line of a character with an
  admin level above 0 is logged, whatever the level (Z11-B1: the original logs none above 100); an argument
  longer than 32 bytes is cut, not copied past its buffer (Z11-B2).
  """

  @type handler :: :hide | :show | :dimension | :linkto | :kickout | :adminlevel

  @line_bytes 100
  @word_bytes 20
  @arg_bytes 32
  @max_args 12

  # The command table: word (bytes after `&`, case-sensitive), the lowest admin level, the handler.
  # `AdminLvSet.shn` is not loaded: it changes only the levels of `&scrint`, `&templink` and `&oxblock`; load it when
  # the first of those is built (issue 93).
  @commands [
    {"&hide", 10, :hide},
    # &숨어 (CP949)
    {<<"&", 0xBC, 0xFB, 0xBE, 0xEE>>, 10, :hide},
    {"&show", 10, :show},
    # &보여 (CP949)
    {<<"&", 0xBA, 0xB8, 0xBF, 0xA9>>, 10, :show},
    {"&linkto", 10, :linkto},
    # &이동 (CP949)
    {<<"&", 0xC0, 0xCC, 0xB5, 0xBF>>, 10, :linkto},
    {"&kickout", 10, :kickout},
    # &추방 (CP949)
    {<<"&", 0xC3, 0xDF, 0xB9, 0xE6>>, 10, :kickout},
    {"&adminlevel", 1, :adminlevel},
    {"&dimension", 100, :dimension}
  ]

  @doc """
  Splits a command line into its word and arguments. Only the first 100 bytes count. Tokens are separated by spaces;
  `"` opens or closes a quoted run (spaces inside belong to the token) and is dropped; `\\` takes the next byte
  literally. Empty tokens are dropped. The word is cut at 20 bytes, at most 12 arguments are kept, each cut at 32 bytes.
  """
  @spec parse(binary()) :: {word :: binary(), args :: [binary()]}
  def parse(line) do
    line = binary_part(line, 0, min(byte_size(line), @line_bytes))

    case tokens(line, false, <<>>, []) do
      [word | args] -> {cut(word, @word_bytes), args |> Enum.take(@max_args) |> Enum.map(&cut(&1, @arg_bytes))}
      [] -> {<<>>, []}
    end
  end

  defp tokens(<<>>, _quoted, token, acc), do: Enum.reverse(push(token, acc))
  defp tokens(<<?\\, b, rest::binary>>, q, token, acc), do: tokens(rest, q, <<token::binary, b>>, acc)
  defp tokens(<<?\\>>, q, token, acc), do: tokens(<<>>, q, token, acc)
  defp tokens(<<?", rest::binary>>, q, token, acc), do: tokens(rest, not q, token, acc)
  defp tokens(<<?\s, rest::binary>>, false, token, acc), do: tokens(rest, false, <<>>, push(token, acc))
  defp tokens(<<b, rest::binary>>, q, token, acc), do: tokens(rest, q, <<token::binary, b>>, acc)

  defp push(<<>>, acc), do: acc
  defp push(token, acc), do: [token | acc]

  defp cut(bin, n), do: binary_part(bin, 0, min(byte_size(bin), n))

  @doc "The handler of a command word for an admin level: `:denied` for a known word that needs a higher level."
  @spec lookup(binary(), non_neg_integer()) :: {:ok, handler()} | :denied | :unknown
  def lookup(word, level) do
    case List.keyfind(@commands, word, 0) do
      {_word, needed, handler} when level >= needed -> {:ok, handler}
      {_word, _needed, _handler} -> :denied
      nil -> :unknown
    end
  end

  @doc """
  A number argument as the original's `sscanf("%d")` reads it: leading spaces skipped, an optional sign, digits;
  the digits up to the first other byte count (`"12x"` is 12), no digits is 0. Clamped to the signed 32-bit range.
  """
  @spec number(binary()) :: integer()
  def number(text) do
    text = String.trim_leading(text, " ")

    {sign, digits} =
      case text do
        <<?-, rest::binary>> -> {-1, rest}
        <<?+, rest::binary>> -> {1, rest}
        _ -> {1, text}
      end

    case digits do
      <<d, _::binary>> when d in ?0..?9 ->
        {n, _rest} = Integer.parse(digits)
        (sign * n) |> max(-2_147_483_648) |> min(2_147_483_647)

      _ ->
        0
    end
  end
end
