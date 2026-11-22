defmodule Proto.Packets.ActTest do
  use ExUnit.Case, async: true

  alias Proto.Packets.{ActSomeonewhisperCmd, ActWhisperfailAck, ActWhisperReq, ActWhispersuccessAck}

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
end
