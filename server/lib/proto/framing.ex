defmodule Proto.Framing do
  @moduledoc """
  Length prefix of a packet (`docs/protocol/README.md` section 1.1).

  A body under 256 bytes has a one-byte length. A longer body has a zero byte, then the length as u16 LE.
  Lengths are never rejected on receive: the caller decrypts and decodes whatever `split/1` returns.
  """

  @doc "Prefixes a body with its length. A body of 0x1FFE bytes or more is too large."
  @spec frame(binary()) :: {:ok, binary()} | {:error, :too_large}
  def frame(body) when byte_size(body) < 0x100, do: {:ok, <<byte_size(body)::8, body::binary>>}
  def frame(body) when byte_size(body) < 0x1FFE, do: {:ok, <<0, byte_size(body)::little-16, body::binary>>}
  def frame(_body), do: {:error, :too_large}

  @doc "Cuts the first complete frame off a buffer; `:more` when it is incomplete."
  @spec split(binary()) :: {:ok, body :: binary(), rest :: binary()} | :more
  def split(<<0, len::little-16, body::binary-size(len), rest::binary>>), do: {:ok, body, rest}
  def split(<<len::8, body::binary-size(len), rest::binary>>) when len > 0, do: {:ok, body, rest}
  def split(_buffer), do: :more
end
