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
