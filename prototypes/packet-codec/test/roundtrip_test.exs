defmodule Proto.RoundtripTest do
  use ExUnit.Case, async: true

  @shapes [Proto.Hand, Proto.Macro, Proto.Gen]
  @fixtures "test/fixtures.json" |> File.read!() |> JSON.decode!()

  # "NC_USER_LOGIN_ACK" -> UserLoginAck
  defp module_for(shape, name) do
    parts =
      name
      |> String.replace_prefix("NC_", "")
      |> String.split("_")
      |> Enum.map(&String.capitalize/1)

    Module.concat(shape, Enum.join(parts))
  end

  # Known values of the capture (field names are identical in the three shapes for these fields).
  defp check("0x0807", p, payload),
    do: assert(p.seed == :binary.decode_unsigned(payload, :little))

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
    assert %{
             slot: 1,
             name: "CharCreateTest",
             race_class_gender: 0x19,
             hair_colour_face: <<1, 1, 5>>
           } = p
  end

  defp check("0x1406", p, _) do
    assert p.flag == 1
    assert %{chrregnum: 3, name: "CharCreateTest", level: 1, slot: 1, loginmap: "RouN"} = p.avatar
  end

  defp check("0x1407", p, _), do: assert(p.slot == 1)

  for shape <- @shapes, f <- @fixtures do
    @shape shape
    @fixture f
    if f["op"] == "0x0C65", do: @tag(:known_loss)

    test "#{inspect(shape)} #{f["server"]} #{f["op"]} #{f["name"]}" do
      mod = module_for(@shape, @fixture["name"])
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
end
