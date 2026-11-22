defmodule MapEntryTest do
  # End-to-end over real sockets: the map-entry bursts of a fresh character, the login-time requests and the
  # dropping of known but unbuilt packets. Expected bytes are written out from docs/technical/flows/map-entry.md.
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

  setup do
    wait_until(fn -> match?({:ok, _}, WorldManager.World.zone_of(0, "RouN")) end)
    :ok = TestSessions.wait_none()
    Persistence.Repo.active().query!("DELETE FROM accounts")
    {:ok, id} = Persistence.create_account("admin", "pw")

    character =
      Factory.character(id, %{
        slot: 0,
        name: "Test1235",
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

    Factory.item(character.id, 10, 1250)
    %{cid: character.id}
  end

  # -- helpers (as in enter_world_test.exs)

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

  defp next!(client) do
    assert {:ok, body, client} = TestClient.recv_raw(client)
    {body, client}
  end

  defp recv!(client, body) do
    assert {:ok, ^body, client} = TestClient.recv_raw(client)
    client
  end

  # "Nothing": a heartbeat whose 0x0805 is the next packet.
  defp nothing!(client), do: client |> send!(<<0x04, 0x08>>) |> recv!(<<0x05, 0x08>>)

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

  defp world_login do
    {key, _login} = select("admin")
    client = TestPorts.endpoint(:wm) |> connect() |> send!(%UserLoginworldReq{user_name: "admin", validate: key})
    assert {:ok, %UserLoginworldAck{worldmanager: handle}, client} = TestClient.recv(client)
    {client, handle}
  end

  defp char_login(client, slot) do
    client = send!(client, <<0x01, 0x10, slot>>)
    assert {:ok, body, client} = TestClient.recv_raw(client)
    {body, client}
  end

  defp capture(opcode, dir) do
    transcript = "replay/transcripts/#{@idle}.txt" |> Path.expand(__DIR__) |> Replay.Transcript.read!()
    Enum.find(transcript.packets, &(&1.opcode == opcode and &1.dir == dir)).payload
  end

  # the captured 0x1801 (character "Test1235") with this handle
  defp map_login(handle) do
    <<_handle::16, rest::binary>> = capture(0x1801, :client)
    <<0x01, 0x18, handle::little-16, rest::binary>>
  end

  defp ack_1003, do: <<0x03, 0x10, "127.0.0.1", 0::56, TestPorts.app().zone::little-16>>

  # world login, 0x1001 and the Zone connection that has sent 0x1801
  defp entering do
    {wm, handle} = world_login()
    {body, wm} = char_login(wm, 0)
    assert body == ack_1003()
    zone = TestPorts.endpoint(:zone) |> connect() |> send!(map_login(handle))
    {wm, zone, handle}
  end

  # the first burst, read and checked; returns the handle of 0x1802
  defp first_burst(zone, cid) do
    expected_before = [
      <<0x38, 0x10, cid::little-32, "Test1235", 0::96, 0, 1, 0::64, 0::16, 0::16, 0::16, 0::16, 52::little-32,
        10::little-32, 0::32, 0::32, 0::64, "RouN", 0::64, 6477::little-32, 9844::little-32, 90, 0::48, 0, 0::32, 0::16,
        0, 0::32>>,
      # gender 0, class 1, race 1: 0b0_00001_01
      <<0x39, 0x10, 0x05, 1, 2, 3>>,
      <<0x3A, 0x10, cid::little-32, 1, 0>>,
      <<0x3B, 0x10, cid::little-32, 0::16, 12, 0, 0::16, 0::16>>,
      <<0xCE, 0x10, cid::little-32, 0::16>>,
      <<0xD7, 0x10, cid::little-32, 0::16>>,
      <<0x3D, 0x10, 0, 3, 0::16, cid::little-32, 0::16>>,
      <<0x3E, 0x10, 0::16>>,
      <<0x47, 0x10, 0, 9, 1>>,
      <<0x47, 0x10, 0, 8, 1>>,
      <<0x47, 0x10, 0, 12, 1>>,
      <<0x47, 0x10, 0, 15, 1>>,
      <<0x49, 0x10, 0, 0, 0::16, 0::16>>,
      <<0x4A, 0x10, 0::16>>,
      <<0x48, 0x10, 0xFF, 0xFF, 0xFF, 0xFF>>,
      <<0xDE, 0x10, 0::64, 1_000_000::little-64>>,
      <<0x1E, 0x44, 0::128>>
    ]

    zone =
      Enum.reduce(expected_before, zone, fn expected, zone ->
        {body, zone} = next!(zone)
        assert body == expected
        zone
      end)

    {body, zone} = next!(zone)
    assert <<0x02, 0x18, handle::little-16, _::binary>> = body
    assert handle in 8000..9499

    assert body ==
             <<0x02, 0x18, handle::little-16, 0::64, 0::64, 0::size(128 * 8), 52::little-32, 10::little-32, 0::32,
               0::32, 0::32, 0::32, 0::size(64 * 8), 6477::little-32, 9844::little-32>>

    {handle, zone}
  end

  defp refresh_flags,
    do:
      [0x10, 0x11, 0x24, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B] ++
        [0x00, 0x01, 0x02, 0x03, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D]

  defp second_burst(handle) do
    unequip = for slot <- 1..29, do: <<0x04, 0x1C, handle::little-16, slot>>

    params =
      for flag <- refresh_flags(), into: <<>> do
        value = %{0x10 => 52, 0x11 => 10}[flag] || 0
        <<flag, value::little-32>>
      end

    [
      <<0xE4, 0x10, 0::32, 0::16>>,
      <<0xE7, 0x10, 0::32, 0::16>>,
      <<0xEA, 0x10, 0::32, 0::16>>
    ] ++
      unequip ++
      [
        # item 1250 (class 5, weapon) in slot 10, upgrade 0, no licence mob
        <<0x05, 0x1C, handle::little-16, 1250::little-16, 0, 10, 0xFF, 0xFF, 0xFF>>,
        <<0x3A, 0x58, 2>>,
        :npcs,
        <<0x5B, 0x10, 0>>,
        <<0x3E, 0x20, 33::little-16, 127::little-16>>,
        <<0x10, 0x90, 5>>,
        <<0x2B, 0x18, 1>>,
        <<0x23, 0x11, 0, 0>> <> :binary.copy(<<0xFF>>, 48),
        <<0x2C, 0x48, 0::16>>,
        <<0xD4, 0x10, 0>>,
        <<0x27, 0x18, 0::32>>,
        <<0x35, 0x10, 26>> <> params,
        <<0x0E, 0x24, 52::little-32, 1::little-16>>,
        <<0x0F, 0x24, 10::little-32>>,
        <<0x5F, 0x24, 0::32>>
      ]
  end

  defp expect_all(client, expected) do
    Enum.reduce(expected, client, fn
      :npcs, client ->
        npc_lists!(client)

      e, client ->
        {body, client} = next!(client)
        assert body == e
        client
    end)
  end

  # The 29 standing NPCs of RouN, all shown (no distance limit), in two 0x1C09 of 28 and 1 in walk order from the
  # entrant at 6477, 9844.
  defp npc_lists!(client) do
    {:ok, map} = Zone.MapInstance.whereis(0, "RouN")
    npcs = :sys.get_state(map).npc_index
    order = npcs |> Enum.map(fn {h, n} -> {h, {n.x, n.y}} end) |> Zone.Grid.walk_order({6477, 9844}, 8000)
    assert length(order) == 29
    {first, client} = next!(client)
    {second, client} = next!(client)

    assert [first, second] ==
             for(
               chunk <- Enum.chunk_every(order, 28),
               do: Proto.encode(%Proto.Packets.BriefinfoMobCmd{mobs: for(h <- chunk, do: npcs[h].brief)})
             )

    client
  end

  # returns the WorldManager session handle
  defp in_world(cid) do
    {wm, zone, wm_handle} = entering()
    {handle, zone} = first_burst(zone, cid)
    zone = zone |> send!(<<0x03, 0x18>>) |> expect_all(second_burst(handle))
    {wm, zone, wm_handle}
  end

  defp wm_burst(wm) do
    wm =
      expect_all(wm, [
        <<0x97, 0x10, 0::32, 0>>,
        <<0x12, 0x10, 0::32>>,
        <<0x14, 0x94, 0::160, 0::32, 0, 0, 3, 0::16>>,
        <<0x26, 0x58, 0::16>>,
        <<0xD9, 0x10, 0>>
      ])

    {body, wm} = next!(wm)
    assert <<0x49, 0x08, tm::binary-36, _zone::signed-8>> = body
    assert_now(tm)
    recv!(wm, <<0x2A, 0x18, 0>>)
  end

  defp assert_now(
         <<sec::little-32, min::little-32, hour::little-32, mday::little-32, mon::little-32, year::little-32,
           _wday::little-32, _yday::little-32, 0::32>>
       ) do
    now = Clock.system_time(:second)
    {date, _time} = local = Clock.local_time(now)
    sent = {{year + 1900, mon + 1, mday}, {hour, min, sec}}
    assert elem(sent, 0) == date
    assert abs(seconds(sent) - seconds(local)) <= 2
  end

  defp seconds(datetime), do: :calendar.datetime_to_gregorian_seconds(datetime)

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not reached")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  # -- tests

  test "a fresh character: both Zone bursts and the WorldManager burst, byte for byte", %{cid: cid} do
    {wm, zone, _handle} = in_world(cid)
    wm |> wm_burst() |> nothing!()
    nothing!(zone)
  end

  test "the login-time requests of the WorldManager", %{cid: cid} do
    {wm, zone, _wm_handle} = entering()
    {_handle, _zone} = first_burst(zone, cid)

    wm =
      wm
      |> send!(<<0x04, 0x70>>)
      |> recv!(<<0x05, 0x70, 0, 0::size(24 * 8)>>)
      |> send!(<<0x0C, 0x70>>)
      |> recv!(<<0x0D, 0x70, 0, 0::size(392 * 8)>>)
      |> send!(<<0x06, 0x7C>>)
      |> recv!(<<0x07, 0x7C, 0xB1, 0x0D, 0::16>>)
      |> send!(<<0x1B, 0x58>>)

    {body, wm} = next!(wm)
    assert <<0x1C, 0x58, unix::little-signed-32, tm::binary-36>> = body
    assert abs(unix - Clock.system_time(:second)) <= 2
    assert_now(tm)
    # a second 0x581B gets nothing
    wm |> send!(<<0x1B, 0x58>>) |> nothing!()
  end

  test "the login-time requests of the Zone", %{cid: cid} do
    {_wm, zone, _handle} = in_world(cid)

    zone
    |> send!(<<0x2C, 0x30, 0::16>>)
    |> recv!(<<0x2D, 0x30, 0, 0>>)
    |> send!(<<0x20, 0x30, 0::16>>)
    |> recv!(<<0x21, 0x30, 0x41, 0x10, 3, 0::16>>)
    |> send!(<<0x0B, 0x20>>)
    |> nothing!()
  end

  test "known but unbuilt packets are dropped with one debug line, unknown ones close", %{cid: cid} do
    {wm, zone, _handle} = in_world(cid)
    wm = wm_burst(wm)
    stop = <<0x12, 0x20>> <> capture(0x2012, :client)

    log =
      TestLog.capture(fn ->
        Process.put(:zone, zone |> send!(stop) |> nothing!())
        wm |> send!(<<0x11, 0x70, 0::size(24 * 8)>>) |> nothing!()
      end)

    assert [_] = Regex.scan(~r/\[debug\] Zone: dropped a known but unbuilt packet 0x2012, peer 127\.0\.0\.1:/, log)
    assert [_] = Regex.scan(~r/dropped a known but unbuilt packet 0x2012/, log)

    assert [_] =
             Regex.scan(~r/\[debug\] WorldManager: dropped a known but unbuilt packet 0x7011, peer 127\.0\.0\.1:/, log)

    assert [_] = Regex.scan(~r/dropped a known but unbuilt packet 0x7011/, log)

    log =
      TestLog.capture(fn ->
        zone = send!(Process.get(:zone), <<0xFE, 0xFF>>)
        assert TestClient.recv_raw(zone) == {:error, :closed}
      end)

    assert log =~ "[info] Zone: connection closed: unknown opcode 0xFFFE, peer 127.0.0.1:"
  end

  test "an entry failure after the ticket answers 0x1804 {0x142, 0xFF} and closes with a warning" do
    {wm, handle} = world_login()
    {body, _wm} = char_login(wm, 0)
    assert body == ack_1003()
    Persistence.Repo.active().query!("ALTER TABLE characters RENAME TO characters_off")
    on_exit(fn -> Persistence.Repo.active().query!("ALTER TABLE characters_off RENAME TO characters") end)

    log =
      TestLog.capture(fn ->
        zone = TestPorts.endpoint(:zone) |> connect() |> send!(map_login(handle))
        zone = recv!(zone, <<0x04, 0x18, 0x42, 0x01, 0xFF>>)
        assert TestClient.recv_raw(zone) == {:error, :closed}
      end)

    assert [_] = Regex.scan(~r/\[warning\] Zone: connection closed: map entry failed: database failure, peer/, log)
    assert [_] = Regex.scan(~r/map entry failed/, log)
  end

  test "a closed Zone connection leaves the map; a new entry on the map succeeds", %{cid: cid} do
    {wm, zone, wm_handle} = in_world(cid)
    TestClient.close(zone)
    {:ok, map} = Zone.MapInstance.whereis(0, "RouN")
    wait_until(fn -> map_size(:sys.get_state(map).players) == 0 end)

    Process.put(:wm, wm)

    wait_until(fn ->
      {body, wm} = char_login(Process.get(:wm), 0)
      Process.put(:wm, wm)
      body == ack_1003()
    end)

    {_handle, _zone} =
      TestPorts.endpoint(:zone)
      |> connect()
      |> send!(map_login(wm_handle))
      |> first_burst(cid)

    assert map_size(:sys.get_state(map).players) == 1
  end
end
