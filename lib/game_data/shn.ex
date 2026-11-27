defmodule GameData.Shn do
  @moduledoc """
  Decoder of SHN tables. Format and cipher: `tools/protocol-re/shn.py` (zone `FUN_0062a780` / `FUN_0062a0b0`).

  Text cells are raw bytes in the client's legacy code page, never converted.
  """

  import Bitwise

  @type column :: %{
          name: binary(),
          type: non_neg_integer(),
          size: non_neg_integer(),
          kind: :integer | :string | :other
        }

  @numeric_types [1, 2, 3, 0xB, 0xC, 0xD, 0x10, 0x12, 0x14, 0x15, 0x16, 0x1B]
  @truncated {:error, "truncated SHN file"}

  @spec decode(binary()) :: {:ok, [column()], [[integer() | binary()]]} | {:error, String.t()}
  def decode(file) when byte_size(file) < 0x34, do: @truncated

  def decode(<<head::binary-size(0x24), body::binary>> = file) do
    <<_::binary-size(0x1C), flag::little-32, _::binary>> = head
    data = if flag == 0, do: file, else: head <> decipher(body)
    <<_::binary-size(0x28), rows_n::little-32, _row_len::little-32, cols_n::little-32, rest::binary>> = data

    with {:ok, columns, rows_bin} <- columns(rest, cols_n, []),
         {:ok, rows} <- rows(rows_bin, rows_n, columns, []) do
      {:ok, columns, rows}
    end
  end

  @doc "The file with its body (from 0x24) decrypted, whatever its flag says: what the Client data check hashes."
  @spec decrypt(binary()) :: {:ok, binary()} | {:error, String.t()}
  def decrypt(file) when byte_size(file) < 0x24, do: @truncated
  def decrypt(<<head::binary-size(0x24), body::binary>>), do: {:ok, head <> decipher(body)}

  defp decipher(body) do
    n = byte_size(body)

    body
    |> :binary.bin_to_list()
    |> Enum.reverse()
    |> decipher(n - 1, n &&& 0xFF, [])
    |> :erlang.list_to_binary()
  end

  # Walks the bytes from the last to the first and prepends, so the result is in file order again.
  defp decipher([], _i, _key, acc), do: acc

  defp decipher([byte | rest], i, key, acc) do
    next = bxor(bxor(bxor((i &&& 0xFF) * 11, (i &&& 0xF) + 0x55), key), 0xAA) &&& 0xFF
    decipher(rest, i - 1, next, [bxor(byte, key) | acc])
  end

  defp columns(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp columns(<<name::binary-size(48), type::little-32, size::little-32, rest::binary>>, n, acc) do
    [name | _] = :binary.split(name, <<0>>)
    columns(rest, n - 1, [%{name: name, type: type, size: size, kind: kind(type, size)} | acc])
  end

  defp columns(_rest, _n, _acc), do: @truncated

  # shortcut: every numeric SHN type is read unsigned, as shn.py does; add signed/float when a schema needs one
  defp kind(26, _size), do: :string

  defp kind(type, size) do
    cond do
      string?(type, size) -> :string
      size in [1, 2, 4] -> :integer
      true -> :other
    end
  end

  defp string?(type, size), do: type in [9, 0x18, 0x1A] or (type not in @numeric_types and size > 4)

  defp rows(_rest, 0, _columns, acc), do: {:ok, Enum.reverse(acc)}

  defp rows(<<len::little-16, _::binary>> = rest, n, columns, acc) when len >= 2 and byte_size(rest) >= len do
    payload = len - 2
    <<_::binary-size(2), row::binary-size(^payload), rest::binary>> = rest

    case cells(row, columns, []) do
      {:ok, cells} -> rows(rest, n - 1, columns, [cells | acc])
      :error -> @truncated
    end
  end

  defp rows(_rest, _n, _columns, _acc), do: @truncated

  defp cells(_row, [], acc), do: {:ok, Enum.reverse(acc)}

  defp cells(row, [%{type: 26} | columns], acc) do
    [string | _] = :binary.split(row, <<0>>)
    skip = min(byte_size(string) + 1, byte_size(row))
    <<_::binary-size(^skip), rest::binary>> = row
    cells(rest, columns, [string | acc])
  end

  defp cells(row, [%{size: size} = column | columns], acc) when byte_size(row) >= size do
    <<raw::binary-size(^size), rest::binary>> = row
    cells(rest, columns, [cell(column, raw) | acc])
  end

  # A text cell that is cut short by the end of its row keeps what is there; any other cell is truncated.
  defp cells(row, [%{kind: :string} | columns], acc) do
    [string | _] = :binary.split(row, <<0>>)
    cells(<<>>, columns, [string | acc])
  end

  defp cells(_row, _columns, _acc), do: :error

  defp cell(%{kind: :string}, raw), do: hd(:binary.split(raw, <<0>>))
  defp cell(%{kind: :integer}, raw), do: :binary.decode_unsigned(raw, :little)
  defp cell(%{kind: :other}, raw), do: raw
end
