defmodule LeaveWorldTest do
  # End-to-end over real sockets: the leave path (docs/technical/flows/leave-world.md). Saving, auto-save, the second
  # login, crashes and stops of the map and the Zone part. Helpers copied from map_entry_test.exs.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Proto.Packets.CharClientBaseCmd
  alias Proto.Packets.UserClientVersionCheckReq
  alias Proto.Packets.UserLoginfailAck
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
    %{cid: character.id, uid: id}
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

  # a Login connection up to the login answer (the next packet, read with a long timeout: a take-over may wait)
  defp login(name) do
    client = connect(TestPorts.endpoint(:login))
    client = client |> send!(%UserClientVersionCheckReq{version_key: @key}) |> recv!(<<0x67, 0x0C, 1, 0>>)

    client
    |> send!(%UserUsLoginReq{user_name: name, password: "pw", spawnapps: <<0::160>>})
    |> send!(%UserXtrapReq{key_length: 0, key: ""})
    |> recv!(<<0x05, 0x0C, 1>>)
  end

  defp select(name) do
    assert {:ok, <<0x0A, 0x0C, _::binary>>, client} = TestClient.recv_raw(login(name))
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
    Enum.reduce(expected, client, fn e, client ->
      {body, client} = next!(client)
      assert body == e
      client
    end)
  end

  # returns the WorldManager session handle and the object handle
  defp in_world(cid) do
    {wm, zone, wm_handle} = entering()
    {handle, zone} = first_burst(zone, cid)
    zone = zone |> send!(<<0x03, 0x18>>) |> expect_all(second_burst(handle))
    {wm, zone, wm_handle, handle}
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

  defp row(cid), do: Persistence.Repo.active().get!(Persistence.Character, cid)

  defp move(handle, x, y, hp) do
    {:ok, map} = Zone.MapInstance.whereis(0, "RouN")

    :sys.replace_state(map, fn state ->
      update_in(state.players[handle], &%{&1 | x: x, y: y, character: %{&1.character | hp: hp}})
    end)
  end

  defp saved?(cid), do: row(cid).logout_at != nil

  # the next packet that is not a server heartbeat request 0x0804
  defp next_skip!(client) do
    case next!(client) do
      {<<0x04, 0x08>>, client} -> next_skip!(client)
      other -> other
    end
  end

  defp closed!(client), do: assert(TestClient.recv_raw(client, 3000) == {:error, :closed})

  defp put_env(key, value) do
    Application.put_env(:pinata, key, value)
    on_exit(fn -> Application.delete_env(:pinata, key) end)
  end

  # -- tests

  test "auto-save with a shortened interval: position and HP, no logout time", %{cid: cid} do
    put_env(:auto_save_ms, 50)
    {_wm, _zone, _wm_handle, handle} = in_world(cid)
    move(handle, 7000, 9001, 40)
    wait_until(fn -> row(cid).login_x == 7000 end)
    r = row(cid)
    assert {r.login_map, r.login_y, r.hp, r.sp, r.logout_at, r.play_minutes} == {"RouN", 9001, 40, 10, nil, 0}
  end

  test "a failing auto-save writes an error line and the player stays", %{cid: cid} do
    put_env(:auto_save_ms, 50)
    {wm, zone, _wm_handle, _handle} = in_world(cid)
    Persistence.Repo.active().query!("DELETE FROM characters WHERE id = #{cid}")

    log = TestLog.capture(fn -> Process.sleep(300) end)

    assert log =~ "[error] Zone: auto-save failed: character #{cid}, character not found, peer 127.0.0.1:"
    {:ok, map} = Zone.MapInstance.whereis(0, "RouN")
    assert map_size(:sys.get_state(map).players) == 1
    nothing!(zone)

    # the save at the leave fails too: keep its line out of the next test
    TestLog.capture(fn ->
      TestClient.close(wm)
      TestClient.close(zone)
      :ok = TestSessions.wait_none()
    end)
  end

  test "a second login finds the character saved when its login answer arrives", %{cid: cid} do
    {wm, zone, _wm_handle, handle} = in_world(cid)
    move(handle, 7001, 9002, 41)

    log =
      TestLog.capture(fn ->
        assert {:ok, <<0x0A, 0x0C, _::binary>>, _login} = TestClient.recv_raw(login("admin"), 6000)
      end)

    r = row(cid)
    assert {r.login_x, r.login_y, r.hp} == {7001, 9002, 41}
    assert %DateTime{} = r.logout_at
    assert log =~ "[info] Zone: connection closed: session replaced, peer"
    {:ok, map} = Zone.MapInstance.whereis(0, "RouN")
    assert :sys.get_state(map).players == %{}
    closed!(zone)
    assert {:ok, <<0x17, 0x0C, 0x83, 0x06>>, wm} = wm |> wm_burst() |> TestClient.recv_raw()
    closed!(wm)
  end

  test "a second login that waits longer than the replace timeout is refused with 0x45", %{uid: uid} do
    put_env(:replace_timeout_ms, 100)
    test = self()

    old =
      spawn(fn ->
        :ok = :pg.join(Cluster.Registry.scope(), {:session, uid}, self())
        send(test, :joined)
        receive do: (:stop -> :ok)
      end)

    on_exit(fn -> Process.exit(old, :kill) end)
    assert_receive :joined

    log =
      TestLog.capture(fn ->
        assert {:ok, %UserLoginfailAck{error: 0x45}, login} = TestClient.recv(login("admin"))
        closed!(login)
      end)

    assert [_] =
             Regex.scan(
               ~r/\[error\] Login: connection closed: login refused, account "admin", the old session did not end in time, peer/,
               log
             )
  end

  test "a killed map process closes the Zone connection without a save; the map comes back empty", %{cid: cid} do
    {_wm, zone, _wm_handle, handle} = in_world(cid)
    move(handle, 7002, 9003, 42)
    {:ok, map} = Zone.MapInstance.whereis(0, "RouN")

    log =
      TestLog.capture(fn ->
        Process.exit(map, :kill)
        closed!(zone)
      end)

    assert log =~ "[warning] Zone: connection closed: map instance lost, peer"
    wait_until(fn -> match?({:ok, pid} when pid != map, Zone.MapInstance.whereis(0, "RouN")) end)
    {:ok, new} = Zone.MapInstance.whereis(0, "RouN")
    assert :sys.get_state(new).players == %{}
    r = row(cid)
    assert {r.login_x, r.logout_at} == {6477, nil}
  end

  test "a map instance stopped in order saves its players and closes their connections", %{cid: cid} do
    {_wm, zone, _wm_handle, handle} = in_world(cid)
    move(handle, 7003, 9004, 43)
    {:ok, map} = Zone.MapInstance.whereis(0, "RouN")

    log =
      TestLog.capture(fn ->
        :ok = GenServer.stop(map, :shutdown)
        closed!(zone)
        wait_until(fn -> saved?(cid) end)
      end)

    assert log =~ "[info] Zone: connection closed: map instance stopped, peer"
    assert log =~ "[info] Zone: left the world: character #{cid}, map RouN, peer"
    r = row(cid)
    assert {r.login_x, r.login_y, r.hp} == {7003, 9004, 43}
  end

  test "a Zone part stopped in order saves its players", %{cid: cid} do
    {_wm, zone, _wm_handle, handle} = in_world(cid)
    move(handle, 7004, 9005, 44)

    on_exit(fn ->
      {:ok, _} = Supervisor.restart_child(Pinata.Supervisor, Zone.Supervisor)
      wait_until(fn -> match?({:ok, _}, WorldManager.World.zone_of(0, "RouN")) end, 250)
    end)

    log =
      TestLog.capture(fn ->
        :ok = Supervisor.terminate_child(Pinata.Supervisor, Zone.Supervisor)
        closed!(zone)
      end)

    assert log =~ "[info] Zone: connection closed: listener stopped, peer"
    assert log =~ "[info] Zone: left the world: character #{cid}, map RouN, peer"
    r = row(cid)
    assert {r.login_x, r.login_y, r.hp} == {7004, 9005, 44}
    assert %DateTime{} = r.logout_at
  end

  test "a failing save at a leave writes an error line, the player is removed, 0x0C1F still answers", %{cid: cid} do
    {wm, _zone, _wm_handle, _handle} = in_world(cid)
    wm = wm_burst(wm)
    Persistence.Repo.active().query!("DELETE FROM characters WHERE id = #{cid}")

    log =
      TestLog.capture(fn ->
        wm = send!(wm, <<0x18, 0x0C, 1>>) |> send!(<<0x1F, 0x0C, 0>>)
        assert {:ok, %UserLoginworldAck{avatars: []}, _wm} = TestClient.recv(wm)
      end)

    assert [_] = Regex.scan(~r/\[error\] Zone: save at leave failed: character #{cid}, character not found, peer/, log)
    {:ok, map} = Zone.MapInstance.whereis(0, "RouN")
    assert :sys.get_state(map).players == %{}
  end

  test "position, HP and play minutes after a second entry", %{cid: cid} do
    Application.put_env(:pinata, :clock_source, TestClock)

    on_exit(fn ->
      Application.delete_env(:pinata, :clock_source)
      TestClock.reset()
    end)

    TestClock.set(1_000_000_000)
    {wm, _zone, wm_handle, handle} = in_world(cid)
    wm = wm_burst(wm)
    move(handle, 7005, 9006, 45)
    TestClock.set(1_125_000_000)
    wm = send!(wm, <<0x18, 0x0C, 1>>)
    {body, wm} = wm |> send!(<<0x01, 0x10, 0>>) |> next_skip!()
    assert body == ack_1003()
    r = row(cid)
    assert {r.play_minutes, r.login_x} == {2, 7005}

    zone = TestPorts.endpoint(:zone) |> connect() |> send!(map_login(wm_handle))
    {body, _zone} = next!(zone)
    assert {:ok, %CharClientBaseCmd{x: 7005, y: 9006, hp: 45, map: "RouN"}} = Proto.decode(body)
    _ = wm
  end

  test "0x0C18 {1} then 0x1001 answers 0x1003", %{cid: cid} do
    {wm, _zone, _wm_handle, _handle} = in_world(cid)
    wm = wm |> wm_burst() |> send!(<<0x18, 0x0C, 1>>)
    {body, _wm} = char_login(wm, 0)
    assert body == ack_1003()
    assert saved?(cid)
  end

  test "0x0C18 {0} closes the Zone connection and saves", %{cid: cid} do
    {wm, zone, _wm_handle, _handle} = in_world(cid)
    wm = wm |> wm_burst() |> send!(<<0x18, 0x0C, 0>>)
    closed!(wm)
    closed!(zone)
    wait_until(fn -> saved?(cid) end)
  end

  test "a closed Zone socket saves and the session stays open", %{cid: cid} do
    {wm, zone, _wm_handle, _handle} = in_world(cid)
    wm = wm_burst(wm)
    TestClient.close(zone)
    wait_until(fn -> saved?(cid) end)
    nothing!(wm)
  end

  test "0x1071 and 0x1072 get no answer and the connection goes on", %{cid: cid} do
    {_wm, zone, _wm_handle, _handle} = in_world(cid)
    zone |> send!(<<0x71, 0x10>>) |> send!(<<0x72, 0x10>>) |> nothing!()
    {:ok, map} = Zone.MapInstance.whereis(0, "RouN")
    assert map_size(:sys.get_state(map).players) == 1
  end
end
