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
