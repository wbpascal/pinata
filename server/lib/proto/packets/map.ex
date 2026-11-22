defmodule Proto.Packets.MapLoginReq do
  @moduledoc "0x1801 NC_MAP_LOGIN_REQ, client to server (sent to the Zone): the map login with the session handle and the 49 checksums of the Client data check."
  use Proto.Packet, opcode: 0x1801
  # official: chardata.wldmanhandle
  field :wm_handle, :u16
  # official: chardata.charid
  field :char_name, {:char, 20}
  # official: checksum, 49 x char[32] (lower-case hex text of an MD5)
  field :checksums, {:bytes, 1568}
end

defmodule Proto.Packets.MapLoginfailAck do
  @moduledoc "0x1804 NC_MAP_LOGINFAIL_ACK, server to client."
  use Proto.Packet, opcode: 0x1804
  # official: err
  field :error, :u16
  # official: nWrongDataFileIndex
  field :wrong_data_file_index, :u8
end
