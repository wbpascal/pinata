defmodule Proto.Packets.CharLoginReq do
  @moduledoc "0x1001 NC_CHAR_LOGIN_REQ, client to server (sent to WorldManager): the character of a slot enters the world."
  use Proto.Packet, opcode: 0x1001
  # official: slot
  field :slot, :u8
end

defmodule Proto.Packets.CharLoginfailAck do
  @moduledoc "0x1002 NC_CHAR_LOGINFAIL_ACK, server to client."
  use Proto.Packet, opcode: 0x1002
  # official: err
  field :error, :u16
end

defmodule Proto.Packets.CharLoginAck do
  @moduledoc "0x1003 NC_CHAR_LOGIN_ACK, server to client: the address of the Zone node that runs the character's map."
  use Proto.Packet, opcode: 0x1003
  # official: zoneip
  field :zone_ip, {:char, 16}
  # official: zoneport
  field :zone_port, :u16
end

defmodule Proto.Packets.CharTutorialPopupReq do
  @moduledoc "0x1110 NC_CHAR_TUTORIAL_POPUP_REQ, server to client: asks whether to play the tutorial. The original never writes the byte (P02-B28); we send 0."
  use Proto.Packet, opcode: 0x1110
  field :unused, :u8
end

defmodule Proto.Packets.CharTutorialPopupAck do
  @moduledoc "0x1111 NC_CHAR_TUTORIAL_POPUP_ACK, client to server: the answer to 0x1110."
  use Proto.Packet, opcode: 0x1111
  # official: bIsSkip
  field :is_skip, :u8
end
