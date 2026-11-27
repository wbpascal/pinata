defmodule Proto.Packets.WorldEntryTest do
  use ExUnit.Case, async: true

  alias Proto.Packets.ShortCutData

  @idle "26_11_15_idle_in_world"

  defp capture(opcode) do
    transcript = "../../replay/transcripts/#{@idle}.txt" |> Path.expand(__DIR__) |> Replay.Transcript.read!()
    Enum.find(transcript.packets, &(&1.opcode == opcode and &1.dir == :server)).payload
  end

  test "the captured option pushes 0x7032, 0x7033, 0x7034 decode and encode to the same bytes" do
    for opcode <- [0x7032, 0x7033, 0x7034] do
      body = <<opcode::little-16, capture(opcode)::binary>>
      assert {:ok, packet} = Proto.decode(body)
      assert IO.iodata_to_binary(Proto.encode(packet)) == body
    end

    {:ok, packet} = Proto.decode(<<0x32, 0x70, capture(0x7032)::binary>>)

    assert [%ShortCutData{slot: 0, code: 4, value: 0}, _, %ShortCutData{slot: 4, code: 3, value: 4021}, _, _] =
             packet.shortcuts
  end

  test "the placeholders encode to count 0" do
    assert IO.iodata_to_binary(Proto.encode(WorldManager.Placeholders.shortcut_data())) == <<0x32, 0x70, 0, 0>>
    assert IO.iodata_to_binary(Proto.encode(WorldManager.Placeholders.key_map())) == <<0x33, 0x70, 0, 0>>
    assert IO.iodata_to_binary(Proto.encode(WorldManager.Placeholders.game_option())) == <<0x34, 0x70, 0, 0>>
  end
end
