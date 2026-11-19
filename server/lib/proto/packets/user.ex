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

defmodule Proto.Packets.UserLoginworldfailAck do
  @moduledoc "0x0C15 NC_USER_LOGINWORLDFAIL_ACK, server to client."
  use Proto.Packet, opcode: 0x0C15
  field :error, :u16
end

defmodule Proto.Packets.UserConnectcutCmd do
  @moduledoc "0x0C17 NC_USER_CONNECTCUT_CMD, server to client."
  use Proto.Packet, opcode: 0x0C17
  field :error, :u16
end

defmodule Proto.Packets.UserNormallogoutCmd do
  @moduledoc "0x0C18 NC_USER_NORMALLOGOUT_CMD, client to server: 0 = quit, 1 = back to the character list."
  use Proto.Packet, opcode: 0x0C18
  field :logout_type, :u8
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

defmodule Proto.Packets.UserWillWorldSelectReq do
  @moduledoc "0x0C33 NC_USER_WILL_WORLD_SELECT_REQ, empty, client to server (sent to WorldManager)."
  use Proto.Packet, opcode: 0x0C33
end

defmodule Proto.Packets.UserWillWorldSelectAck do
  @moduledoc "0x0C34 NC_USER_WILL_WORLD_SELECT_ACK, server to client: the login token for the way back."
  use Proto.Packet, opcode: 0x0C34
  field :error, :u16
  field :otp, {:char, 32}
end

defmodule Proto.Packets.UserLoginWithOtpReq do
  @moduledoc "0x0C37 NC_USER_LOGIN_WITH_OTP_REQ, client to server (sent to Login)."
  use Proto.Packet, opcode: 0x0C37
  field :otp, {:char, 32}
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
