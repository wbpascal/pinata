defmodule WorldManager.CharacterCreateTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  import ExUnit.CaptureLog

  alias Proto.Packets.AvatarCreatesuccAck
  alias Proto.Packets.UserAvatarListReq
  alias Proto.Packets.UserClientVersionCheckReq
  alias Proto.Packets.UserLoginworldAck
  alias Proto.Packets.UserLoginworldReq
  alias Proto.Packets.UserUsLoginReq
  alias Proto.Packets.UserWorldselectAck
  alias Proto.Packets.UserWorldselectReq
  alias Proto.Packets.UserXtrapReq

  # case                         original         rebuild  bug
  # slot >= 6                    0x84             0x85     W01-B2
  # slot in use                  0x182 (no text)  0x85     D02-B1
  # invalid name                 0x84             0x82     W01-B2
  # class 26 below the level     0x84             0x83     W01-B2
  # class without defaults       0x181            0x83     (assumption 2 of the plan, D02 §3.3)
  # name in use                  0x181            0x181    captured, 37b index 16
  # hair / colour / face refused 0x183 (no text)  0x82     D02-B1
  # other persistence failure    0x183 / 0x184    0x82     D02-B1

  @key "20151116141627"

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
    client = connect(TestPorts.endpoint(:login))
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

  # the client after the character list (0x0C14) has been read
  defp world_login(name \\ "admin") do
    {key, _login} = select(name)
    client = TestPorts.endpoint(:wm) |> connect() |> send!(%UserLoginworldReq{user_name: name, validate: key})
    assert {:ok, <<0x14, 0x0C, _::binary>>, client} = TestClient.recv_raw(client)
    client
  end

  defp create(client, payload) do
    {:ok, client} = TestClient.send_raw(client, <<0x01, 0x14, payload::binary>>)
    assert {:ok, body, client} = TestClient.recv_raw(client)
    {body, client}
  end

  defp request(slot, name, class, opts \\ []) do
    gender = Keyword.get(opts, :gender, 0)
    {hair, color, face} = Keyword.get(opts, :look, {0, 0, 0})
    <<slot, String.pad_trailing(name, 20, <<0>>)::binary-20, gender::1, class::5, 1::2, hair, color, face>>
  end

  defp fail(code), do: <<0x04, 0x14, code::little-16>>

  defp capture(name, index) do
    transcript = "../replay/transcripts/#{name}.txt" |> Path.expand(__DIR__) |> Replay.Transcript.read!()
    Enum.find(transcript.packets, &(&1.index == index)).payload
  end

  test "the bytes of capture create-char", %{id: id} do
    use_test_clock(1_794_733_600_925_868)
    Factory.character(id, %{slot: 0, name: "Test1235"})

    {<<0x06, 0x14, 1, _::binary>> = body, _client} =
      world_login() |> create(capture("26_11_15_create-char", 23))

    <<0x06, 0x14, payload::binary>> = body
    expected = capture("26_11_15_create-char", 24)
    <<_::binary-1, chrregnum::binary-4, _::binary>> = payload
    # the seconds byte: 40 s, the two uninitialised bits (P02-B7) 0 instead of the captured 1
    seconds = 1 + 0x76
    <<head::binary-1, _::binary-4, mid::binary-size(^seconds - 5), _, tail::binary>> = expected
    assert payload == head <> chrregnum <> mid <> <<0x28>> <> tail
  end

  test "a created character equals the one of the later list (37 to 37b)" do
    use_test_clock(1_794_758_928_521_346)
    payload = Base.decode16!("0258333744656c0000000000000000000000000000d5040000", case: :mixed)
    {<<0x06, 0x14, 1, _::binary>>, client} = world_login() |> create(payload)

    {:ok, client} = TestClient.send_raw(client, <<0x1F, 0x0C>>)
    assert {:ok, <<0x14, 0x0C, _::little-16, 1, record::binary>>, _client} = TestClient.recv_raw(client)

    <<_::binary-size(3 + 2 * 130), expected::binary-130, _::binary>> =
      capture("26_11_16_37b_char-select-rename-refusals", 12)

    <<_::binary-4, _::binary-20, middle::binary-size(0x28 - 24), _::binary-4, tail::binary>> = expected
    <<chrregnum::binary-4, _::binary>> = record
    name = String.pad_trailing("X37Del", 20, <<0>>)
    assert record == chrregnum <> name <> middle <> <<0, 0, 0, 0>> <> tail
  end

  test "slot 6 and a slot in use answer 0x85, and the connection goes on", %{id: id} do
    Factory.character(id, %{slot: 2, name: "Taken"})
    {body, client} = world_login() |> create(request(6, "Fresh", 1))
    assert body == fail(0x85)
    {body, client} = create(client, request(2, "Fresh", 1))
    assert body == fail(0x85)
    # the slot wins over the name
    {body, client} = create(client, request(2, "Taken", 1))
    assert body == fail(0x85)
    {body, _client} = create(client, request(3, "Fresh", 1, look: {4, 0, 0}))
    assert <<0x06, 0x14, 1, _::binary>> = body
  end

  test "invalid names answer 0x82" do
    bad0 =
      GameData.BadNameFilter
      |> GameData.lookup(:type, 0)
      |> Enum.find(&(&1.bad_name != "" and byte_size(&1.bad_name) <= 20 and not String.contains?(&1.bad_name, " ")))

    names = ["X37 Sp", "", "xGmx", String.upcase(bad0.bad_name, :ascii)]

    Enum.reduce(names, world_login(), fn name, client ->
      {body, client} = create(client, request(0, name, 1))
      assert body == fail(0x82), "name #{inspect(name)}"
      client
    end)
  end

  test "class 26 needs a character of the level", %{id: id} do
    client = world_login()
    {body, client} = create(client, request(0, "Sentinel", 26))
    assert body == fail(0x83)

    Factory.character(id, %{slot: 1, level: 60})
    {<<0x06, 0x14, payload::binary>>, _client} = create(client, request(0, "Sentinel", 26))
    assert {:ok, %AvatarCreatesuccAck{avatars: [avatar]}} = AvatarCreatesuccAck.decode(payload)
    assert {avatar.level, avatar.loginmap, avatar.chrclass, avatar.race, avatar.tutorial_state} == {60, "Eld", 26, 2, 2}
    assert Enum.at(avatar.equip, 2) == 62_923
    assert avatar.equip |> List.delete_at(2) |> Enum.all?(&(&1 == 0xFFFF))
  end

  test "a class without defaults answers 0x83" do
    {body, _client} = world_login() |> create(request(0, "Nobody", 2))
    assert body == fail(0x83)
  end

  test "a name in use answers 0x181, with any letter case", %{id: id} do
    Factory.character(id, %{slot: 0, name: "Test1235"})
    client = world_login()
    {body, client} = create(client, capture("26_11_16_37b_char-select-rename-refusals", 15))
    assert body == <<0x04, 0x14, 0x81, 0x01>>
    {body, _client} = create(client, request(1, "TEST1235", 1))
    assert body == <<0x04, 0x14, 0x81, 0x01>>
  end

  test "a hair that is not free or does not exist answers 0x82" do
    client = world_login()
    {body, client} = create(client, request(0, "Hairy", 1, look: {5, 0, 0}))
    assert body == fail(0x82)
    {body, _client} = create(client, request(0, "Hairy", 1, look: {200, 0, 0}))
    assert body == fail(0x82)
  end

  test "a database failure answers 0x82" do
    client = world_login()
    Persistence.Repo.active().query!("ALTER TABLE characters RENAME TO characters_off")
    on_exit(fn -> Persistence.Repo.active().query!("ALTER TABLE characters_off RENAME TO characters") end)

    log =
      capture_log(fn ->
        {body, _client} = create(client, request(0, "Doomed", 1))
        assert body == fail(0x82)
      end)

    assert log =~ "the database failed in create_character"
  end

  test "a 20 byte name is created and listed" do
    name = "Twenty0Bytes0Name0XY"

    {<<0x06, 0x14, 1, _::binary-4, sent::binary-20, level, _::binary>>, client} =
      world_login() |> create(request(0, name, 1, gender: 1, look: {4, 0, 0}))

    assert {sent, level} == {name, 1}
    {:ok, client} = TestClient.send_packet(client, %UserAvatarListReq{})
    assert {:ok, %UserLoginworldAck{avatars: [%{name: ^name}]}, _client} = TestClient.recv(client)
  end
end
