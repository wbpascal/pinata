defmodule Proto.Packets do
  @moduledoc """
  Registry of packet modules by opcode (opcodes are unique regardless of direction).

  A new packet module gets a line here, then run `mix pinata.packets_doc`. The map is literal so this file does
  not depend on the packet modules at compile time; a test checks that it agrees with `opcode/0`.
  """

  @packets %{
    0x0804 => Proto.Packets.MiscHeartbeatReq,
    0x0805 => Proto.Packets.MiscHeartbeatAck,
    0x0807 => Proto.Packets.MiscSeedAck,
    0x080D => Proto.Packets.MiscGametimeReq,
    0x080E => Proto.Packets.MiscGametimeAck,
    0x0C04 => Proto.Packets.UserXtrapReq,
    0x0C05 => Proto.Packets.UserXtrapAck,
    0x0C09 => Proto.Packets.UserLoginfailAck,
    0x0C0A => Proto.Packets.UserLoginAck,
    0x0C0B => Proto.Packets.UserWorldselectReq,
    0x0C0C => Proto.Packets.UserWorldselectAck,
    0x0C0F => Proto.Packets.UserLoginworldReq,
    0x0C14 => Proto.Packets.UserLoginworldAck,
    0x0C15 => Proto.Packets.UserLoginworldfailAck,
    0x0C17 => Proto.Packets.UserConnectcutCmd,
    0x0C18 => Proto.Packets.UserNormallogoutCmd,
    0x0C1B => Proto.Packets.UserWorldStatusReq,
    0x0C1C => Proto.Packets.UserWorldStatusAck,
    0x0C1F => Proto.Packets.UserAvatarListReq,
    0x0C33 => Proto.Packets.UserWillWorldSelectReq,
    0x0C34 => Proto.Packets.UserWillWorldSelectAck,
    0x0C37 => Proto.Packets.UserLoginWithOtpReq,
    0x0C5A => Proto.Packets.UserUsLoginReq,
    0x0C65 => Proto.Packets.UserClientVersionCheckReq,
    0x0C66 => Proto.Packets.UserClientWrongversionCheckAck,
    0x0C67 => Proto.Packets.UserClientRightversionCheckAck,
    0x1401 => Proto.Packets.AvatarCreateReq,
    0x1404 => Proto.Packets.AvatarCreatefailAck,
    0x1406 => Proto.Packets.AvatarCreatesuccAck
  }

  @doc "The module for an opcode."
  @spec fetch(integer()) :: {:ok, module()} | :error
  def fetch(opcode), do: Map.fetch(@packets, opcode)

  @doc "Every registered module, sorted by opcode."
  @spec all() :: [module()]
  def all, do: @packets |> Enum.sort() |> Enum.map(&elem(&1, 1))
end
