defmodule MapChangeTest do
  # End-to-end over real sockets: the map change (docs/technical/flows/map-change.md). Gates with their menu, the town
  # portal, the reservation in the WorldManager session, the same-map link. Request bytes from the transcript
  # 26_11_15_walk-run-portals (0x181A at 228 and 343, 0x200A at 847, 0x3C02 at 856). Helpers copied from
  # leave_world_test.exs and movement_test.exs.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Proto.Packets.MapLinkotherCmd
  alias Proto.Packets.MenuServermenuReq
  alias Proto.Packets.ServerMenu
  alias Proto.Packets.UserClientVersionCheckReq
  alias Proto.Packets.UserLoginworldAck
  alias Proto.Packets.UserLoginworldReq
  alias Proto.Packets.UserUsLoginReq
  alias Proto.Packets.UserWorldselectAck
  alias Proto.Packets.UserWorldselectReq
  alias Proto.Packets.UserXtrapReq

  @key "20151116141627"
  @walk "26_11_15_walk-run-portals"
  # near the town portal NPC Gate_Town of RouN (5874, 6530), the gate GateRou6 to EventF (4801, 4643) and the gate
  # GateRou1 to RouCos02 (6477, 10579)
  @town {5874, 6600}
  @event_gate {4801, 4700}
  @cos_gate {6477, 10_500}

  setup do
    wait_until(fn -> match?({:ok, _}, WorldManager.World.zone_of(0, "RouN")) end)
    wait_until(fn -> match?({:ok, _}, WorldManager.World.zone_of(0, "RouVal01")) end)
    :ok = TestSessions.wait_none()
    Persistence.Repo.active().query!("DELETE FROM accounts")
    :ok
  end

  # -- helpers (as in leave_world_test.exs and movement_test.exs)

  defp character!(account, name, {x, y}, level \\ 1) do
    {:ok, id} = Persistence.create_account(account, "pw")

    Factory.character(id, %{slot: 0, name: name, level: level, login_map: "RouN", login_x: x, login_y: y})
    |> Map.fetch!(:id)
  end

  defp connect({host, port}) do
    client = TestClient.connect(host, port)
    {:ok, <<0x07, 0x08, _::binary>>, client} = TestClient.recv_raw(client)
    client
  end

  defp send!(client, body) do
    {:ok, client} = TestClient.send_raw(client, body)
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

  defp op(<<lo, hi, _::binary>>), do: hi * 256 + lo

  defp until!(client, opcode, acc \\ []) do
    {body, client} = next!(client)
    if op(body) == opcode, do: {Enum.reverse([body | acc]), client}, else: until!(client, opcode, [body | acc])
  end

  # the bodies the server sent before the answer of a heartbeat, NPC appears (0x1C08) and heartbeats left out
  defp bodies!(client) do
    client = send!(client, <<0x04, 0x08>>)
    {bodies, client} = until!(client, 0x0805)
    {bodies |> Enum.drop(-1) |> Enum.reject(&(op(&1) in [0x1C08, 0x0804])), client}
  end

  defp nothing!(client) do
    {bodies, client} = bodies!(client)
    assert bodies == []
    client
  end

  defp payload(index) do
    transcript = "replay/transcripts/#{@walk}.txt" |> Path.expand(__DIR__) |> Replay.Transcript.read!()
    Enum.find(transcript.packets, &(&1.index == index)).payload
  end

  # the captured 0x1801 with this session handle and character name
  defp map_login(handle, name) do
    <<_handle::16, _name::binary-20, rest::binary>> = payload(233)
    <<0x01, 0x18, handle::little-16, name::binary, 0::size((20 - byte_size(name)) * 8), rest::binary>>
  end

  # login, world login, 0x1001, the map login and 0x1803; the WorldManager burst is read up to 0x182A
  defp in_world(account, name) do
    login = connect(TestPorts.endpoint(:login))
    login = login |> send!(Proto.encode(%UserClientVersionCheckReq{version_key: @key})) |> recv!(<<0x67, 0x0C, 1, 0>>)

    login =
      login
      |> send!(Proto.encode(%UserUsLoginReq{user_name: account, password: "pw", spawnapps: <<0::160>>}))
      |> send!(Proto.encode(%UserXtrapReq{key_length: 0, key: ""}))
      |> recv!(<<0x05, 0x0C, 1>>)

    assert {:ok, <<0x0A, 0x0C, _::binary>>, login} = TestClient.recv_raw(login)
    login = send!(login, Proto.encode(%UserWorldselectReq{world_no: 0}))
    assert {:ok, %UserWorldselectAck{world_status: 6, validate: key}, _login} = TestClient.recv(login)

    wm =
      TestPorts.endpoint(:wm) |> connect() |> send!(Proto.encode(%UserLoginworldReq{user_name: account, validate: key}))

    assert {:ok, %UserLoginworldAck{worldmanager: wm_handle}, wm} = TestClient.recv(wm)
    wm = send!(wm, <<0x01, 0x10, 0>>)
    assert {:ok, <<0x03, 0x10, _::binary>>, wm} = TestClient.recv_raw(wm)
    {zone, handle} = TestPorts.endpoint(:zone) |> connect() |> enter_zone(wm_handle, name)
    {_burst, wm} = until!(wm, 0x182A)
    %{wm: wm, zone: zone, wm_handle: wm_handle, handle: handle}
  end

  # 0x1801 on a fresh Zone connection, the first burst up to 0x1802, 0x1803 and its burst up to 0x245F
  defp enter_zone(zone, wm_handle, name) do
    {first, zone} = zone |> send!(map_login(wm_handle, name)) |> until!(0x1802)
    <<_op::16, handle::little-16, _::binary>> = List.last(first)
    {_second, zone} = zone |> send!(<<0x03, 0x18>>) |> until!(0x245F)
    Process.put(:first_burst, first)
    {zone, handle}
  end

  defp map!(name) do
    {:ok, map} = Zone.MapInstance.whereis(0, name)
    map
  end

  defp npc_handle(map_name, fun) do
    map_name |> map!() |> :sys.get_state() |> Map.fetch!(:npcs) |> Enum.find(&fun.(&1.row)) |> Map.fetch!(:handle)
  end

  defp click(zone, npc), do: send!(zone, <<0x0A, 0x20, npc::little-16>>)

  defp town_portal(zone, index), do: send!(zone, <<0x1A, 0x18, index>>)

  defp row(cid), do: Persistence.Repo.active().get!(Persistence.Character, cid)

  defp on_map?(map_name, handle), do: Map.has_key?(:sys.get_state(map!(map_name)).players, handle)

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not reached")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  defp close_all(clients) do
    TestLog.capture(fn ->
      Enum.each(clients, &TestClient.close/1)
      :ok = TestSessions.wait_none()
    end)
  end

  # -- tests

  test "the captured 0x3C01 and 0x180A decode and encode to the same bytes" do
    for {index, module} <- [{850, MenuServermenuReq}, {231, MapLinkotherCmd}] do
      bytes = payload(index)
      assert {:ok, %^module{} = packet} = module.decode(bytes)
      assert Proto.encode(packet) == <<module.opcode()::little-16, bytes::binary>>
    end

    assert {:ok, %MenuServermenuReq{limit_range: 1000, menus: [%ServerMenu{reply: 0, string: "Yes"} | _]}} =
             MenuServermenuReq.decode(payload(850))
  end

  test "a gate to a map that is not running: the menu, \"Yes\", no packet, one info line, nothing saved" do
    cid = character!("admin", "Test1235", @event_gate)
    p = in_world("admin", "Test1235")
    gate = npc_handle("RouN", &(&1.role_arg == "GateRou6"))
    {[menu], zone} = p.zone |> click(gate) |> bodies!()

    assert {:ok, %MenuServermenuReq{} = m} = MenuServermenuReq.decode(binary_part(menu, 2, byte_size(menu) - 2))
    assert op(menu) == 0x3C01

    # the player's server position, the limit range 1000, "Yes" and "No"
    assert {m.npc_handle, m.x, m.y, m.limit_range, m.priority} == {gate, 4801, 4700, 1000, 0}
    assert m.title =~ ~r/^Do you want to move to .* field\?$/
    assert m.menus == [%ServerMenu{reply: 0, string: "Yes"}, %ServerMenu{reply: 1, string: "No"}]

    log = TestLog.capture(fn -> zone |> send!(<<0x02, 0x3C, 0>>) |> nothing!() end)

    assert log =~ "[info] Zone: gate MapLinkGate on map RouN: destination EventF is not running, peer"
    assert on_map?("RouN", p.handle)
    r = row(cid)
    assert {r.login_map, r.login_x, r.login_y, r.logout_at} == {"RouN", 4801, 4700, nil}
    close_all([p.wm, zone])
  end

  test "a town portal refused by WorldManager: 0x19C2, one info line, the player stays" do
    _cid = character!("admin", "Test1235", @town)
    wm_pid = GenServer.whereis(Cluster.Registry.world_manager(0))
    old = :sys.get_state(wm_pid).maps
    on_exit(fn -> :sys.replace_state(wm_pid, &%{&1 | maps: old}) end)
    p = in_world("admin", "Test1235")
    :sys.replace_state(wm_pid, &%{&1 | maps: Map.delete(&1.maps, "RouVal01")})

    log = TestLog.capture(fn -> p.zone |> town_portal(1) |> recv!(<<0x1B, 0x18, 0x19C2::little-16>>) end)

    assert [_] = Regex.scan(~r/\[info\] Zone: town portal refused: map RouVal01 is not running, peer/, log)
    assert on_map?("RouN", p.handle)
    close_all([p.wm, p.zone])
  end

  test "0x19C3 for an unknown index, 0x19C4 below the level of the row" do
    _cid = character!("admin", "Test1235", @town)
    p = in_world("admin", "Test1235")

    zone =
      p.zone
      |> town_portal(200)
      |> recv!(<<0x1B, 0x18, 0x19C3::little-16>>)
      |> town_portal(5)
      |> recv!(<<0x1B, 0x18, 0x19C4::little-16>>)
      |> nothing!()

    assert on_map?("RouN", p.handle)
    close_all([p.wm, zone])
  end

  test "a town portal away from a town portal NPC is refused with 0x19C2" do
    _cid = character!("admin", "Test1235", @cos_gate)
    p = in_world("admin", "Test1235")
    zone = p.zone |> town_portal(1) |> recv!(<<0x1B, 0x18, 0x19C2::little-16>>) |> nothing!()
    assert on_map?("RouN", p.handle)
    close_all([p.wm, zone])
  end

  test "a failing save refuses the town portal with 0x19C2 and an error line" do
    cid = character!("admin", "Test1235", @town)
    p = in_world("admin", "Test1235")
    Persistence.Repo.active().query!("DELETE FROM characters WHERE id = #{cid}")

    log = TestLog.capture(fn -> p.zone |> town_portal(1) |> recv!(<<0x1B, 0x18, 0x19C2::little-16>>) end)

    assert [_] =
             Regex.scan(
               ~r/\[error\] Zone: map change refused: save failed: character #{cid}, character not found, peer/,
               log
             )

    assert on_map?("RouN", p.handle)
    close_all([p.wm, p.zone])
  end

  test "a failing save refuses the gate without a packet and with an error line" do
    cid = character!("admin", "Test1235", @cos_gate)
    p = in_world("admin", "Test1235")
    gate = npc_handle("RouN", &(&1.role_arg == "GateRou1"))
    {[menu], zone} = p.zone |> click(gate) |> bodies!()
    assert op(menu) == 0x3C01
    Persistence.Repo.active().query!("DELETE FROM characters WHERE id = #{cid}")

    log = TestLog.capture(fn -> zone |> send!(<<0x02, 0x3C, 0>>) |> nothing!() end)

    assert log =~ "[error] Zone: map change refused: save failed: character #{cid}, character not found, peer"
    assert on_map?("RouN", p.handle)
    close_all([p.wm, zone])
  end

  test "a town portal to RouVal01: 0x19C1, 0x180A, the new connection enters the reserved map and position" do
    cid = character!("admin", "Test1235", @town)
    p = in_world("admin", "Test1235")

    log =
      TestLog.capture(fn ->
        zone = p.zone |> town_portal(1) |> recv!(<<0x1B, 0x18, 0x19C1::little-16>>)

        recv!(
          zone,
          <<0x0A, 0x18, 5::little-16, 13_658::little-32, 7812::little-32, "127.0.0.1", 0::56,
            TestPorts.app().zone::little-16, p.wm_handle::little-16>>
        )
      end)

    assert log =~ "[info] Zone: map change: character #{cid}, map RouN to RouVal01, peer"
    refute on_map?("RouN", p.handle)
    r = row(cid)
    assert {r.login_map, r.login_x, r.login_y} == {"RouN", 5874, 6600}

    {zone2, handle2} = TestPorts.endpoint(:zone) |> connect() |> enter_zone(p.wm_handle, "Test1235")
    [base | _] = Process.get(:first_burst)

    assert <<0x38, 0x10, ^cid::little-32, _::binary-62, "RouVal01", 0::32, 13_658::little-32, 7812::little-32,
             _::binary>> =
             base

    assert on_map?("RouVal01", handle2)
    # the short WorldManager burst after a map change
    assert {[<<0x26, 0x58, 0::16>>, <<0x2A, 0x18, 0>>], wm} = until!(p.wm, 0x182A)
    wm = nothing!(wm)
    close_all([wm, p.zone, zone2])
  end

  test "the client never arrives: the session ends, no player on any map, the old position stored" do
    cid = character!("admin", "Test1235", @town)
    p = in_world("admin", "Test1235")
    zone = p.zone |> town_portal(1) |> recv!(<<0x1B, 0x18, 0x19C1::little-16>>)
    {<<0x0A, 0x18, _::binary>>, zone} = next!(zone)
    TestClient.close(p.wm)
    :ok = TestSessions.wait_none()

    r = row(cid)
    assert {r.login_map, r.login_x, r.login_y} == {"RouN", 5874, 6600}
    assert %DateTime{} = r.logout_at
    assert :sys.get_state(map!("RouN")).players == %{}
    assert :sys.get_state(map!("RouVal01")).players == %{}
    TestClient.close(zone)
  end

  test "a link inside the map instance: 0x1809, 0x1805 to the others, the next 0x1803 runs the bursts" do
    _a = character!("admin", "Test1235", @town)
    _b = character!("bobby", "Bobby", {5900, 6650})
    a = in_world("admin", "Test1235")
    b = in_world("bobby", "Bobby")
    {_appears, a_zone} = bodies!(a.zone)

    a_zone =
      a_zone
      |> town_portal(0)
      |> recv!(<<0x1B, 0x18, 0x19C1::little-16>>)
      |> recv!(<<0x09, 0x18, 150::little-16, 5874::little-32, 6530::little-32>>)

    {bodies, b_zone} = bodies!(b.zone)
    assert <<0x05, 0x18, a.handle::little-16>> in bodies
    assert on_map?("RouN", a.handle)

    # a town portal before the 0x1803 of the link is refused
    a_zone = a_zone |> town_portal(0) |> recv!(<<0x1B, 0x18, 0x19C2::little-16>>)
    {_burst, a_zone} = a_zone |> send!(<<0x03, 0x18>>) |> until!(0x245F)
    assert {[<<0x26, 0x58, 0::16>>, <<0x2A, 0x18, 0>>], a_wm} = until!(a.wm, 0x182A)
    close_all([a_wm, a_zone, b.wm, b_zone])
  end

  test "a click on a non-Gate NPC or out of reach: nothing, the role line for the town portal NPC" do
    _cid = character!("admin", "Test1235", @town)
    p = in_world("admin", "Test1235")
    town = npc_handle("RouN", &(&1.mob_name == "Gate_Town"))
    gate = npc_handle("RouN", &(&1.role_arg == "GateRou1"))

    # the gate GateRou1 is out of reach from the town portal NPC
    log = TestLog.capture(fn -> p.zone |> click(town) |> nothing!() |> click(gate) |> nothing!() end)

    assert log =~ "[debug] Zone: NPC click dropped: role QuestNpc is not built"
    close_all([p.wm, p.zone])
  end

  test "\"No\" closes the gate menu: a later \"Yes\" does nothing, the player stays" do
    cid = character!("admin", "Test1235", @cos_gate)
    p = in_world("admin", "Test1235")
    gate = npc_handle("RouN", &(&1.role_arg == "GateRou1"))
    {[menu], zone} = p.zone |> click(gate) |> bodies!()
    assert op(menu) == 0x3C01

    zone = zone |> send!(<<0x02, 0x3C, 1>>) |> nothing!() |> send!(<<0x02, 0x3C, 0>>) |> nothing!()

    assert on_map?("RouN", p.handle)
    r = row(cid)
    assert {r.login_map, r.login_x, r.login_y, r.logout_at} == {"RouN", 6477, 10_500, nil}
    close_all([p.wm, zone])
  end

  test "\"Yes\" from too far from where the menu opened: nothing, one debug line, the player stays" do
    _cid = character!("admin", "Test1235", @cos_gate)
    p = in_world("admin", "Test1235")
    gate = npc_handle("RouN", &(&1.role_arg == "GateRou1"))
    {[menu], zone} = p.zone |> click(gate) |> bodies!()
    assert op(menu) == 0x3C01

    :sys.replace_state(map!("RouN"), fn s ->
      %{s | players: Map.update!(s.players, p.handle, &%{&1 | x: 6477 + 1500})}
    end)

    log = TestLog.capture(fn -> zone |> send!(<<0x02, 0x3C, 0>>) |> nothing!() end)

    assert log =~ "[debug] Zone: server menu answer dropped: too far from where the menu opened"
    assert on_map?("RouN", p.handle)
    close_all([p.wm, zone])
  end

  test "0x1001 between two maps voids the reservation: 0x1003, the new connection enters by first entry" do
    cid = character!("admin", "Test1235", @town)
    p = in_world("admin", "Test1235")
    zone = p.zone |> town_portal(1) |> recv!(<<0x1B, 0x18, 0x19C1::little-16>>)
    {<<0x0A, 0x18, _::binary>>, zone} = next!(zone)

    # the old Zone connection is still open
    wm = send!(p.wm, <<0x01, 0x10, 0>>)
    assert {:ok, <<0x03, 0x10, _::binary>>, wm} = TestClient.recv_raw(wm)

    {zone2, handle2} = TestPorts.endpoint(:zone) |> connect() |> enter_zone(p.wm_handle, "Test1235")
    [base | _] = Process.get(:first_burst)

    assert <<0x38, 0x10, ^cid::little-32, _::binary-62, "RouN", 0::64, 5874::little-32, 6600::little-32, _::binary>> =
             base

    assert on_map?("RouN", handle2)
    {_burst, wm} = until!(wm, 0x182A)
    close_all([wm, zone, zone2])
  end

  test "0x0C18 {1} between two maps drops the reservation: the new connection is refused" do
    _cid = character!("admin", "Test1235", @town)
    p = in_world("admin", "Test1235")
    zone = p.zone |> town_portal(1) |> recv!(<<0x1B, 0x18, 0x19C1::little-16>>)
    {<<0x0A, 0x18, _::binary>>, zone} = next!(zone)

    log =
      TestLog.capture(fn ->
        _wm = p.wm |> send!(<<0x18, 0x0C, 1>>) |> nothing!()

        TestPorts.endpoint(:zone)
        |> connect()
        |> send!(map_login(p.wm_handle, "Test1235"))
        |> recv!(<<0x04, 0x18, 0x41, 0x01, 0xFF>>)
        |> TestClient.close()

        # the line of the closed Zone connection
        Process.sleep(100)
      end)

    assert log =~ "[info] WorldManager: map-login ticket dropped: back to the character list, peer"
    assert log =~ "[info] Zone: connection closed: map login refused: no map-login ticket, peer"
    close_all([p.wm, zone])
  end

  # GateRou4 of RouN (7222, 4370) leads to RouCos03 (7514, 15412); both maps have machine number 0 in FieldList
  defp cos03_gate!(name) do
    wait_until(fn -> match?({:ok, _}, WorldManager.World.zone_of(0, "RouCos03")) end)
    {:ok, %{id: index}} = GameData.fetch(GameData.MapInfo, "RouCos03")
    {npc_handle(name, &(&1.role_arg == "GateRou4")), index}
  end

  test "a gate inside one machine number: 0x1809, 0x1805 to the others, the handle kept, the bursts" do
    cid = character!("admin", "Test1235", {7222, 4450})
    _b = character!("bobby", "Bobby", {7250, 4500})
    a = in_world("admin", "Test1235")
    b = in_world("bobby", "Bobby")
    {gate, index} = cos03_gate!("RouN")
    {_appears, a_zone} = bodies!(a.zone)
    {[menu], a_zone} = a_zone |> click(gate) |> bodies!()
    assert op(menu) == 0x3C01

    log =
      TestLog.capture(fn ->
        a_zone
        |> send!(<<0x02, 0x3C, 0>>)
        |> recv!(<<0x09, 0x18, index::little-16, 7514::little-32, 15_412::little-32>>)
        |> then(&Process.put(:a_zone, &1))
      end)

    a_zone = Process.get(:a_zone)

    assert log =~ "[info] Zone: map change: character #{cid}, map RouN to RouCos03, peer"
    {bodies, b_zone} = bodies!(b.zone)
    assert <<0x05, 0x18, a.handle::little-16>> in bodies
    refute on_map?("RouN", a.handle)

    assert %Zone.Player{map: "RouCos03", x: 7514, y: 15_412, mode: 0} =
             :sys.get_state(map!("RouCos03")).players[a.handle]

    {_burst, a_zone} = a_zone |> send!(<<0x03, 0x18>>) |> until!(0x245F)
    assert {[<<0x26, 0x58, 0::16>>, <<0x2A, 0x18, 0>>], a_wm} = until!(a.wm, 0x182A)
    close_all([a_wm, a_zone, b.wm, b_zone])
    # under PINATA_TEST_TOPOLOGY=multi close_all/1 waits for the peers' sessions, not for this node's
    wait_until(fn -> row(cid).login_map == "RouCos03" end)
    r = row(cid)
    assert {r.login_map, r.login_x, r.login_y} == {"RouCos03", 7514, 15_412}
  end

  test "a gate inside one machine number whose handle is in use on the target: 0x180A" do
    _cid = character!("admin", "Test1235", {7222, 4450})
    p = in_world("admin", "Test1235")
    {gate, index} = cos03_gate!("RouN")
    cos03 = map!("RouCos03")
    me = :sys.get_state(map!("RouN")).players[p.handle]
    :sys.replace_state(cos03, &%{&1 | players: Map.put(&1.players, p.handle, %{me | mode: 0, conn: :none})})
    on_exit(fn -> :sys.replace_state(cos03, &%{&1 | players: Map.delete(&1.players, p.handle)}) end)
    {[menu], zone} = p.zone |> click(gate) |> bodies!()
    assert op(menu) == 0x3C01

    zone = send!(zone, <<0x02, 0x3C, 0>>)
    assert {<<0x0A, 0x18, ^index::little-16, 7514::little-32, 15_412::little-32, _::binary>>, zone} = next!(zone)
    refute on_map?("RouN", p.handle)

    # the parked player arrives through a new connection, under another handle
    {zone2, handle2} = TestPorts.endpoint(:zone) |> connect() |> enter_zone(p.wm_handle, "Test1235")
    assert handle2 != p.handle and on_map?("RouCos03", handle2)
    {_burst, wm} = until!(p.wm, 0x182A)
    close_all([wm, zone, zone2])
  end
end
