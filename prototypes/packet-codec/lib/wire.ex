defmodule Proto.Wire do
  @moduledoc false

  @doc "char[N] decode: the bytes before the first NUL (no character-set conversion)."
  @spec cstr(binary()) :: binary()
  def cstr(bin), do: bin |> :binary.split(<<0>>) |> hd()

  @doc "char[N] encode: zero-pad to n bytes, raise when longer."
  @spec pad(binary(), non_neg_integer()) :: binary()
  def pad(bin, n) when byte_size(bin) <= n, do: bin <> :binary.copy(<<0>>, n - byte_size(bin))
  def pad(bin, n), do: raise(ArgumentError, "#{inspect(bin)} longer than char[#{n}]")
end
