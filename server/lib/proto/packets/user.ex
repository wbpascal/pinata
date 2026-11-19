defmodule Proto.Packets.WorldInfo do
  @moduledoc "One world of the world list: number, name, status (nested in 0x0C0A and 0x0C1C)."
  use Proto.Packet
  field :world_no, :u8
  field :name, {:char, 16}
  field :status, :u8
end

defmodule Proto.Packets.UserXtrapReq do
  @moduledoc "0x0C04 NC_USER_XTRAP_REQ, client to server."
  use Proto.Packet, opcode: 0x0C04
  field :key_length, :u8
  field :key, {:char, 29}
end

defmodule Proto.Packets.UserXtrapAck do
  @moduledoc "0x0C05 NC_USER_XTRAP_ACK, server to client."
  use Proto.Packet, opcode: 0x0C05
  field :success, :u8
end

defmodule Proto.Packets.UserLoginfailAck do
  @moduledoc "0x0C09 NC_USER_LOGINFAIL_ACK, server to client."
  use Proto.Packet, opcode: 0x0C09
  field :error, :u16
end

defmodule Proto.Packets.UserLoginAck do
  @moduledoc "0x0C0A NC_USER_LOGIN_ACK, server to client: the world list."
  use Proto.Packet, opcode: 0x0C0A
  array :worlds, Proto.Packets.WorldInfo, count: :u8
end

defmodule Proto.Packets.UserWorldselectReq do
  @moduledoc "0x0C0B NC_USER_WORLDSELECT_REQ, client to server."
  use Proto.Packet, opcode: 0x0C0B
  field :world_no, :u8
end

defmodule Proto.Packets.UserWorldselectAck do
  @moduledoc "0x0C0C NC_USER_WORLDSELECT_ACK, server to client: status of the world, where to connect and the validation key."
  use Proto.Packet, opcode: 0x0C0C
  field :world_status, :u8
  field :ip, {:char, 16}
  field :port, :u16
  field :validate, {:u16s, 32}
end

defmodule Proto.Packets.UserLoginworldReq do
  @moduledoc "0x0C0F NC_USER_LOGINWORLD_REQ, client to server (sent to WorldManager)."
  use Proto.Packet, opcode: 0x0C0F
  field :user_name, {:char, 256}
  field :validate, {:u16s, 32}
end

defmodule Proto.Packets.AvatarDeleteInfo do
  @moduledoc "Delete date of a character (nested in AVATAR). Always zero here: deleted characters are never listed (P02-B1 fixed)."
  use Proto.Packet
  field :year, :u8
  field :month, :u8
  field :day, :u8
  field :hour, :u8
  field :min, :u8
end

defmodule Proto.Packets.Avatar do
  @moduledoc """
  AVATAR (PROTO_AVATARINFORMATION, 0x82 bytes): one character of the character list (nested in 0x0C14).

  `kq_date` holds bits 0-23 of `SHINE_DATETIME` (year:4, month:4, day:5, hour:5, min:6, little-endian), the next byte
  the seconds and two unused bits (P02-B7: sent as 0). `upgrade_unused` is always 0xF.
  """
  use Proto.Packet
  field :chrregnum, :u32
  field :name, {:char, 20}
  field :level, :u16
  field :slot, :u8
  field :loginmap, {:char, 12}
  field :delinfo, Proto.Packets.AvatarDeleteInfo
  bits gender: 1, chrclass: 5, race: 2
  field :hairtype, :u8
  field :haircolor, :u8
  field :faceshape, :u8
  field :equip, {:u16s, 20}
  bits upgrade_righthand: 4, upgrade_lefthand: 4
  bits upgrade_leg: 4, upgrade_body: 4
  bits upgrade_unused: 4, upgrade_shoes: 4
  field :kq_handle, :u32
  field :kq_map_name, {:char, 12}
  field :kq_x, :u32
  field :kq_y, :u32
  field :kq_date, {:bytes, 3}
  bits kq_date_unused: 2, kq_date_sec: 6
  field :need_change_id, :u8
  field :change_id_init, :u8
  field :change_id_row_no, :u32
  field :tutorial_state, :u32
  field :tutorial_step, :u8
end

defmodule Proto.Packets.UserLoginworldAck do
  @moduledoc "0x0C14 NC_USER_LOGINWORLD_ACK, server to client: the WorldManager session handle and the character list."
  use Proto.Packet, opcode: 0x0C14
  field :worldmanager, :u16
  array :avatars, Proto.Packets.Avatar, count: :u8
end

defmodule Proto.Packets.UserLoginworldfailAck do
  @moduledoc "0x0C15 NC_USER_LOGINWORLDFAIL_ACK, server to client."
  use Proto.Packet, opcode: 0x0C15
  field :error, :u16
end

defmodule Proto.Packets.UserAvatarListReq do
  @moduledoc "0x0C1F NC_USER_AVATAR_LIST_REQ, empty, client to server."
  use Proto.Packet, opcode: 0x0C1F
end

defmodule Proto.Packets.UserConnectcutCmd do
  @moduledoc "0x0C17 NC_USER_CONNECTCUT_CMD, server to client."
  use Proto.Packet, opcode: 0x0C17
  field :error, :u16
end

defmodule Proto.Packets.UserWorldStatusReq do
  @moduledoc "0x0C1B NC_USER_WORLD_STATUS_REQ, empty, client to server."
  use Proto.Packet, opcode: 0x0C1B
end

defmodule Proto.Packets.UserWorldStatusAck do
  @moduledoc "0x0C1C NC_USER_WORLD_STATUS_ACK, server to client: the world list."
  use Proto.Packet, opcode: 0x0C1C
  array :worlds, Proto.Packets.WorldInfo, count: :u8
end

defmodule Proto.Packets.UserUsLoginReq do
  @moduledoc "0x0C5A NC_USER_US_LOGIN_REQ, client to server."
  use Proto.Packet, opcode: 0x0C5A
  field :user_name, {:char, 260}
  field :password, {:char, 36}
  field :spawnapps, {:bytes, 20}
end

defmodule Proto.Packets.UserClientVersionCheckReq do
  @moduledoc "0x0C65 NC_USER_CLIENT_VERSION_CHECK_REQ, client to server."
  use Proto.Packet, opcode: 0x0C65
  field :version_key, {:char, 64}
end

defmodule Proto.Packets.UserClientWrongversionCheckAck do
  @moduledoc "0x0C66 NC_USER_CLIENT_WRONGVERSION_CHECK_ACK, server to client. The original never writes the byte (L00-B1); we send 0."
  use Proto.Packet, opcode: 0x0C66
  field :unused, :u8
end

defmodule Proto.Packets.UserClientRightversionCheckAck do
  @moduledoc "0x0C67 NC_USER_CLIENT_RIGHTVERSION_CHECK_ACK, server to client."
  use Proto.Packet, opcode: 0x0C67
  field :xtrap_server_key_length, :u8
  field :xtrap_server_key, {:char, 1}
end
