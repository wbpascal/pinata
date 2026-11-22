defmodule Proto.Packets.MiscHeartbeatReq do
  @moduledoc "0x0804 NC_MISC_HEARTBEAT_REQ, empty, both directions."
  use Proto.Packet, opcode: 0x0804
end

defmodule Proto.Packets.MiscHeartbeatAck do
  @moduledoc "0x0805 NC_MISC_HEARTBEAT_ACK, empty, both directions."
  use Proto.Packet, opcode: 0x0805
end

defmodule Proto.Packets.MiscSeedAck do
  @moduledoc "0x0807 NC_MISC_SEED_ACK, server to client."
  use Proto.Packet, opcode: 0x0807
  field :seed, :u16
end

defmodule Proto.Packets.MiscGametimeReq do
  @moduledoc "0x080D NC_MISC_GAMETIME_REQ, empty, client to server."
  use Proto.Packet, opcode: 0x080D
end

defmodule Proto.Packets.MiscGametimeAck do
  @moduledoc "0x080E NC_MISC_GAMETIME_ACK, server to client: local time of the server."
  use Proto.Packet, opcode: 0x080E
  field :hour, :u8
  field :minute, :u8
  field :second, :u8
end

defmodule Proto.Packets.MiscServerparameterReq do
  @moduledoc "0x082F NC_MISC_SERVERPARAMETER_REQ, empty, client to server."
  use Proto.Packet, opcode: 0x082F
end

defmodule Proto.Packets.MiscServerparameterAck do
  @moduledoc "0x0830 NC_MISC_SERVERPARAMETER_ACK, server to client: the shout limits; the 2016 client has no handler for it (Z01-B5)."
  use Proto.Packet, opcode: 0x0830
  # ShoutLevel of ChrCommon
  field :shout_level, :u8
  # ShoutDelay of ChrCommon, seconds
  field :shout_delay, :u16
end

defmodule Proto.Packets.MiscChatBlockSpamerBlocktimeCmd do
  @moduledoc "0x0848 NC_MISC_CHAT_BLOCK_SPAMER_BLOCKTIME_CMD, server to client: the chat of the player is blocked by the spam filter."
  use Proto.Packet, opcode: 0x0848
  # official: nBlockTime, seconds left
  field :block_time, :u32
end
