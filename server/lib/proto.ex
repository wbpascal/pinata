defmodule Proto do
  @moduledoc """
  Client protocol: framing, cipher and packet definitions. Named `Proto` because `Protocol` is an Elixir core module.

  Pure code, no sockets and no processes. Receive: `Proto.Framing.split/1`, then `Proto.Cipher.crypt/2`, then
  `decode/1`. Send: `encode/1`, then `Proto.Framing.frame/1`.
  """

  use Boundary, deps: [Clock, Random], exports: [Cipher, Framing, {Packets, []}]

  @doc "Decodes one decrypted body: opcode u16 LE, then the payload."
  @spec decode(binary()) :: {:ok, struct()} | {:error, :unknown_opcode | :bad_size}
  def decode(<<opcode::little-16, payload::binary>>) do
    case Proto.Packets.fetch(opcode) do
      {:ok, mod} -> mod.decode(payload)
      :error -> {:error, :unknown_opcode}
    end
  end

  def decode(_body), do: {:error, :bad_size}

  @doc "Encodes a packet to a body (opcode and payload); frame it with `Proto.Framing.frame/1`."
  @spec encode(struct()) :: binary()
  def encode(%mod{} = packet), do: <<mod.opcode()::little-16, mod.encode(packet)::binary>>
end
