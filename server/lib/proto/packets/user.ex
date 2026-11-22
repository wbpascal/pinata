defmodule Proto.Packets.WorldInfo do
  @moduledoc "One world of the world list: number, name, status (nested in 0x0C0A and 0x0C1C)."
  use Proto.Packet
  # official: worldno
  field :world_no, :u8
  # official: worldname
  field :name, {:char, 16}
  # official: worldstatus
  field :status, :u8
end

defmodule Proto.Packets.UserXtrapReq do
  @moduledoc "0x0C04 NC_USER_XTRAP_REQ, client to server."
  use Proto.Packet, opcode: 0x0C04
  # official: XTrapClientKeyLength
  field :key_length, :u8
  # official: XTrapClientKey
  field :key, {:char, 29}
end

defmodule Proto.Packets.UserXtrapAck do
  @moduledoc "0x0C05 NC_USER_XTRAP_ACK, server to client."
  use Proto.Packet, opcode: 0x0C05
  # official: bSuccess
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
  # official: worldinfo, count numofworld
  array :worlds, Proto.Packets.WorldInfo, count: :u8
end

defmodule Proto.Packets.UserWorldselectReq do
  @moduledoc "0x0C0B NC_USER_WORLDSELECT_REQ, client to server."
  use Proto.Packet, opcode: 0x0C0B
  # official: worldno
  field :world_no, :u8
end

defmodule Proto.Packets.UserWorldselectAck do
  @moduledoc "0x0C0C NC_USER_WORLDSELECT_ACK, server to client: status of the world, where to connect and the validation key."
  use Proto.Packet, opcode: 0x0C0C
  # official: worldstatus
  field :world_status, :u8
  field :ip, {:char, 16}
  field :port, :u16
  # official: validate_new
  field :validate, {:u16s, 32}
end

defmodule Proto.Packets.UserLoginworldReq do
  @moduledoc "0x0C0F NC_USER_LOGINWORLD_REQ, client to server (sent to WorldManager)."
  use Proto.Packet, opcode: 0x0C0F
  # official: user
  field :user_name, {:char, 256}
  # official: validate_new
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
  # official: shape
  bits gender: 1, chrclass: 5, race: 2
  field :hairtype, :u8
  field :haircolor, :u8
  field :faceshape, :u8
  # official: equip (Equ_Head to Equ_AccShield)
  field :equip, {:u16s, 20}
  # official: equip.upgrade.lefthand, .righthand
  bits upgrade_righthand: 4, upgrade_lefthand: 4
  # official: equip.upgrade.body, .leg
  bits upgrade_leg: 4, upgrade_body: 4
  # official: equip.upgrade.shoes
  bits upgrade_unused: 4, upgrade_shoes: 4
  # official: nKQHandle
  field :kq_handle, :u32
  # official: sKQMapName
  field :kq_map_name, {:char, 12}
  # official: nKQCoord.x
  field :kq_x, :u32
  # official: nKQCoord.y
  field :kq_y, :u32
  # official: dKQDate
  field :kq_date, {:bytes, 3}
  bits kq_date_unused: 2, kq_date_sec: 6
  # official: CharIDChangeData.bNeedChangeID
  field :need_change_id, :u8
  # official: CharIDChangeData.bInit
  field :change_id_init, :u8
  # official: CharIDChangeData.nRowNo
  field :change_id_row_no, :u32
  # official: TutorialInfo.nTutorialState
  field :tutorial_state, :u32
  # official: TutorialInfo.nTutorialStep
  field :tutorial_step, :u8
end

defmodule Proto.Packets.UserLoginworldAck do
  @moduledoc "0x0C14 NC_USER_LOGINWORLD_ACK, server to client: the WorldManager session handle and the character list."
  use Proto.Packet, opcode: 0x0C14
  field :worldmanager, :u16
  # official: avatar, count numofavatar
  array :avatars, Proto.Packets.Avatar, count: :u8
end

defmodule Proto.Packets.AvatarCreateReq do
  @moduledoc "0x1401 NC_AVATAR_CREATE_REQ, client to server (sent to WorldManager): slot, name and look of the new character."
  use Proto.Packet, opcode: 0x1401
  # official: slotnum
  field :slot, :u8
  field :name, {:char, 20}
  # official: char_shape
  bits gender: 1, chrclass: 5, race: 2
  field :hairtype, :u8
  field :haircolor, :u8
  field :faceshape, :u8
end

defmodule Proto.Packets.AvatarCreatefailAck do
  @moduledoc "0x1404 NC_AVATAR_CREATEFAIL_ACK, server to client."
  use Proto.Packet, opcode: 0x1404
  # official: err
  field :error, :u16
end

defmodule Proto.Packets.AvatarCreatesuccAck do
  @moduledoc "0x1406 NC_AVATAR_CREATESUCC_ACK, server to client: numofavatar (always 1) and the new AVATAR."
  use Proto.Packet, opcode: 0x1406
  # official: avatar, count numofavatar
  array :avatars, Proto.Packets.Avatar, count: :u8
end

defmodule Proto.Packets.AvatarEraseReq do
  @moduledoc "0x1407 NC_AVATAR_ERASE_REQ, client to server (sent to WorldManager): the slot of the character to delete."
  use Proto.Packet, opcode: 0x1407
  field :slot, :u8
end

defmodule Proto.Packets.AvatarErasefailAck do
  @moduledoc "0x140A NC_AVATAR_ERASEFAIL_ACK, server to client. The client knows 0xC7 (guild master) and one text for every other code."
  use Proto.Packet, opcode: 0x140A
  # official: err
  field :error, :u16
end

defmodule Proto.Packets.AvatarErasesuccAck do
  @moduledoc "0x140C NC_AVATAR_ERASESUCC_ACK, server to client: the slot of the 0x1407."
  use Proto.Packet, opcode: 0x140C
  field :slot, :u8
end

defmodule Proto.Packets.AvatarRenameReq do
  @moduledoc "0x140F NC_AVATAR_RENAME_REQ, client to server (sent to WorldManager): the slot and the new name."
  use Proto.Packet, opcode: 0x140F
  # official: SlotNo
  field :slot, :u8
  # official: NewName
  field :name, {:char, 20}
end

defmodule Proto.Packets.AvatarRenameAck do
  @moduledoc "0x1410 NC_AVATAR_RENAME_ACK, server to client: slot and name of the 0x140F; error 0xD0 renamed, 0xD1 refused."
  use Proto.Packet, opcode: 0x1410
  # official: SlotNo
  field :slot, :u8
  # official: NewName
  field :name, {:char, 20}
  # official: Error
  field :error, :u16
end

defmodule Proto.Packets.UserConnectionChangeCharIdReq do
  @moduledoc "0xB409 NC_USER_CONNECTION_CHANGE_CHAR_ID_REQ, client to server (sent to WorldManager): rename by item right."
  use Proto.Packet, opcode: 0xB409
  # official: nSlotNo
  field :slot, :u8
  # official: sNewID
  field :name, {:char, 20}
end

defmodule Proto.Packets.UserConnectionChangeCharIdAck do
  @moduledoc "0xB40C NC_USER_CONNECTION_CHANGE_CHAR_ID_ACK, server to client: the error comes first."
  use Proto.Packet, opcode: 0xB40C
  # official: nError
  field :error, :u16
  # official: nSlotNo
  field :slot, :u8
  # official: sNewID
  field :name, {:char, 20}
end

defmodule Proto.Packets.UserLoginworldfailAck do
  @moduledoc "0x0C15 NC_USER_LOGINWORLDFAIL_ACK, server to client."
  use Proto.Packet, opcode: 0x0C15
  # official: errorcode
  field :error, :u16
end

defmodule Proto.Packets.UserAvatarListReq do
  @moduledoc """
  0x0C1F NC_USER_AVATAR_LIST_REQ, client to server. The official struct is empty; the 2016 client sends one unset
  byte (capture-validation §22.5), and the server does not read it.
  """
  use Proto.Packet, opcode: 0x0C1F
  field :unset, :u8
end

defmodule Proto.Packets.UserConnectcutCmd do
  @moduledoc "0x0C17 NC_USER_CONNECTCUT_CMD, server to client."
  use Proto.Packet, opcode: 0x0C17
  # official: reason
  field :error, :u16
end

defmodule Proto.Packets.UserNormallogoutCmd do
  @moduledoc "0x0C18 NC_USER_NORMALLOGOUT_CMD, client to server: 0 = quit, 1 = back to the character list."
  use Proto.Packet, opcode: 0x0C18
  # official: LogoutType
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
  # official: nError
  field :error, :u16
  # official: sOTP
  field :otp, {:char, 32}
end

defmodule Proto.Packets.UserLoginWithOtpReq do
  @moduledoc "0x0C37 NC_USER_LOGIN_WITH_OTP_REQ, client to server (sent to Login)."
  use Proto.Packet, opcode: 0x0C37
  # official: sOTP
  field :otp, {:char, 32}
end

defmodule Proto.Packets.UserUsLoginReq do
  @moduledoc "0x0C5A NC_USER_US_LOGIN_REQ, client to server."
  use Proto.Packet, opcode: 0x0C5A
  # official: sUserName
  field :user_name, {:char, 260}
  # official: sPassword
  field :password, {:char, 36}
  field :spawnapps, {:bytes, 20}
end

defmodule Proto.Packets.UserClientVersionCheckReq do
  @moduledoc "0x0C65 NC_USER_CLIENT_VERSION_CHECK_REQ, client to server."
  use Proto.Packet, opcode: 0x0C65
  # official: sVersionKey
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
  # official: XTrapServerKeyLength
  field :xtrap_server_key_length, :u8
  # official: XTrapServerKey
  field :xtrap_server_key, {:char, 1}
end
