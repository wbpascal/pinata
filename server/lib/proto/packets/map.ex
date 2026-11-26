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

defmodule Proto.Packets.MapLinksameCmd do
  @moduledoc "0x1809 NC_MAP_LINKSAME_CMD, server to client: a link inside the player's own map instance; the client reloads the map without a reconnect and sends `0x1803`."
  use Proto.Packet, opcode: 0x1809
  # official: mapid (MapInfo.ID of the client map)
  field :map_index, :u16
  # official: location.x
  field :x, :u32
  # official: location.y
  field :y, :u32
end

defmodule Proto.Packets.MapLinkotherCmd do
  @moduledoc "0x180A NC_MAP_LINKOTHER_CMD, server to client: a link to another map instance; the client connects to the Zone at the address and sends `0x1801` with the session handle."
  use Proto.Packet, opcode: 0x180A
  # official: link.mapid (MapInfo.ID of the client map)
  field :map_index, :u16
  # official: link.location.x
  field :x, :u32
  # official: link.location.y
  field :y, :u32
  # official: sock.zoneip
  field :zone_ip, {:char, 16}
  # official: sock.zoneport
  field :zone_port, :u16
  # official: wldmanhandle
  field :wm_handle, :u16
end

defmodule Proto.Packets.MapTownportalReq do
  @moduledoc "0x181A NC_MAP_TOWNPORTAL_REQ, client to server: use the town portal row of `TownPortal.shn` with this index."
  use Proto.Packet, opcode: 0x181A
  # official: portalindex
  field :index, :u8
end

defmodule Proto.Packets.MapTownportalAck do
  @moduledoc "0x181B NC_MAP_TOWNPORTAL_ACK, server to client: 0x19C1 success, 0x19C2 cannot use now, 0x19C3 invalid index, 0x19C4 level too low."
  use Proto.Packet, opcode: 0x181B
  # official: err
  field :error, :u16
end
