defmodule Proto.Packets.ServerMenu do
  @moduledoc "SERVERMENU (0x21 bytes, nested in 0x3C01): one entry of a server menu, the answer byte and its text."
  use Proto.Packet
  # official: reply
  field :reply, :u8
  # official: string
  field :string, {:char, 32}
end

defmodule Proto.Packets.MenuServermenuReq do
  @moduledoc """
  0x3C01 NC_MENU_SERVERMENU_REQ, server to client: a menu with a title and entries; the client answers the chosen
  entry with `0x3C02` and closes the menu when the player walks farther than `limit_range` from `npcPosition`.
  """
  use Proto.Packet, opcode: 0x3C01
  # official: title
  field :title, {:char, 128}
  # official: priority
  field :priority, :u8
  # official: npcHandle
  field :npc_handle, :u16
  # official: npcPosition.x
  field :x, :u32
  # official: npcPosition.y
  field :y, :u32
  # official: limitRange
  field :limit_range, :u16
  # official: menunum, menu
  array :menus, Proto.Packets.ServerMenu, count: :u8
end

defmodule Proto.Packets.MenuServermenuAck do
  @moduledoc "0x3C02 NC_MENU_SERVERMENU_ACK, client to server: the answer byte of the chosen server menu entry."
  use Proto.Packet, opcode: 0x3C02
  # official: reply
  field :reply, :u8
end
