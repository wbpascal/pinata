defmodule ProtoTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Proto.Packets.MiscSeedAck

  test "decode results" do
    assert Proto.decode(<<0xFF, 0xFF>>) == {:error, :unknown_opcode}
    assert Proto.decode(<<0x07, 0x08, 1>>) == {:error, :bad_size}
    assert Proto.decode(<<7>>) == {:error, :bad_size}
    assert Proto.decode(<<>>) == {:error, :bad_size}
    assert Proto.decode(<<0x07, 0x08, 0x6B, 0x01>>) == {:ok, %MiscSeedAck{seed: 363}}
  end

  test "encode and framing bytes (README 1.4, 1.5)" do
    assert Proto.encode(%MiscSeedAck{seed: 363}) == <<0x07, 0x08, 0x6B, 0x01>>
    assert Proto.Framing.frame(Proto.encode(%MiscSeedAck{seed: 0x016B})) == {:ok, <<0x04, 0x07, 0x08, 0x6B, 0x01>>}
    assert Proto.Framing.frame(Proto.encode(%Proto.Packets.MiscHeartbeatReq{})) == {:ok, <<0x02, 0x04, 0x08>>}
    assert Proto.Framing.frame(Proto.encode(%Proto.Packets.MiscHeartbeatAck{})) == {:ok, <<0x02, 0x05, 0x08>>}
  end

  test "registry agrees with the modules" do
    {:ok, mods} = :application.get_key(:pinata, :modules)

    defined =
      for mod <- mods,
          Code.ensure_loaded?(mod),
          function_exported?(mod, :opcode, 0),
          function_exported?(mod, :__packet__, 0),
          do: mod

    assert Enum.sort(defined) == Enum.sort(Proto.Packets.all())
    for mod <- defined, do: assert(Proto.Packets.fetch(mod.opcode()) == {:ok, mod})
  end

  property "decode of random binaries" do
    check all bin <- StreamData.binary() do
      assert match?({:ok, %_{}}, Proto.decode(bin)) or
               Proto.decode(bin) in [{:error, :unknown_opcode}, {:error, :bad_size}]
    end
  end

  property "decode of registered opcodes with random payload" do
    check all mod <- StreamData.member_of(Proto.Packets.all()), payload <- StreamData.binary() do
      result = Proto.decode(<<mod.opcode()::little-16, payload::binary>>)
      assert match?({:ok, %_{}}, result) or result == {:error, :bad_size}
    end
  end
end
