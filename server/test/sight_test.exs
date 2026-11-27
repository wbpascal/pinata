defmodule SightTest do
  # End-to-end over real sockets: the entry exchange, 0x1C01, 0x1805 and dimensions between two test clients on
  # RouN, and the batches and the crowd shrink with stub players entered straight into the map instance.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Proto.Packets.BriefinfoBriefinfodeleteCmd
  alias Proto.Packets.BriefinfoCharacterCmd
  alias Proto.Packets.BriefinfoInformCmd
  alias Proto.Packets.BriefinfoLogincharacterCmd
  alias Proto.Packets.BriefinfoMobCmd
  alias Proto.Packets.BriefinfoRegenmobCmd
  alias Proto.Packets.MapLoginReq
  alias Proto.Packets.MapLogoutCmd
  alias Proto.Packets.UserClientVersionCheckReq
  alias Proto.Packets.UserLoginworldAck
  alias Proto.Packets.UserLoginworldReq
  alias Proto.Packets.UserUsLoginReq
  alias Proto.Packets.UserWorldselectAck
  alias Proto.Packets.UserWorldselectReq
  alias Proto.Packets.UserXtrapReq

  @key "20151116141627"
  @a_pos {6477, 9844}
  @b_pos {6500, 9800}

  setup do
    wait_until(fn -> match?({:ok, _}, WorldManager.World.zone_of(0, "RouN")) end)
    {:ok, map} = Zone.MapInstance.whereis(0, "RouN")
    wait_until(fn -> :sys.get_state(map).players == %{} end)
    # a Zone connection of the previous test saves while it ends
    :ok = TestSessions.wait_none()
    Persistence.Repo.active().query!("DELETE FROM accounts")

    for {account, name, {x, y}} <- [{"alice", "Alice", @a_pos}, {"bobby", "Bobby", @b_pos}] do
      {:ok, id} = Persistence.create_account(account, "pw")
      Factory.character(id, %{slot: 0, name: name, login_map: "RouN", login_x: x, login_y: y, hp: 52, sp: 10})
    end

    # the stub players have no connection: they leave here
    on_exit(fn -> for handle <- Map.keys(:sys.get_state(map).players), do: Zone.MapInstance.leave(map, handle) end)

    %{map: map}
  end

  # -- helpers (as in map_entry_test.exs)

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

  defp packet!(client) do
    assert {:ok, packet, client} = TestClient.recv(client)
    {packet, client}
  end

  # "Nothing": a heartbeat whose 0x0805 is the next packet.
  defp nothing!(client), do: client |> send!(<<0x04, 0x08>>) |> recv!(<<0x05, 0x08>>)

  defp op(<<lo, hi, _::binary>>), do: hi * 256 + lo

  # the bodies up to and including the first one with the opcode
  defp until!(client, opcode, acc \\ []) do
    assert {:ok, body, client} = TestClient.recv_raw(client)
    if op(body) == opcode, do: {Enum.reverse([body | acc]), client}, else: until!(client, opcode, [body | acc])
  end

  defp checksums do
    transcript = "replay/transcripts/26_11_15_idle_in_world.txt" |> Path.expand(__DIR__) |> Replay.Transcript.read!()
    %{payload: payload} = Enum.find(transcript.packets, &(&1.opcode == 0x1801 and &1.dir == :client))
    binary_part(payload, 22, 1568)
  end

  # login, world login, 0x1001 and the map login of the account's character; the WorldManager client is kept in the
  # process dictionary (its end would end the session)
  defp enter(account, name) do
    login = connect(TestPorts.endpoint(:login))
    login = login |> send!(%UserClientVersionCheckReq{version_key: @key}) |> recv!(<<0x67, 0x0C, 1, 0>>)

    login =
      login
      |> send!(%UserUsLoginReq{user_name: account, password: "pw", spawnapps: <<0::160>>})
      |> send!(%UserXtrapReq{key_length: 0, key: ""})
      |> recv!(<<0x05, 0x0C, 1>>)

    assert {:ok, <<0x0A, 0x0C, _::binary>>, login} = TestClient.recv_raw(login)
    login = send!(login, %UserWorldselectReq{world_no: 0})
    assert {:ok, %UserWorldselectAck{world_status: 6, validate: key}, _login} = TestClient.recv(login)

    wm = TestPorts.endpoint(:wm) |> connect() |> send!(%UserLoginworldReq{user_name: account, validate: key})
    assert {:ok, %UserLoginworldAck{worldmanager: wm_handle}, wm} = TestClient.recv(wm)
    wm = send!(wm, <<0x01, 0x10, 0>>)
    assert {:ok, <<0x03, 0x10, _::binary>>, wm} = TestClient.recv_raw(wm)
    wm = TestClient.option_pushes!(wm)
    Process.put({:wm, account}, wm)

    zone =
      TestPorts.endpoint(:zone)
      |> connect()
      |> send!(%MapLoginReq{wm_handle: wm_handle, char_name: name, checksums: checksums()})

    {first, zone} = until!(zone, 0x1802)
    <<_op::16, handle::little-16, _::binary>> = List.last(first)
    {second, zone} = zone |> send!(<<0x03, 0x18>>) |> until!(0x245F)
    {%{zone: zone, handle: handle}, sight(second)}
  end

  # the packets between 0x583A and 0x105B of the second burst, decoded
  defp sight(bodies) do
    bodies
    |> Enum.drop_while(&(op(&1) != 0x583A))
    |> Enum.drop(1)
    |> Enum.take_while(&(op(&1) != 0x105B))
    |> Enum.map(fn body ->
      {:ok, packet} = Proto.decode(body)
      packet
    end)
  end

  defp chars(sight), do: for(%BriefinfoCharacterCmd{chars: c} <- sight, e <- c, do: e)
  defp npc_lists(sight), do: for(%BriefinfoMobCmd{mobs: m} <- sight, do: length(m))

  defp stub(name, {x, y}, conn) do
    character = %{
      id: 1,
      slot: 0,
      name: name,
      level: 1,
      exp: 0,
      login_map: "RouN",
      login_x: x,
      login_y: y,
      hp: 1,
      sp: 1,
      money: 0,
      hp_stones: 0,
      sp_stones: 0,
      race: 0,
      class: 1,
      gender: 0,
      hair: 0,
      hair_color: 0,
      face: 0,
      admin_level: 0,
      equipment: []
    }

    %Zone.Player{
      character: character,
      world_no: 0,
      map: "RouN",
      x: x,
      y: y,
      walk_speed: 33,
      run_speed: 127,
      map_type: 0,
      equipment: [],
      address: "127.0.0.1",
      last_good: {x, y},
      conn: conn
    }
  end

  # enters a stub player in mode 1
  defp stub!(map, name, pos, conn \\ :none) do
    {:ok, handle} = Zone.MapInstance.enter(map, stub(name, pos, conn))
    {:ok, _packets} = Zone.MapInstance.login_complete(map, handle)
    handle
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not reached")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  defp inform(b, handle),
    do: send!(b.zone, %BriefinfoInformCmd{my_handle: b.handle, receive_net_command: 0, handle: handle})

  # -- tests

  test "the entry exchange both ways and its order", %{map: map} do
    {a, sight} = enter("alice", "Alice")
    assert chars(sight) == []
    assert npc_lists(sight) == [28, 1]
    assert Enum.all?(sight, &match?(%BriefinfoMobCmd{}, &1))

    # the NPC batch full during the walk goes out first, then the rest of the players, then the rest of the NPCs
    # (bixall_Send @ FUN_0043fc80; captured in 26_11_21_45 and 26_11_21_52)
    {b, sight} = enter("bobby", "Bobby")
    assert [%BriefinfoMobCmd{mobs: m}, %BriefinfoCharacterCmd{chars: [char]}, %BriefinfoMobCmd{mobs: [_]}] = sight
    assert length(m) == 28
    assert %{handle: handle, name: "Alice", x: 6477, y: 9844, mode: 1, dir: 90} = char
    assert handle == a.handle
    assert char == Zone.Sight.brief(:sys.get_state(map).players[a.handle])

    {appear, zone} = packet!(a.zone)
    assert %BriefinfoLogincharacterCmd{name: "Bobby", x: 6500, y: 9800, mode: 1} = appear
    assert appear.handle == b.handle
    nothing!(zone)
  end

  test "0x1C01 in sight and out of sight, unknown handle, own handle", %{map: map} do
    {a, _} = enter("alice", "Alice")
    {b, _} = enter("bobby", "Bobby")
    {_appear, a_zone} = packet!(a.zone)

    {packet, zone} = b |> inform(a.handle) |> packet!()
    assert %BriefinfoLogincharacterCmd{name: "Alice"} = packet
    {packet, zone} = %{b | zone: zone} |> inform(17_084) |> packet!()
    assert %BriefinfoRegenmobCmd{handle: 17_084, mode: 2} = packet
    zone = %{b | zone: zone} |> inform(9000) |> nothing!()
    zone = %{b | zone: zone} |> inform(b.handle) |> nothing!()

    :ok = Zone.MapInstance.step(map, a.handle, {6477, 4000})
    {packet, zone} = packet!(zone)
    assert packet == %BriefinfoBriefinfodeleteCmd{handle: a.handle}
    # A gets the appears of the NPCs it comes to first, then the delete of B
    {bodies, _a_zone} = until!(a_zone, 0x1C0E)
    assert Enum.all?(Enum.drop(bodies, -1), &(op(&1) == 0x1C08))
    assert List.last(bodies) == <<0x0E, 0x1C, b.handle::little-16>>
    %{b | zone: zone} |> inform(a.handle) |> nothing!()
  end

  test "a player that leaves is announced with 0x1805" do
    {a, _} = enter("alice", "Alice")
    {b, _} = enter("bobby", "Bobby")
    TestClient.close(a.zone)
    {packet, zone} = packet!(b.zone)
    assert packet == %MapLogoutCmd{handle: a.handle}
    nothing!(zone)
  end

  test "players in different dimensions do not see each other", %{map: map} do
    {a, _} = enter("alice", "Alice")
    :ok = Zone.MapInstance.set_layer(map, a.handle, 1, 0)
    {b, sight} = enter("bobby", "Bobby")
    assert chars(sight) == []
    nothing!(a.zone)
    zone = b |> inform(a.handle) |> nothing!()
    TestClient.close(a.zone)
    wait_until(fn -> not Map.has_key?(:sys.get_state(map).players, a.handle) end)
    nothing!(zone)
  end

  test "dimension -1 sees and is seen", %{map: map} do
    {a, _} = enter("alice", "Alice")
    :ok = Zone.MapInstance.set_layer(map, a.handle, -1, 0)
    {b, sight} = enter("bobby", "Bobby")
    assert [%{name: "Alice"}] = chars(sight)
    {packet, _zone} = packet!(a.zone)
    assert %BriefinfoLogincharacterCmd{name: "Bobby"} = packet
    assert packet.handle == b.handle
  end

  test "players in sight go out in 0x1C07 batches of 28, in walk order", %{map: map} do
    {bx, by} = @b_pos
    stubs = for i <- 0..29, do: {stub!(map, "S#{i}", {bx + 100, by - 200 + i * 13}), {bx + 100, by - 200 + i * 13}}
    {b, sight} = enter("bobby", "Bobby")
    assert [28, 2] = for(%BriefinfoCharacterCmd{chars: c} <- sight, do: length(c))
    assert Enum.map(chars(sight), & &1.handle) == Zone.Grid.walk_order(stubs, @b_pos, b.handle)
  end

  test "a crowd shrinks the radius of the entry exchange", %{map: map} do
    {bx, by} = @b_pos
    for i <- 0..99, do: stub!(map, "C#{i}", {bx - 200 + rem(i, 10) * 40, by - 200 + div(i, 10) * 40})
    far = stub!(map, "Far", {bx + 1100, by}, self())
    flush()
    {b, sight} = enter("bobby", "Bobby")
    assert length(chars(sight)) == 100
    refute Enum.any?(chars(sight), &(&1.handle == far))
    refute_receive {:cluster, {:packets, _}}, 100
    _ = b
  end

  test "without a crowd the player at 1100 units is in the exchange", %{map: map} do
    {bx, by} = @b_pos
    far = stub!(map, "Far", {bx + 1100, by}, self())
    {b, sight} = enter("bobby", "Bobby")
    assert [%{handle: ^far}] = chars(sight)
    handle = b.handle
    assert_receive {:cluster, {:packets, [%BriefinfoLogincharacterCmd{handle: ^handle}]}}
  end

  defp flush do
    receive do
      {:cluster, _} -> flush()
    after
      0 -> :ok
    end
  end
end
