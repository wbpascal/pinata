defmodule WorldManager.CharacterDeleteTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  import ExUnit.CaptureLog

  alias Proto.Packets.UserAvatarListReq
  alias Proto.Packets.UserClientVersionCheckReq
  alias Proto.Packets.UserLoginworldAck
  alias Proto.Packets.UserLoginworldReq
  alias Proto.Packets.UserUsLoginReq
  alias Proto.Packets.UserWorldselectAck
  alias Proto.Packets.UserWorldselectReq
  alias Proto.Packets.UserXtrapReq

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

  defp capture(name, index) do
    transcript = "../replay/transcripts/#{name}.txt" |> Path.expand(__DIR__) |> Replay.Transcript.read!()
    Enum.find(transcript.packets, &(&1.index == index)).payload
  end

  defp erase(client, slot) do
    {:ok, client} = TestClient.send_raw(client, <<0x07, 0x14, slot>>)
    assert {:ok, body, client} = TestClient.recv_raw(client)
    {body, client}
  end

  @fail <<0x0A, 0x14, 0xC6, 0x00>>
  @capture "26_11_15_37_login-heartbeat-refusals-delete"

  test "the bytes of capture 37", %{id: id} do
    Factory.character(id, %{slot: 2, name: "X37Del"})
    assert capture(@capture, 37) == <<2>>
    {body, _client} = world_login() |> erase(2)
    assert body == <<0x0C, 0x14>> <> capture(@capture, 38)
  end

  test "an empty slot answers 0xC6, and the connection goes on" do
    {body, client} = world_login() |> erase(0)
    assert body == @fail
    {body, _client} = create(client, request(0, "Fresh", 1))
    assert <<0x06, 0x14, 1, _::binary>> = body
  end

  test "a slot out of range answers 0xC6", %{id: id} do
    Factory.character(id, %{slot: 0, name: "Stay"})
    {body, client} = world_login() |> erase(6)
    assert body == @fail
    {body, client} = erase(client, 255)
    assert body == @fail
    {:ok, client} = TestClient.send_packet(client, %UserAvatarListReq{})
    assert {:ok, %UserLoginworldAck{avatars: [%{name: "Stay"}]}, _} = TestClient.recv(client)
  end

  test "delete then list", %{id: id} do
    gone = Factory.character(id, %{slot: 0, name: "Gone"})
    Factory.character(id, %{slot: 1, name: "Stay"})
    Factory.item(gone.id, 3, 4)
    {body, client} = world_login() |> erase(0)
    assert body == <<0x0C, 0x14, 0>>
    {:ok, client} = TestClient.send_packet(client, %UserAvatarListReq{})
    assert {:ok, %UserLoginworldAck{avatars: [%{name: "Stay", slot: 1}]}, client} = TestClient.recv(client)
    {body, _client} = erase(client, 0)
    assert body == @fail
  end

  test "delete then create with the same name" do
    use_test_clock(1_794_758_928_521_346)
    first = Base.decode16!("0258333744656c000000000000000000000000000085040000", case: :mixed)
    second = Base.decode16!("0258333744656c0000000000000000000000000000d5040000", case: :mixed)
    {<<0x06, 0x14, 1, _::binary>>, client} = world_login() |> create(first)
    {body, client} = erase(client, 2)
    assert body == <<0x0C, 0x14, 2>>
    {body, _client} = create(client, second)
    assert <<0x06, 0x14, 1, _::binary>> = body
  end

  test "a database failure answers 0xC6" do
    client = world_login()
    Persistence.Repo.active().query!("ALTER TABLE characters RENAME TO characters_off")
    on_exit(fn -> Persistence.Repo.active().query!("ALTER TABLE characters_off RENAME TO characters") end)

    log =
      capture_log(fn ->
        {body, _client} = erase(client, 0)
        assert body == @fail
      end)

    assert log =~ "the database failed in delete_character"
  end

  test "a guild master answers 0xC7 (no caller yet)" do
    state = %WorldManager.Handler{worlds: [0]}

    assert {^state, [{:send, %Proto.Packets.AvatarErasefailAck{error: 0xC7}}]} =
             WorldManager.Handler.handle_info(state, {:character_deleted, 2, {:error, :guild_master}})
  end
end
