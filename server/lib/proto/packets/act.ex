defmodule Proto.Packets.ActWhisperReq do
  @moduledoc "0x200C NC_ACT_WHISPER_REQ, client to server (sent to WorldManager): a whisper to a character by name, with its item links."
  use Proto.Packet, opcode: 0x200C
  # official: itemLinkDataCount
  field :item_link_count, :u8
  # official: receiver
  field :receiver, {:char, 20}
  # official: len, content
  field :content, {:counted, :u8}
  # the item links, 0x67 opaque bytes each
  field :links, {:records, :item_link_count, 0x67}
end

defmodule Proto.Packets.ActSomeonewhisperCmd do
  @moduledoc """
  0x200D NC_ACT_SOMEONEWHISPER_CMD, server to client: a whisper to the receiver. Bit 0 of the flag is the GM colour,
  always 0 until GM chat colour is built; the original leaves bits 1 to 7 as its stack held them (P02-B29), we send 0.
  """
  use Proto.Packet, opcode: 0x200D
  # official: itemLinkDataCount
  field :item_link_count, :u8
  # official: talker
  field :talker, {:char, 20}
  # official: flag
  field :flag, :u8
  # official: len, content
  field :content, {:counted, :u8}
  field :links, {:records, :item_link_count, 0x67}
end

defmodule Proto.Packets.ActWhisperfailAck do
  @moduledoc "0x200E NC_ACT_WHISPERFAIL_ACK, server to client: a refused whisper (0x0F69 receiver not found, 0x0F6B text too long)."
  use Proto.Packet, opcode: 0x200E
  # official: ErrorType
  field :error, :u16
  # official: receiver
  field :receiver, {:char, 20}
end

defmodule Proto.Packets.ActWhispersuccessAck do
  @moduledoc """
  0x200F NC_ACT_WHISPERSUCCESS_ACK, server to client: the echo of a delivered whisper, with the receiver's stored
  spelling. The original never writes the count of the empty-whisper echo (W04-B4); we send 0.
  """
  use Proto.Packet, opcode: 0x200F
  # official: itemLinkDataCount
  field :item_link_count, :u8
  # official: receiver
  field :receiver, {:char, 20}
  # official: len, content
  field :content, {:counted, :u8}
  field :links, {:records, :item_link_count, 0x67}
end

defmodule Proto.Packets.ActStopReq do
  @moduledoc "0x2012 NC_ACT_STOP_REQ, client to server: the player stops at the point the client shows."
  use Proto.Packet, opcode: 0x2012
  # official: loc.x
  field :x, :u32
  # official: loc.y
  field :y, :u32
end

defmodule Proto.Packets.ActSomeonestopCmd do
  @moduledoc "0x2013 NC_ACT_SOMEONESTOP_CMD, server to client: the object stopped at the server's position."
  use Proto.Packet, opcode: 0x2013
  # official: handle
  field :handle, :u16
  # official: loc.x
  field :x, :u32
  # official: loc.y
  field :y, :u32
end

defmodule Proto.Packets.ActMovewalkCmd do
  @moduledoc "0x2017 NC_ACT_MOVEWALK_CMD, client to server: the player walks from `from` to `to`."
  use Proto.Packet, opcode: 0x2017
  # official: from.x, from.y
  field :from_x, :u32
  field :from_y, :u32
  # official: to.x, to.y
  field :to_x, :u32
  field :to_y, :u32
end

defmodule Proto.Packets.ActSomeonemovewalkCmd do
  @moduledoc """
  0x2018 NC_ACT_SOMEONEMOVEWALK_CMD, server to client: the object walks from `from` (the server's position) to `to`.
  The original leaves `moveattr` as its buffer held it except bit 0 (Z02-B2); we send 0.
  """
  use Proto.Packet, opcode: 0x2018
  # official: handle
  field :handle, :u16
  # official: from.x, from.y
  field :from_x, :u32
  field :from_y, :u32
  # official: to.x, to.y
  field :to_x, :u32
  field :to_y, :u32
  # official: speed
  field :speed, :u16
  # official: moveattr
  field :moveattr, :u16
end

defmodule Proto.Packets.ActMoverunCmd do
  @moduledoc "0x2019 NC_ACT_MOVERUN_CMD, client to server: the player runs from `from` to `to`."
  use Proto.Packet, opcode: 0x2019
  # official: from.x, from.y
  field :from_x, :u32
  field :from_y, :u32
  # official: to.x, to.y
  field :to_x, :u32
  field :to_y, :u32
end

defmodule Proto.Packets.ActSomeonemoverunCmd do
  @moduledoc """
  0x201A NC_ACT_SOMEONEMOVERUN_CMD, server to client: the object runs from `from` (the server's position) to `to`.
  The original leaves `moveattr` as its buffer held it except bit 0 (Z02-B2); we send 0.
  """
  use Proto.Packet, opcode: 0x201A
  # official: handle
  field :handle, :u16
  # official: from.x, from.y
  field :from_x, :u32
  field :from_y, :u32
  # official: to.x, to.y
  field :to_x, :u32
  field :to_y, :u32
  # official: speed
  field :speed, :u16
  # official: moveattr
  field :moveattr, :u16
end

defmodule Proto.Packets.ActMovefailAck do
  @moduledoc "0x201B NC_ACT_MOVEFAIL_ACK, server to client: a refused move or stop; the player stands at the server's position."
  use Proto.Packet, opcode: 0x201B
  # official: back.x
  field :x, :u32
  # official: back.y
  field :y, :u32
end

defmodule Proto.Packets.ActReinforceStopCmd do
  @moduledoc "0x204A NC_ACT_REINFORCE_STOP_CMD, server to client: the server pulled the player back to this point."
  use Proto.Packet, opcode: 0x204A
  # official: loc.x
  field :x, :u32
  # official: loc.y
  field :y, :u32
end

defmodule Proto.Packets.ActChatReq do
  @moduledoc "0x2001 NC_ACT_CHAT_REQ, client to server: a line of normal chat, with its item links."
  use Proto.Packet, opcode: 0x2001
  # official: itemLinkDataCount
  field :item_link_count, :u8
  # official: len, content
  field :content, {:counted, :u8}
  # the item links, 0x67 opaque bytes each
  field :links, {:records, :item_link_count, 0x67}
end

defmodule Proto.Packets.ActSomeonechatCmd do
  @moduledoc """
  0x2002 NC_ACT_SOMEONECHAT_CMD, server to client: a line of normal chat of the object of the handle. Bit 0 of the
  flag is the GM colour, bit 1 the chat window; the caller keeps `len` equal to the size of `content`.
  """
  use Proto.Packet, opcode: 0x2002
  # official: itemLinkDataCount
  field :item_link_count, :u8
  # official: handle
  field :handle, :u16
  # official: len
  field :len, :u8
  # official: flag
  field :flag, :u8
  # official: nChatFontColorID
  field :font_color, :u8
  # official: nChatBalloonColorID
  field :balloon_color, :u8
  # official: content
  field :content, {:records, :len, 1}
  field :links, {:records, :item_link_count, 0x67}
end

defmodule Proto.Packets.ActShoutCmd do
  @moduledoc "0x201E NC_ACT_SHOUT_CMD, client to server: a shout to the map, with its item links."
  use Proto.Packet, opcode: 0x201E
  # official: itemLinkDataCount
  field :item_link_count, :u8
  # official: len, content
  field :content, {:counted, :u8}
  field :links, {:records, :item_link_count, 0x67}
end

defmodule Proto.Packets.ActSomeoneshoutCmd do
  @moduledoc """
  0x201F NC_ACT_SOMEONESHOUT_CMD, server to client: a shout of the speaker. Bit 0 of the flag is the GM colour, bit 1
  isMob; the original leaves bits 2 to 7 as its shared buffer held them (P02-B29), we send 0.
  """
  use Proto.Packet, opcode: 0x201F
  # official: itemLinkDataCount
  field :item_link_count, :u8
  # official: speaker
  field :speaker, {:char, 20}
  # official: flag
  field :flag, :u8
  # official: len, content
  field :content, {:counted, :u8}
  field :links, {:records, :item_link_count, 0x67}
end
