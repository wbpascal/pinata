defmodule WorldManager.CharacterRenameTest do
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

  defp capture(name, index) do
    transcript = "../replay/transcripts/#{name}.txt" |> Path.expand(__DIR__) |> Replay.Transcript.read!()
    Enum.find(transcript.packets, &(&1.index == index)).payload
  end

  @capture "26_11_16_37b_char-select-rename-refusals"

  defp rename(client, payload) do
    {:ok, client} = TestClient.send_raw(client, <<0x0F, 0x14, payload::binary>>)
    assert {:ok, body, client} = TestClient.recv_raw(client)
    {body, client}
  end

  defp request(slot, name), do: <<slot, String.pad_trailing(name, 20, <<0>>)::binary-20>>
  defp ack(slot, name, code), do: <<0x10, 0x14, request(slot, name)::binary, code::little-16>>

  defp three(id) do
    Factory.character(id, %{slot: 0, name: "Test1235"})
    Factory.character(id, %{slot: 1, name: "Test2"})
    Factory.character(id, %{slot: 2, name: "X37-Ren"})
  end

  defp names(client) do
    {:ok, client} = TestClient.send_packet(client, %UserAvatarListReq{unset: 0})
    assert {:ok, %UserLoginworldAck{avatars: avatars}, client} = TestClient.recv(client)
    {Enum.map(avatars, &{&1.slot, &1.name}), client}
  end

  test "the bytes of capture 37b: rename, then the list", %{id: id} do
    three(id)
    assert capture(@capture, 176) == request(2, "X37Ren")
    {body, client} = world_login() |> rename(capture(@capture, 176))
    assert body == <<0x10, 0x14>> <> capture(@capture, 177)
    assert {[{0, "Test1235"}, {1, "Test2"}, {2, "X37Ren"}], _} = names(client)
  end

  test "a taken name answers 0xD1 (37b index 27 and scenario 52 at 361.966 s are the same bytes; P02-B42 fixed)", %{
    id: id
  } do
    three(id)
    # the plan's "index 29" is the transcript line; the packet index is two lower
    assert capture(@capture, 27) == request(2, "Test1235")
    # the capture's index 28 says 0xD0: the original renamed anyway
    {body, client} = world_login() |> rename(capture(@capture, 27))
    assert body == ack(2, "Test1235", 0xD1)
    assert {[{0, "Test1235"}, {1, "Test2"}, {2, "X37-Ren"}], _} = names(client)
  end

  test "a taken name in another letter case answers 0xD1", %{id: id} do
    three(id)
    {body, client} = world_login() |> rename(request(2, "TEST1235"))
    assert body == ack(2, "TEST1235", 0xD1)
    {body, _client} = rename(client, request(2, "test1235"))
    assert body == ack(2, "test1235", 0xD1)
  end

  test "an invalid name answers 0xD1", %{id: id} do
    three(id)
    long = String.duplicate("a", 17)
    {body, client} = world_login() |> rename(request(2, long))
    assert body == ack(2, long, 0xD1)
    {body, client} = rename(client, request(2, "X37 Sp"))
    assert body == ack(2, "X37 Sp", 0xD1)
    {body, client} = rename(client, <<2, 0::160>>)
    assert body == ack(2, "", 0xD1)
    {body, _client} = rename(client, request(2, String.duplicate("b", 16)))
    assert body == ack(2, String.duplicate("b", 16), 0xD0)
  end

  test "an empty or out-of-range slot answers 0xD1", %{id: id} do
    three(id)

    Enum.reduce([3, 6, 255], world_login(), fn slot, client ->
      {body, client} = rename(client, request(slot, "Free1"))
      assert body == ack(slot, "Free1", 0xD1)
      client
    end)
  end

  test "the own name in another letter case is accepted, and the old name is free", %{id: id} do
    three(id)
    {body, client} = world_login() |> rename(request(0, "TEST1235"))
    assert body == ack(0, "TEST1235", 0xD0)
    {body, client} = rename(client, request(2, "Free1"))
    assert body == ack(2, "Free1", 0xD0)
    {body, _client} = rename(client, request(1, "X37-Ren"))
    assert body == ack(1, "X37-Ren", 0xD0)
  end

  test "a database failure answers 0xD1", %{id: id} do
    three(id)
    client = world_login()
    Persistence.Repo.active().query!("ALTER TABLE characters RENAME TO characters_off")
    on_exit(fn -> Persistence.Repo.active().query!("ALTER TABLE characters_off RENAME TO characters") end)

    log =
      capture_log(fn ->
        {body, _client} = rename(client, request(2, "Free1"))
        assert body == ack(2, "Free1", 0xD1)
      end)

    assert log =~ "the database failed in rename_character"
  end

  # the capture answered 0x20D1 with slot 7 (index 227) and 0x20C0 (index 231)
  test "0xB409 always answers 0x20C3 with the slot of the request (P02-B34 fixed)", %{id: id} do
    three(id)
    seven = request(7, "Other")

    {client, _} =
      Enum.reduce([capture(@capture, 226), capture(@capture, 230), seven], {world_login(), nil}, fn payload,
                                                                                                    {client, _} ->
        {:ok, client} = TestClient.send_raw(client, <<0x09, 0xB4, payload::binary>>)
        assert {:ok, body, client} = TestClient.recv_raw(client)
        assert body == <<0x0C, 0xB4, 0xC3, 0x20>> <> payload
        {client, nil}
      end)

    assert {[{0, "Test1235"}, {1, "Test2"}, {2, "X37-Ren"}], _} = names(client)
  end
end
