defmodule Proto.Packets.UserTest do
  use ExUnit.Case, async: true

  alias Proto.Packets.{
    UserClientRightversionCheckAck,
    UserConnectcutCmd,
    UserLoginAck,
    UserLoginfailAck,
    UserLoginworldReq,
    UserLoginworldfailAck,
    UserUsLoginReq,
    UserWorldselectAck,
    UserWorldselectReq,
    UserXtrapAck,
    UserXtrapReq,
    WorldInfo
  }

  defp roundtrip(mod, payload) do
    assert {:ok, packet} = mod.decode(payload)
    assert mod.encode(packet) == payload
    packet
  end

  test "world list" do
    payload = Base.decode16!("0100494e4954494f0000000000000000000006", case: :lower)

    assert %UserLoginAck{worlds: [%WorldInfo{world_no: 0, name: "INITIO", status: 6}]} =
             roundtrip(UserLoginAck, payload)
  end

  test "small packets" do
    assert %UserClientRightversionCheckAck{xtrap_server_key_length: 1} =
             roundtrip(UserClientRightversionCheckAck, <<1, 0>>)

    assert %UserXtrapAck{success: 1} = roundtrip(UserXtrapAck, <<1>>)
    assert %UserLoginfailAck{error: 0x45} = roundtrip(UserLoginfailAck, <<0x45, 0>>)
    assert %UserConnectcutCmd{error: 0x683} = roundtrip(UserConnectcutCmd, <<0x83, 0x06>>)
  end

  test "xtrap request" do
    payload = Base.decode16!("1d3333423534334230434136453743343145354431443036353133303700", case: :lower)
    assert %UserXtrapReq{key_length: 29, key: "33B543B0CA6E7C41E5D1D0651307"} = roundtrip(UserXtrapReq, payload)
  end

  test "login request" do
    line =
      "test/replay/transcripts/26_11_15_login-logout.txt"
      |> File.read!()
      |> String.split("\n")
      |> Enum.at(5)

    [_, _, _, "0x0C5A", hex] = String.split(line, " ")
    payload = Base.decode16!(hex, case: :mixed)
    assert byte_size(payload) == 316
    packet = roundtrip(UserUsLoginReq, payload)
    assert packet.user_name == "admin"
    assert packet.password == "21232f297a57a5a743894a0e4a801fc3"
    assert UserUsLoginReq.decode(binary_part(payload, 0, 315)) == {:error, :bad_size}
  end

  test "world select" do
    assert %UserWorldselectReq{world_no: 0} = roundtrip(UserWorldselectReq, <<0>>)

    ack =
      Base.decode16!(
        "063137322e31362e34322e32313400000096239a26206c2f311372604cf83e66196b0fa4098f01b7337526cd6d8247da3f5a487014dd1039052c086948e030a52ecb372b5d0312470e066c5432377bd95da97c",
        case: :lower
      )

    assert %UserWorldselectAck{world_status: 6, ip: "172.16.42.214", port: 9110, validate: words} =
             roundtrip(UserWorldselectAck, ack)

    assert length(words) == 32
  end

  test "login at the world" do
    req =
      Base.decode16!(
        "61646d696e00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000009a26206c2f311372604cf83e66196b0fa4098f01b7337526cd6d8247da3f5a487014dd1039052c086948e030a52ecb372b5d0312470e066c5432377bd95da97c",
        case: :lower
      )

    assert %UserLoginworldReq{user_name: "admin", validate: words} = roundtrip(UserLoginworldReq, req)
    assert length(words) == 32
    assert %UserLoginworldfailAck{error: 0x44} = roundtrip(UserLoginworldfailAck, <<0x44, 0>>)
  end
end
