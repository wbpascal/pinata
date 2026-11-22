defmodule Proto.Packets.Tm do
  @moduledoc "C `struct tm` (36 bytes, nested in 0x0849 and 0x581C): `mon` 0-based, `year` minus 1900, `wday` 0 = Sunday, `yday` 0-based."
  use Proto.Packet
  # official: tm_sec … tm_isdst
  field :sec, :i32
  field :min, :i32
  field :hour, :i32
  field :mday, :i32
  field :mon, :i32
  field :year, :i32
  field :wday, :i32
  field :yday, :i32
  field :isdst, :i32
end

defmodule Proto.Packets.CharOptionGetShortcutsizeReq do
  @moduledoc "0x7004 NC_CHAR_OPTION_GET_SHORTCUTSIZE_REQ, empty, client to server (sent to WorldManager)."
  use Proto.Packet, opcode: 0x7004
end

defmodule Proto.Packets.CharOptionGetShortcutsizeAck do
  @moduledoc "0x7005 NC_CHAR_OPTION_GET_SHORTCUTSIZE_ACK, server to client: the stored shortcut bar sizes."
  use Proto.Packet, opcode: 0x7005
  # official: bSuccess
  field :success, :u8
  # official: Data.Data
  field :data, {:bytes, 24}
end

defmodule Proto.Packets.CharOptionGetWindowposReq do
  @moduledoc "0x700C NC_CHAR_OPTION_GET_WINDOWPOS_REQ, empty, client to server (sent to WorldManager)."
  use Proto.Packet, opcode: 0x700C
end

defmodule Proto.Packets.CharOptionGetWindowposAck do
  @moduledoc "0x700D NC_CHAR_OPTION_GET_WINDOWPOS_ACK, server to client: the stored window positions."
  use Proto.Packet, opcode: 0x700D
  # official: bSuccess
  field :success, :u8
  # official: Data.Data
  field :data, {:bytes, 392}
end

defmodule Proto.Packets.PrisonGetReq do
  @moduledoc "0x7C06 NC_PRISON_GET_REQ, empty, client to server (sent to WorldManager)."
  use Proto.Packet, opcode: 0x7C06
end

defmodule Proto.Packets.PrisonGetAck do
  @moduledoc "0x7C07 NC_PRISON_GET_ACK, server to client: the prison minutes left (0x0DB1: not in prison)."
  use Proto.Packet, opcode: 0x7C07
  # official: err
  field :error, :u16
  # official: nMinute
  field :minutes, :u16
end

defmodule Proto.Packets.KqListRefreshReq do
  @moduledoc "0x581B NC_KQ_LIST_REFRESH_REQ, empty, client to server (sent to WorldManager)."
  use Proto.Packet, opcode: 0x581B
end

defmodule Proto.Packets.KqListTimeAck do
  @moduledoc "0x581C NC_KQ_LIST_TIME_ACK, server to client: the server time before the Kingdom Quest list."
  use Proto.Packet, opcode: 0x581C
  # official: ServerTime
  field :server_time, :i32
  # official: tm_ServerTime
  field :tm, Proto.Packets.Tm
end

defmodule Proto.Packets.CharGuildAcademyCmd do
  @moduledoc "0x1097 NC_CHAR_GUILD_ACADEMY_CMD, server to client: the guild academy of the character (milestone 8)."
  use Proto.Packet, opcode: 0x1097
  # official: nGuildAcademyNo
  field :academy_no, :u32
  # official: isGuildAcademyMember
  field :is_member, :u8
end

defmodule Proto.Packets.CharGuildCmd do
  @moduledoc "0x1012 NC_CHAR_GUILD_CMD, server to client: the guild of the character (milestone 8)."
  use Proto.Packet, opcode: 0x1012
  # official: nGuildNo
  field :guild_no, :u32
end

defmodule Proto.Packets.HolyPromiseListCmd do
  @moduledoc "0x9414 NC_HOLY_PROMISE_LIST_CMD, server to client: the holy promise partner and members (milestone 11)."
  use Proto.Packet, opcode: 0x9414
  # official: UpInfo.PromiseCharID
  field :up_name, {:char, 20}
  # official: UpInfo.LogonInfo
  field :up_logon, :u32
  # official: UpInfo.Level
  field :up_level, :u8
  # official: UpInfo.Flags
  field :up_flags, :u8
  # official: nPart
  field :part, :u8
  # official: MemberCount
  field :count, :u16
end

defmodule Proto.Packets.KqJoiningAlarmList do
  @moduledoc "0x5826 NC_KQ_JOINING_ALARM_LIST, server to client: the Kingdom Quests open to join (milestone 10)."
  use Proto.Packet, opcode: 0x5826
  # official: nNumOfKQ
  field :count, :u16
end

defmodule Proto.Packets.CharClientNewbieGuideViewListCmd do
  @moduledoc "0x10D9 NC_CHAR_CLIENT_NEWBIE_GUIDE_VIEW_LIST_CMD, server to client: the newbie guides already seen."
  use Proto.Packet, opcode: 0x10D9
  # official: nGuideViewNum
  field :count, :u8
end

defmodule Proto.Packets.MiscServerTimeNotifyCmd do
  @moduledoc "0x0849 NC_MISC_SERVER_TIME_NOTIFY_CMD, server to client: the local time of the server and its time zone in hours."
  use Proto.Packet, opcode: 0x0849
  # official: dCurrentTM
  field :tm, Proto.Packets.Tm
  # official: nTimeZone
  field :time_zone, :i8
end

defmodule Proto.Packets.MapLinkendClientCmd do
  @moduledoc "0x182A NC_MAP_LINKEND_CLIENT_CMD, server to client: the map link is complete. The original never writes the byte (P02-B2); we send 0."
  use Proto.Packet, opcode: 0x182A
  field :unused, :u8
end
