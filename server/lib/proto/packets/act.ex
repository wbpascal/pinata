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
