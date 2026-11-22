defmodule Proto.RoundtripTest.Fixtures.World do
  use Proto.Packet
  field :world_no, :u8
  field :world_name, {:char, 16}
  field :status, :u8
end

defmodule Proto.RoundtripTest.Fixtures.Avatar do
  use Proto.Packet
  field :chrregnum, :u32
  field :name, {:char, 20}
  field :level, :i16
  field :slot, :u8
  field :loginmap, {:char, 12}
  field :delinfo, {:bytes, 5}
  bits gender: 1, chrclass: 5, race: 2
  field :hairtype, :u8
  field :haircolor, :u8
  field :faceshape, :u8
  field :equip, {:u16s, 20}
  field :equip_upgrade, {:bytes, 3}
  field :kq_handle, :u32
  field :kq_map_name, {:char, 12}
  field :kq_coord_x, :u32
  field :kq_coord_y, :u32
  field :kq_date, :u32
  field :char_id_change_flags, {:bytes, 2}
  field :char_id_change_row_no, :u32
  field :tutorial_state, :u32
  field :tutorial_step, :u8
end

defmodule Proto.RoundtripTest.Fixtures.UserClientVersionCheckReq do
  use Proto.Packet, opcode: 0x0C65
  field :s_version_key, {:char, 64}
end

defmodule Proto.RoundtripTest.Fixtures.UserLoginAck do
  use Proto.Packet, opcode: 0x0C0A
  array :worlds, Proto.RoundtripTest.Fixtures.World, count: :u8
end

defmodule Proto.RoundtripTest.Fixtures.UserWorldselectAck do
  use Proto.Packet, opcode: 0x0C0C
  field :world_status, :u8
  field :wm_ip, {:char, 16}
  field :wm_port, :u16
  field :validate, {:u16s, 32}
end

defmodule Proto.RoundtripTest.Fixtures.UserLoginworldAck do
  use Proto.Packet, opcode: 0x0C14
  field :worldmanager, :u16
  array :avatar, Proto.RoundtripTest.Fixtures.Avatar, count: :u8
end

defmodule Proto.RoundtripTest.Fixtures.AvatarCreateReq do
  use Proto.Packet, opcode: 0x1401
  field :slot, :u8
  field :name, {:char, 20}
  field :race_class_gender, :u8
  field :hair_colour_face, {:bytes, 3}
end

defmodule Proto.RoundtripTest.Fixtures.AvatarCreatesuccAck do
  use Proto.Packet, opcode: 0x1406
  field :flag, :u8
  field :avatar, Proto.RoundtripTest.Fixtures.Avatar
end

defmodule Proto.RoundtripTest.Fixtures.AvatarEraseReq do
  use Proto.Packet, opcode: 0x1407
  field :slot, :u8
end

defmodule Proto.RoundtripTest.Fixtures.Wide do
  use Proto.Packet
  field :big, :u64
  field :small, :i8
  field :text, {:counted, :u8}
end

defmodule Proto.RoundtripTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Proto.RoundtripTest.Fixtures, as: F

  @fixtures "test/fixtures/packet_codec.json" |> File.read!() |> JSON.decode!()

  @modules %{
    "0x0807" => Proto.Packets.MiscSeedAck,
    "0x0C65" => F.UserClientVersionCheckReq,
    "0x0C0A" => F.UserLoginAck,
    "0x0C0C" => F.UserWorldselectAck,
    "0x0C14" => F.UserLoginworldAck,
    "0x1401" => F.AvatarCreateReq,
    "0x1406" => F.AvatarCreatesuccAck,
    "0x1407" => F.AvatarEraseReq
  }

  defp check("0x0807", p, payload), do: assert(p.seed == :binary.decode_unsigned(payload, :little))
  defp check("0x0C65", p, _), do: assert(p.s_version_key == "20151116141627")

  defp check("0x0C0A", p, _) do
    assert [%{world_no: 0, world_name: "INITIO", status: 6}] = p.worlds
  end

  defp check("0x0C0C", p, _) do
    assert %{world_status: 6, wm_ip: "172.16.42.214", wm_port: 9110} = p
    assert length(p.validate) == 32
  end

  defp check("0x0C14", p, _) do
    assert p.worldmanager == 0x2710
    assert [a] = p.avatar
    assert %{chrregnum: 2, name: "Test1235", level: 120, slot: 0, loginmap: "RouN"} = a
    # the four bytes after the first one are uninitialised garbage the original server really sent
    assert a.delinfo == <<0x00, 0x98, 0xD9, 0x72, 0x10>>
  end

  defp check("0x1401", p, _) do
    assert %{slot: 1, name: "CharCreateTest", race_class_gender: 0x19, hair_colour_face: <<1, 1, 5>>} = p
  end

  defp check("0x1406", p, _) do
    assert p.flag == 1
    assert %{chrregnum: 3, name: "CharCreateTest", level: 1, slot: 1, loginmap: "RouN"} = p.avatar
  end

  defp check("0x1407", p, _), do: assert(p.slot == 1)

  for f <- @fixtures do
    @fixture f

    test "#{f["server"]} #{f["op"]} #{f["name"]}" do
      mod = Map.fetch!(@modules, @fixture["op"])
      payload = Base.decode16!(@fixture["payload"], case: :lower)
      assert mod.opcode() == String.to_integer(String.trim_leading(@fixture["op"], "0x"), 16)
      assert {:ok, p} = mod.decode(payload)
      check(@fixture["op"], p, payload)
      assert {:error, :bad_size} = mod.decode(payload <> <<0>>)
      assert {:error, :bad_size} = mod.decode(binary_part(payload, 0, byte_size(payload) - 1))

      if @fixture["op"] == "0x0C65" do
        # known loss: char[64] keeps only the bytes before the first NUL, the garbage after it is dropped
        assert byte_size(mod.encode(p)) == 64
        refute mod.encode(p) == payload
      else
        assert mod.encode(p) == payload
      end
    end
  end

  test "u64, i8 and counted bytes" do
    p = %F.Wide{big: 0x0102030405060708, small: -2, text: "From"}
    bytes = <<8, 7, 6, 5, 4, 3, 2, 1, 0xFE, 4, "From">>
    assert F.Wide.encode(p) == bytes
    assert F.Wide.decode(bytes) == {:ok, p}
    assert F.Wide.decode(<<0::64, 0, 5, "From">>) == {:error, :bad_size}
    assert F.Wide.decode(<<0::64, 0, 0>>) == {:ok, %F.Wide{big: 0, small: 0, text: ""}}
    assert F.Wide.__packet__().fields == [big: "u64", small: "i8", text: "bytes[count: u8]"]
  end

  property "decode of random binaries never raises" do
    check all mod <- StreamData.member_of([F.World, F.Avatar, F.Wide | Map.values(@modules)]),
              bin <- StreamData.binary() do
      result = mod.decode(bin)
      assert match?({:ok, %^mod{}}, result) or result == {:error, :bad_size}
    end
  end
end
