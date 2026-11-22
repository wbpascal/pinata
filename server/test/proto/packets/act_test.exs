defmodule Proto.Packets.ActTest do
  use ExUnit.Case, async: true

  alias Proto.Packets.{ActSomeonewhisperCmd, ActWhisperfailAck, ActWhisperReq, ActWhispersuccessAck}
  alias Proto.Packets.{ActChatReq, ActShoutCmd, ActSomeonechatCmd, ActSomeoneshoutCmd}

  # scenario 14 (26_11_15_14_second-client-in-sight, lines 707 to 709) and scenario 45 (lines 1005, 1006)
  @req14 Base.decode16!("0054657374313233350000000000000000000000000d78313420776869737065722042", case: :lower)
  @cmd14 Base.decode16!("005831344200000000000000000000000000000000540d78313420776869737065722042", case: :lower)
  @ack14 Base.decode16!("0054657374313233350000000000000000000000000d78313420776869737065722042", case: :lower)
  @req45 Base.decode16!("005834354e6f626f647900000000000000000000000b7834352077686973706572", case: :lower)
  @fail45 Base.decode16!("690f5834354e6f626f64790000000000000000000000", case: :lower)

  test "captured whisper requests decode" do
    assert {:ok, %ActWhisperReq{item_link_count: 0, receiver: "Test1235", content: "x14 whisper B", links: ""}} =
             ActWhisperReq.decode(@req14)

    assert {:ok, %ActWhisperReq{item_link_count: 0, receiver: "X45Nobody", content: "x45 whisper", links: ""}} =
             ActWhisperReq.decode(@req45)
  end

  test "captured server payloads encode" do
    cmd = %ActSomeonewhisperCmd{item_link_count: 0, talker: "X14B", flag: 0x54, content: "x14 whisper B", links: ""}
    assert ActSomeonewhisperCmd.encode(cmd) == @cmd14

    ack = %ActWhispersuccessAck{item_link_count: 0, receiver: "Test1235", content: "x14 whisper B", links: ""}
    assert ActWhispersuccessAck.encode(ack) == @ack14

    assert ActWhisperfailAck.encode(%ActWhisperfailAck{error: 0x0F69, receiver: "X45Nobody"}) == @fail45
  end

  test "the size must match the item links" do
    name = Proto.Packet.pad("Test1235", 20)
    assert {:error, :bad_size} = ActWhisperReq.decode(<<1, name::binary, 2, "hi">>)
    assert {:error, :bad_size} = ActWhisperReq.decode(<<0, name::binary, 2, "hi", 0>>)
    links = :binary.copy(<<0xAB>>, 0x67)

    assert {:ok, %ActWhisperReq{item_link_count: 1, links: ^links}} =
             ActWhisperReq.decode(<<1, name::binary, 2, "hi", links::binary>>)
  end

  # scenario 45 (line 844 the shout, line 1280 an NPC line) and the captured GM command line
  test "captured chat and shout payloads" do
    hex = &Base.decode16!(&1, case: :lower)

    assert {:ok, %ActShoutCmd{item_link_count: 0, content: "x45 shout A", links: ""}} =
             ActShoutCmd.decode(hex.("000b7834352073686f75742041"))

    shout = %ActSomeoneshoutCmd{item_link_count: 0, speaker: "X45A", flag: 0x64, content: "x45 shout A", links: ""}

    assert ActSomeoneshoutCmd.encode(shout) ==
             hex.("005834354100000000000000000000000000000000640b7834352073686f75742041")

    assert {:ok, %ActChatReq{content: "&adminlevel"}} = ActChatReq.decode(hex.("000b2661646d696e6c6576656c"))

    npc = hex.("0064171a00000057656c636f6d652c206e69636520746f206d65657420796f752e")

    assert {:ok,
            %ActSomeonechatCmd{
              handle: 0x1764,
              len: 26,
              flag: 0,
              font_color: 0,
              balloon_color: 0,
              content: "Welcome, nice to meet you.",
              links: ""
            } = cmd} = ActSomeonechatCmd.decode(npc)

    assert ActSomeonechatCmd.encode(cmd) == npc
  end

  test "the chat size must match the item links" do
    assert {:error, :bad_size} = ActChatReq.decode(<<1, 2, "hi">> <> :binary.copy(<<0xAB>>, 0x66))
    links = :binary.copy(<<0xAB>>, 0x67)
    assert {:ok, %ActChatReq{item_link_count: 1, links: ^links}} = ActChatReq.decode(<<1, 2, "hi", links::binary>>)
  end
end
