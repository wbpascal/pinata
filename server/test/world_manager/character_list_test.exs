defmodule WorldManager.CharacterListTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  import ExUnit.CaptureLog

  alias Proto.Packets.{
    MiscGametimeReq,
    UserAvatarListReq,
    UserClientVersionCheckReq,
    UserLoginworldAck,
    UserLoginworldReq,
    UserUsLoginReq,
    UserWorldselectAck,
    UserWorldselectReq,
    UserXtrapReq
  }

  @key "20151116141627"
  @login {~c"127.0.0.1", 9010}
  @wm {~c"127.0.0.1", 9110}
  @equip_slots [1, 24, 12, 7, 10, 19, 21, 22, 20, 8, 27, 28, 26, 11, 13, 9, 17, 18, 25, 29]

  setup do
    Persistence.Repo.active().query!("DELETE FROM accounts")
    {:ok, id} = Persistence.create_account("admin", "pw")
    %{id: id}
  end

  defp use_test_clock(microseconds) do
    Application.put_env(:pinata, :clock_source, TestClock)
    TestClock.set(microseconds)
    on_exit(fn -> Application.delete_env(:pinata, :clock_source) end)
  end

  defp connect({host, port}) do
    client = TestClient.connect(host, port)
    {:ok, <<0x07, 0x08, _::binary>>, client} = TestClient.recv_raw(client)
    client
  end

  defp send!(client, packet) do
    {:ok, client} = TestClient.send_packet(client, packet)
    client
  end

  defp recv!(client, body) do
    assert {:ok, ^body, client} = TestClient.recv_raw(client)
    client
  end

  defp select(name) do
    client = connect(@login)
    client = client |> send!(%UserClientVersionCheckReq{version_key: @key}) |> recv!(<<0x67, 0x0C, 1, 0>>)

    client =
      client
      |> send!(%UserUsLoginReq{user_name: name, password: "pw", spawnapps: <<0::160>>})
      |> send!(%UserXtrapReq{key_length: 0, key: ""})
      |> recv!(<<0x05, 0x0C, 1>>)

    assert {:ok, <<0x0A, 0x0C, _::binary>>, client} = TestClient.recv_raw(client)
    client = send!(client, %UserWorldselectReq{world_no: 0})
    assert {:ok, %UserWorldselectAck{world_status: 6, validate: key}, client} = TestClient.recv(client)
    {key, client}
  end

  defp world_login(name \\ "admin") do
    {key, _login} = select(name)
    @wm |> connect() |> send!(%UserLoginworldReq{user_name: name, validate: key})
  end

  defp list(client) do
    assert {:ok, body, client} = TestClient.recv_raw(client)
    {body, client}
  end

  defp decoded(client) do
    assert {:ok, %UserLoginworldAck{} = ack, client} = TestClient.recv(client)
    {ack, client}
  end

  test "an empty list" do
    {<<0x14, 0x0C, handle::little-16, 0>>, _client} = world_login() |> list()
    assert handle in 0..0xFFFF
  end

  test "a full list", %{id: id} do
    use_test_clock(1_794_732_634_000_000)

    for slot <- [3, 0, 5, 1, 4, 2] do
      Factory.character(id, %{id: slot + 10, slot: slot, name: "Other#{slot}"})
    end

    Persistence.Repo.active().query!("DELETE FROM characters WHERE slot = 0")

    c =
      Factory.character(id, %{
        id: 2,
        slot: 0,
        name: "Test1235",
        level: 120,
        race: 2,
        class: 11,
        gender: 1,
        hair: 4,
        kq_map: "RouN",
        kq_x: 6477,
        kq_y: 9844,
        kq_date: ~U[2026-11-13 11:57:15Z]
      })

    for {slot, item} <- [{10, 1250}, {8, 35_740}, {25, 30_817}], do: Factory.item(c.id, slot, item)

    {<<0x14, 0x0C, _::little-16, 6, records::binary>>, _client} = world_login() |> list()
    assert byte_size(records) == 6 * 130
    slots = for <<r::binary-130 <- records>>, do: :binary.at(r, 26)
    assert slots == [0, 1, 2, 3, 4, 5]

    # the AVATAR of the capture with the uninitialised delinfo bytes zeroed
    [line] =
      "../replay/transcripts/26_11_15_login-logout.txt"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> String.split("\n")
      |> Enum.filter(&String.contains?(&1, "wm#1 S 0x0C14"))

    hex = line |> String.split(" ") |> List.last()
    <<_::binary-3, expected::binary-130, _::binary>> = Base.decode16!(hex, case: :mixed)
    <<head::binary-0x28, _::binary-4, tail::binary>> = expected
    assert binary_part(records, 0, 130) == head <> <<0, 0, 0, 0>> <> tail
  end

  test "a character that has not started the tutorial goes to RouT", %{id: id} do
    Factory.character(id, %{tutorial_state: 0, login_map: "RouN"})
    {%{avatars: [avatar]}, _client} = world_login() |> decoded()
    assert avatar.loginmap == "RouT"
    assert avatar.tutorial_state == 0
  end

  test "equipment and upgrades are mapped", %{id: id} do
    c = Factory.character(id)
    upgrades = %{10 => 1, 12 => 2, 7 => 3, 19 => 4, 21 => 5}
    for slot <- [15 | @equip_slots], do: Factory.item(c.id, slot, 1000 + slot, Map.get(upgrades, slot, 0))

    {<<0x14, 0x0C, _::little-16, 1, record::binary>>, _client} = world_login() |> list()

    assert for(<<v::little-16 <- binary_part(record, 0x30, 40)>>, do: v) ==
             [
               1001,
               1024,
               1012,
               1007,
               1010,
               1019,
               1021,
               1022,
               1020,
               1008,
               1027,
               1028,
               1026,
               1011,
               1013,
               1009,
               1017,
               1018,
               1025,
               1029
             ]

    assert binary_part(record, 0x58, 3) == <<0x21, 0x43, 0xF5>>
  end

  test "other accounts and other worlds are not listed", %{id: id} do
    {:ok, other} = Persistence.create_account("other", "pw")
    Factory.character(other, %{name: "Alien"})
    Factory.character(id, %{world_id: 1, name: "Elsewhere"})
    {<<0x14, 0x0C, _::little-16, 0>>, _client} = world_login() |> list()
  end

  test "a database failure answers 0x0C15 and closes once" do
    Persistence.Repo.active().query!("ALTER TABLE characters RENAME TO characters_off")
    on_exit(fn -> Persistence.Repo.active().query!("ALTER TABLE characters_off RENAME TO characters") end)

    log =
      capture_log(fn ->
        client = world_login() |> recv!(<<0x15, 0x0C, 0x46, 0x00>>)
        assert {:error, :closed} = TestClient.recv_raw(client)
      end)

    assert log =~ "the database failed in list_characters"
  end

  test "0x0C1F lists again", %{id: id} do
    {<<0x14, 0x0C, handle::little-16, 0>>, client} = world_login() |> list()
    Factory.character(id, %{name: "Late"})
    client = send!(client, %UserAvatarListReq{})
    {ack, _client} = decoded(client)
    assert ack.worldmanager == handle
    assert [%{name: "Late"}] = ack.avatars
  end

  test "0x080D is answered with the local time" do
    use_test_clock(1_794_732_634_000_000)
    {_body, client} = world_login() |> list()
    client = send!(client, %MiscGametimeReq{})
    recv!(client, <<0x0E, 0x08, 9, 50, 34>>)
  end

  test "two sessions get different handles" do
    {:ok, _} = Persistence.create_account("second", "pw")
    {<<0x14, 0x0C, a::little-16, _::binary>>, _c1} = world_login() |> list()
    {<<0x14, 0x0C, b::little-16, _::binary>>, _c2} = world_login("second") |> list()
    assert a != b
  end
end
