defmodule Proto.Packets do
  @moduledoc """
  Registry of packet modules by opcode (opcodes are unique regardless of direction).

  A new packet module gets a line here, then run `mix pinata.packets_doc`. The map is literal so this file does
  not depend on the packet modules at compile time; a test checks that it agrees with `opcode/0`.
  """

  @packets %{
    0x0804 => Proto.Packets.MiscHeartbeatReq,
    0x0805 => Proto.Packets.MiscHeartbeatAck,
    0x0807 => Proto.Packets.MiscSeedAck
  }

  @doc "The module for an opcode."
  @spec fetch(integer()) :: {:ok, module()} | :error
  def fetch(opcode), do: Map.fetch(@packets, opcode)

  @doc "Every registered module, sorted by opcode."
  @spec all() :: [module()]
  def all, do: @packets |> Enum.sort() |> Enum.map(&elem(&1, 1))
end
