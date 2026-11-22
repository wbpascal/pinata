defmodule WhisperTest do
  # End-to-end over real sockets: the whisper 0x200C. Expected bytes are written out from the transcripts of
  # scenario 14 (26_11_15_14_second-client-in-sight, lines 707 to 709) and scenario 45
  # (26_11_21_45_walk-sit-emote-stop-shout-whisper-cast-abort, lines 1005, 1006).
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Proto.Packets.UserClientVersionCheckReq
  alias Proto.Packets.UserLoginworldAck
  alias Proto.Packets.UserLoginworldReq
  alias Proto.Packets.UserUsLoginReq
  alias Proto.Packets.UserWorldselectAck
  alias Proto.Packets.UserWorldselectReq
  alias Proto.Packets.UserXtrapReq

  @key "20151116141627"
  @idle "26_11_15_idle_in_world"

  # scenario 14: X14B whispers "x14 whisper B" to Test1235
  @req14 <<0x0C, 0x20>> <>
           Base.decode16!("0054657374313233350000000000000000000000000d78313420776869737065722042", case: :lower)
  # the captured flag byte 0x54 is stale stack memory (P02-B29); the rebuild sends 0
  @cmd14 <<0x0D, 0x20>> <>
           Base.decode16!("005831344200000000000000000000000000000000000d78313420776869737065722042", case: :lower)
  @ack14 <<0x0F, 0x20>> <>
           Base.decode16!("0054657374313233350000000000000000000000000d78313420776869737065722042", case: :lower)
  # scenario 45: a whisper to an unknown name
  @req45 <<0x0C, 0x20>> <>
           Base.decode16!("005834354e6f626f647900000000000000000000000b7834352077686973706572", case: :lower)
  @fail45 <<0x0E, 0x20>> <> Base.decode16!("690f5834354e6f626f64790000000000000000000000", case: :lower)

  setup_all do
    peers = TestPeers.start()
    on_exit(fn -> TestPeers.stop(peers) end)
    %{peers: peers}
  end

  setup %{topology: topology, peers: peers} do
    t =
      case topology do
        :single ->
          %{
            login: TestPorts.endpoint(:login),
            wm: TestPorts.endpoint(:wm),
            zone: TestPorts.endpoint(:zone),
            call: fn _part, m, f, a -> apply(m, f, a) end
          }

        :peers ->
          %{
            login: {~c"127.0.0.1", peers.login_port},
            wm: {~c"127.0.0.1", peers.wm_port},
            zone: {~c"127.0.0.1", peers.zone_port},
            call: fn part, m, f, a -> :peer.call(peers[part], m, f, a) end
          }
      end

    wait_until(fn -> match?({:ok, _}, t.call.(:wm, WorldManager.World, :zone_of, [0, "RouN"])) end)
    Persistence.Repo.active().query!("DELETE FROM accounts")
    account("admin", "Test1235")
    account("second", "X14B")
    t
  end

  defp account(name, character) do
    {:ok, id} = Persistence.create_account(name, "pw")

    Factory.character(id, %{
      slot: 0,
      name: character,
      level: 1,
      race: 1,
      class: 1,
      gender: 0,
      hair: 1,
      hair_color: 2,
      face: 3,
      login_map: "RouN",
      login_x: 6477,
      login_y: 9844,
      hp: 52,
      sp: 10
    })
  end

  # -- helpers (as in map_entry_test.exs and enter_world_test.exs)

  defp connect({host, port}) do
    client = TestClient.connect(host, port)
    {:ok, <<0x07, 0x08, _::binary>>, client} = TestClient.recv_raw(client)
    client
  end

  defp send!(client, body) when is_binary(body) do
    {:ok, client} = TestClient.send_raw(client, body)
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

  # "Nothing": a heartbeat whose 0x0805 is the next packet.
  defp nothing!(client), do: client |> send!(<<0x04, 0x08>>) |> recv!(<<0x05, 0x08>>)

  defp select(t, name) do
    client = connect(t.login)
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

  # the session at character select
  defp world_login(t, account) do
    {key, _login} = select(t, account)
    client = t.wm |> connect() |> send!(%UserLoginworldReq{user_name: account, validate: key})
    assert {:ok, %UserLoginworldAck{worldmanager: handle}, client} = TestClient.recv(client)
    {client, handle}
  end

  defp char_login(client) do
    client = send!(client, <<0x01, 0x10, 0>>)
    assert {:ok, body, client} = TestClient.recv_raw(client)
    {body, client}
  end

  defp capture(opcode, dir) do
    transcript = "replay/transcripts/#{@idle}.txt" |> Path.expand(__DIR__) |> Replay.Transcript.read!()
    Enum.find(transcript.packets, &(&1.opcode == opcode and &1.dir == dir)).payload
  end

  # the captured 0x1801 with this handle and character name
  defp map_login(handle, name) do
    <<_handle::16, _name::binary-20, sums::binary>> = capture(0x1801, :client)
    <<0x01, 0x18, handle::little-16, Proto.Packet.pad(name, 20)::binary, sums::binary>>
  end

  defp until_heartbeat(zone) do
    case TestClient.recv_raw(zone) do
      {:ok, <<0x05, 0x08>>, zone} -> zone
      {:ok, <<0x04, 0x18, _::binary>> = body, _zone} -> flunk("map login refused: #{inspect(body)}")
      {:ok, _body, zone} -> until_heartbeat(zone)
    end
  end

  # world login, 0x1001 and a map login: the character is in the world
  defp in_world(t, account, character) do
    {wm, handle} = world_login(t, account)
    {body, wm} = char_login(wm)
    assert <<0x03, 0x10, _::binary>> = body
    zone = t.zone |> connect() |> send!(map_login(handle, character)) |> send!(<<0x04, 0x08>>) |> until_heartbeat()
    {wm, zone}
  end

  defp whisper(receiver, content, count \\ 0, links \\ <<>>),
    do:
      <<0x0C, 0x20, count, Proto.Packet.pad(receiver, 20)::binary, byte_size(content), content::binary, links::binary>>

  defp fail(code, receiver), do: <<0x0E, 0x20, code::little-16, Proto.Packet.pad(receiver, 20)::binary>>

  # the Zone connection closed and the map no longer holds the character (`others` = players still on the map)
  defp leave_map(zone, others \\ 0) do
    TestClient.close(zone)
    {:ok, map} = Zone.MapInstance.whereis(0, "RouN")
    wait_until(fn -> map_size(:sys.get_state(map).players) == others end)
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not reached")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  for topology <- [:single, :peers] do
    describe "#{topology}" do
      @describetag topology: topology

      test "a whisper between two clients is delivered", t do
        {receiver, _rz} = in_world(t, "admin", "Test1235")
        {sender, _sz} = in_world(t, "second", "X14B")
        sender |> send!(@req14) |> recv!(@ack14) |> nothing!()
        receiver |> recv!(@cmd14) |> nothing!()
      end
    end
  end

  describe "single node" do
    @describetag topology: :single

    test "another letter case is delivered; the echo has the stored spelling", t do
      {receiver, _rz} = in_world(t, "admin", "Test1235")
      {sender, _sz} = in_world(t, "second", "X14B")
      sender |> send!(whisper("TEST1235", "x14 whisper B")) |> recv!(@ack14) |> nothing!()
      receiver |> recv!(@cmd14) |> nothing!()
    end

    test "an unknown name answers 0x0F69", t do
      {receiver, _rz} = in_world(t, "admin", "Test1235")
      {sender, _sz} = in_world(t, "second", "X14B")
      sender |> send!(@req45) |> recv!(@fail45) |> nothing!()
      nothing!(receiver)
    end

    test "a text of 129 bytes answers 0x0F6B; 128 bytes are delivered", t do
      {receiver, _rz} = in_world(t, "admin", "Test1235")
      {sender, _sz} = in_world(t, "second", "X14B")

      sender =
        sender
        |> send!(whisper("Test1235", String.duplicate("a", 129)))
        |> recv!(<<0x0E, 0x20, 0x6B, 0x0F, "Test1235", 0::96>>)
        |> nothing!()

      receiver = nothing!(receiver)
      text = String.duplicate("a", 128)
      sender |> send!(whisper("Test1235", text)) |> recv!(<<0x0F, 0x20, 0, "Test1235", 0::96, 128, text::binary>>)
      recv!(receiver, <<0x0D, 0x20, 0, "X14B", 0::128, 0, 128, text::binary>>)
    end

    test "a receiver between maps gets the whisper", t do
      {receiver, rz} = in_world(t, "admin", "Test1235")
      leave_map(rz)
      {sender, _sz} = in_world(t, "second", "X14B")
      sender |> send!(@req14) |> recv!(@ack14) |> nothing!()
      receiver |> recv!(@cmd14) |> nothing!()
    end

    test "a receiver at character select is not found", t do
      {at_select, _handle} = world_login(t, "admin")
      {sender, _sz} = in_world(t, "second", "X14B")
      sender = sender |> send!(whisper("Test1235", "hi")) |> recv!(fail(0x0F69, "Test1235")) |> nothing!()
      nothing!(at_select)
      TestClient.close(at_select)

      {receiver, rz} = in_world(t, "admin", "Test1235")
      leave_map(rz, 1)
      Process.put(:wm, receiver)

      wait_until(fn ->
        {body, wm} = char_login(Process.get(:wm))
        Process.put(:wm, wm)
        match?(<<0x03, 0x10, _::binary>>, body)
      end)

      sender |> send!(whisper("Test1235", "hi")) |> recv!(fail(0x0F69, "Test1235")) |> nothing!()
      nothing!(Process.get(:wm))
    end

    test "a whisper to yourself answers 0x200D, then 0x200F", t do
      {wm, _zone} = in_world(t, "admin", "Test1235")

      wm
      |> send!(whisper("Test1235", "me"))
      |> recv!(<<0x0D, 0x20, 0, "Test1235", 0::96, 0, 2, "me">>)
      |> recv!(<<0x0F, 0x20, 0, "Test1235", 0::96, 2, "me">>)
      |> nothing!()
    end

    test "an empty whisper is echoed with count 0, also to an unknown name", t do
      {receiver, _rz} = in_world(t, "admin", "Test1235")
      {sender, _sz} = in_world(t, "second", "X14B")
      links = :binary.copy(<<0xAB>>, 0x67)

      sender
      |> send!(whisper("Test1235", "", 1, links))
      |> recv!(<<0x0F, 0x20, 0, "Test1235", 0::96, 0>>)
      |> send!(whisper("X45Nobody", ""))
      |> recv!(<<0x0F, 0x20, 0, "X45Nobody", 0::88, 0>>)
      |> nothing!()

      nothing!(receiver)
    end

    test "a sender at character select gets no answer", t do
      {receiver, _rz} = in_world(t, "admin", "Test1235")
      {sender, _handle} = world_login(t, "second")
      sender |> send!(@req14) |> nothing!()
      nothing!(receiver)
    end

    test "item links are relayed; a wrong size and 79 links are dropped", t do
      {receiver, _rz} = in_world(t, "admin", "Test1235")
      {sender, _sz} = in_world(t, "second", "X14B")
      links = :binary.copy(<<0xAB>>, 0x67)

      sender =
        sender
        |> send!(whisper("Test1235", "hi", 1, links))
        |> recv!(<<0x0F, 0x20, 1, "Test1235", 0::96, 2, "hi", links::binary>>)

      receiver = recv!(receiver, <<0x0D, 0x20, 1, "X14B", 0::128, 0, 2, "hi", links::binary>>)

      log =
        TestLog.capture(fn ->
          Process.put(:sender, sender |> send!(whisper("Test1235", "hi", 1, binary_part(links, 0, 0x66))) |> nothing!())
        end)

      assert [_] = Regex.scan(~r/\[debug\] WorldManager: dropped a packet of the wrong size/, log)

      log =
        TestLog.capture(fn ->
          Process.get(:sender)
          |> send!(whisper("Test1235", "h", 79, :binary.copy(<<0xAB>>, 79 * 0x67)))
          |> nothing!()
        end)

      assert [_] = Regex.scan(~r/\[info\] WorldManager: whisper dropped: 79 item links, peer /, log)
      nothing!(receiver)
    end
  end
end
