defmodule GmCommandTest do
  # End-to-end over real sockets: the GM command frame of 0x2001 lines starting with & (Zone.GmCommand). Bytes from
  # scenario 14 (26_11_15_14_second-client-in-sight: &hide at 392.45 s, &show at 405.08 s, &dimensio 1 at 428.57 s,
  # &linkto at 506.26 s) and scenario 52 (&kickout X52B, transcript index 519, 641.555 s, its 0x0C17 at index 522).
  #
  # The kick is asynchronous: the GM's notice and the 0x1805 of the kicked player can come in either order (the capture
  # has 0x1805 first), so the tests read both without their order.
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

  # captured lines
  @adminlevel <<0x01, 0x20>> <> Base.decode16!("000b2661646d696e6c6576656c", case: :lower)
  @kickout52 <<0x01, 0x20>> <> Base.decode16!("000d266b69636b6f75742058353242", case: :lower)
  # captured answers: 0x242A {288 STA_GMHIDEMODE, 4 200 000 000 ms}; 0x0C17 {0x068B}
  @hidden <<0x2A, 0x24>> <> Base.decode16!("2001000000ea56fa", case: :lower)
  @kicked <<0x17, 0x0C, 0x8B, 0x06>>

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
            call: fn _part, m, f, a -> apply(m, f, a) end
          }

        :peers ->
          %{
            login: {~c"127.0.0.1", peers.login_port},
            wm: {~c"127.0.0.1", peers.wm_port},
            call: fn part, m, f, a -> :peer.call(peers[part], m, f, a) end
          }
      end

    wait_until(fn -> match?({:ok, _}, t.call.(:wm, WorldManager.World, :zone_of, [0, "RouN"])) end)
    :ok = TestSessions.wait_none()
    :ok = TestSessions.wait_none(fn part, m, f, a -> :peer.call(peers[part], m, f, a) end)
    Persistence.Repo.active().query!("DELETE FROM accounts")
    t
  end

  defp account(name, character, attrs) do
    {:ok, id} = Persistence.create_account(name, "pw")

    Factory.character(
      id,
      Map.merge(
        %{
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
        },
        attrs
      )
    )
  end

  # -- helpers (as in chat_test.exs)

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

  defp seen!(client) do
    assert {:ok, <<0x06, 0x1C, _::binary>>, client} = TestClient.recv_raw(client)
    client
  end

  # the next packets, in any order
  defp recv_all!(client, bodies) do
    {got, client} =
      Enum.reduce(bodies, {[], client}, fn _, {acc, c} ->
        assert {:ok, body, c} = TestClient.recv_raw(c)
        {[body | acc], c}
      end)

    assert Enum.sort(got) == Enum.sort(bodies)
    client
  end

  # skips other packets up to the body
  defp until!(client, body) do
    case TestClient.recv_raw(client) do
      {:ok, ^body, client} -> client
      {:ok, _other, client} -> until!(client, body)
      {:error, reason} -> flunk("#{inspect(body)} not received: #{reason}")
    end
  end

  defp closed!(client) do
    case TestClient.recv_raw(client) do
      {:ok, _body, client} -> closed!(client)
      {:error, :closed} -> :ok
      {:error, :timeout} -> flunk("the connection was not closed")
    end
  end

  defp notice(text), do: <<0x11, 0x20, 0, byte_size(text), text::binary>>
  defp line(content), do: <<0x01, 0x20, 0, byte_size(content), content::binary>>
  defp gone(handle), do: <<0x05, 0x18, handle::little-16>>

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

  defp world_login(t, account) do
    {key, _login} = select(t, account)
    client = t.wm |> connect() |> send!(%UserLoginworldReq{user_name: account, validate: key})
    assert {:ok, %UserLoginworldAck{worldmanager: handle}, client} = TestClient.recv(client)
    {client, handle}
  end

  defp capture(opcode, dir) do
    transcript = "replay/transcripts/#{@idle}.txt" |> Path.expand(__DIR__) |> Replay.Transcript.read!()
    Enum.find(transcript.packets, &(&1.opcode == opcode and &1.dir == dir)).payload
  end

  defp map_login(handle, name) do
    <<_handle::16, _name::binary-20, sums::binary>> = capture(0x1801, :client)
    <<0x01, 0x18, handle::little-16, Proto.Packet.pad(name, 20)::binary, sums::binary>>
  end

  defp until_handle(zone) do
    case TestClient.recv_raw(zone) do
      {:ok, <<0x02, 0x18, handle::little-16, _::binary>>, zone} -> {handle, zone}
      {:ok, <<0x04, 0x18, _::binary>> = body, _zone} -> flunk("map login refused: #{inspect(body)}")
      {:ok, _body, zone} -> until_handle(zone)
    end
  end

  # the packets up to the answer of a heartbeat
  defp burst!(client), do: client |> send!(<<0x04, 0x08>>) |> burst!([])

  defp burst!(client, acc) do
    case TestClient.recv_raw(client) do
      {:ok, <<0x05, 0x08>>, client} -> {Enum.reverse(acc), client}
      {:ok, body, client} -> burst!(client, [body | acc])
    end
  end

  defp until_heartbeat(zone) do
    case TestClient.recv_raw(zone) do
      {:ok, <<0x05, 0x08>>, zone} -> zone
      {:ok, _body, zone} -> until_heartbeat(zone)
    end
  end

  # 0x1803 and its burst again after a 0x1809
  defp complete(zone), do: zone |> send!(<<0x03, 0x18>>) |> send!(<<0x04, 0x08>>) |> until_heartbeat()

  # world login, 0x1001, the map login on the Zone node 0x1003 names, and 0x1803: the character is in the world
  defp in_world(t, account, character, attrs \\ %{}) do
    c = account(account, character, attrs)
    {wm, wm_handle} = world_login(t, account)
    wm = send!(wm, <<0x01, 0x10, 0>>)
    assert {:ok, <<0x03, 0x10, _ip::binary-16, port::little-16>>, wm} = TestClient.recv_raw(wm)
    wm = TestClient.option_pushes!(wm)
    zone = connect({~c"127.0.0.1", port})
    {handle, zone} = zone |> send!(map_login(wm_handle, character)) |> until_handle()
    %{wm: wm, zone: complete(zone), handle: handle, id: c.id, port: port, wm_handle: wm_handle}
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not reached")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  defp saved?(id), do: Persistence.Repo.active().get!(Persistence.Character, id).logout_at != nil

  for topology <- [:single, :peers] do
    describe "#{topology}" do
      @describetag topology: topology

      test "&hide and &show (scenario 14) and the Korean alias of &hide", t do
        a = in_world(t, "admin", "Test1235", %{admin_level: 100})
        b = in_world(t, "second", "X14B", %{login_x: 6500, login_y: 9800})
        shown = <<0x28, 0x24, a.handle::little-16, 288::little-32>>

        az = a.zone |> seen!() |> send!(line("&hide")) |> recv!(@hidden)
        bz = recv!(b.zone, gone(a.handle))
        az = az |> send!(line("&show")) |> recv!(shown)
        bz = bz |> recv!(shown) |> nothing!()
        # not hidden: nothing; the alias &숨어 hides
        az = az |> send!(line("&show")) |> nothing!()
        az = az |> send!(line(<<"&", 0xBC, 0xFB, 0xBE, 0xEE>>)) |> recv!(@hidden) |> nothing!()
        nothing!(recv!(bz, gone(a.handle)))
        nothing!(az)
      end

      test "&linkto <map> <x> <y> on the own map: 0x1809", t do
        a = in_world(t, "admin", "Test1235", %{admin_level: 100})

        a.zone
        |> send!(line("&linkto RouN 7000 9000"))
        |> recv!(<<0x09, 0x18, 150::little-16, 7000::little-32, 9000::little-32>>)
        |> complete()
        |> nothing!()
      end
    end
  end

  describe "single node" do
    @describetag topology: :single

    test "&linkto <map> <x> <y> far outside the walkable area lands on the regen point and saves it", t do
      a = in_world(t, "admin", "Test1235", %{admin_level: 100})

      a.zone
      |> send!(line("&linkto RouN 100 200"))
      |> recv!(<<0x09, 0x18, 150::little-16, 6445::little-32, 8630::little-32>>)
      |> complete()
      |> TestClient.close()

      TestClient.close(a.wm)

      wait_until(fn ->
        r = Persistence.Repo.active().get!(Persistence.Character, a.id)
        {r.login_x, r.login_y} == {6445, 8630}
      end)
    end

    test "&linkto <map> <x> <y> on a blocked cell lands on a free cell next to it", t do
      a = in_world(t, "admin", "Test1235", %{admin_level: 100})
      zone = send!(a.zone, line("&linkto RouN 4801 4700"))
      assert {:ok, <<0x09, 0x18, 150::little-16, x::little-32, y::little-32>>, _zone} = TestClient.recv_raw(zone)
      assert {x, y} in [{4813, 4679}, {4789, 4679}]
    end

    test "admin level 0: no answer, not shown as chat, no log line", t do
      a = in_world(t, "first", "X45A")
      b = in_world(t, "second", "X45B", %{login_x: 6500, login_y: 9800})
      az = seen!(a.zone)
      log = TestLog.capture(fn -> az |> send!(@adminlevel) |> send!(line("&hide")) |> nothing!() end)
      refute log =~ "GM command"
      nothing!(b.zone)
    end

    test "an unknown word answers Invalid command and is logged", t do
      a = in_world(t, "admin", "Test1235", %{admin_level: 100})

      log =
        TestLog.capture(fn -> a.zone |> send!(line("&dimensio 1")) |> recv!(notice("Invalid command : &dimensio")) end)

      assert [_] = Regex.scan(~r/\[info\] Zone: GM command: character "Test1235": "&dimensio 1", peer /, log)
    end

    test "a known word with too low a level: no answer, the line is logged", t do
      a = in_world(t, "admin", "Test1235", %{admin_level: 10})
      log = TestLog.capture(fn -> a.zone |> send!(line("&dimension 1")) |> nothing!() end)
      assert log =~ ~s([info] Zone: GM command: character "Test1235": "&dimension 1")
    end

    test "&adminlevel answers the level", t do
      a = in_world(t, "admin", "Test1235", %{admin_level: 100})
      a.zone |> send!(@adminlevel) |> recv!(notice("Admin level is 100")) |> nothing!()
    end

    test "&dimension: 0x1805 under the old number, the GM's deletes; back: appears both ways", t do
      a = in_world(t, "admin", "Test1235", %{admin_level: 100})
      b = in_world(t, "second", "X14B", %{login_x: 6500, login_y: 9800})
      az = a.zone |> seen!() |> send!(line("&dimension 1")) |> recv!(<<0x0E, 0x1C, b.handle::little-16>>)
      {deletes, az} = burst!(az)
      assert Enum.all?(deletes, &match?(<<0x0E, 0x1C, _::16>>, &1))
      bz = b.zone |> recv!(gone(a.handle)) |> nothing!()

      {appears, az} = az |> send!(line("&dimension 0")) |> seen!() |> burst!()
      assert length(appears) == length(deletes)
      assert Enum.all?(appears, &match?(<<0x08, 0x1C, _::binary>>, &1))
      bz |> seen!() |> nothing!()
      nothing!(az)
    end

    test "&kickout on the same node (scenario 52)", t do
      a = in_world(t, "admin", "Test1235", %{admin_level: 100})
      x = in_world(t, "victim", "X52B", %{login_x: 6500, login_y: 9800})

      log =
        TestLog.capture(fn ->
          az = a.zone |> seen!() |> send!(@kickout52) |> recv_all!([gone(x.handle), notice("X52B is banned")])
          Process.put(:zone, nothing!(az))
          until!(x.wm, @kicked)
          closed!(x.zone)
          wait_until(fn -> saved?(x.id) end)
        end)

      assert log =~ ~s([info] WorldManager: kicked: character "X52B")
      assert log =~ "[info] Zone: connection closed: kicked, peer"
      # the session left the character group: a second kick finds nobody
      :zone |> Process.get() |> send!(@kickout52) |> recv!(notice("X52B is not in game"))
    end

    test "&kickout of an offline name: is not in game, nobody is disconnected", t do
      a = in_world(t, "admin", "Test1235", %{admin_level: 100})
      b = in_world(t, "second", "X14B", %{login_x: 6500, login_y: 9800})
      a.zone |> seen!() |> send!(line("&kickout Nobody")) |> recv!(notice("Nobody is not in game")) |> nothing!()
      nothing!(b.zone)
    end

    test "&kickout of a player between two maps: 0x0C17, its later 0x1801 is refused", t do
      a = in_world(t, "admin", "Test1235", %{admin_level: 100})
      x = in_world(t, "victim", "X52B", %{admin_level: 10, login_x: 6500, login_y: 9800})
      az = seen!(a.zone)

      # &linkto <map> of another machine number: the RegenX / RegenY point of MapInfo, 0x180A
      assert {:ok, <<0x0A, 0x18, 5::little-16, 12_879::little-32, 3852::little-32, _::binary>>, _zone} =
               x.zone |> send!(line("&linkto RouVal01")) |> TestClient.recv_raw()

      az = az |> recv!(gone(x.handle)) |> send!(@kickout52) |> recv!(notice("X52B is banned")) |> nothing!()
      until!(x.wm, @kicked)
      zone = connect({~c"127.0.0.1", x.port}) |> send!(map_login(x.wm_handle, "X52B"))
      assert {:ok, <<0x04, 0x18, 0x41, 0x01, _::binary>>, _zone} = TestClient.recv_raw(zone)
      nothing!(az)
    end

    test "&linkto forms", t do
      a = in_world(t, "admin", "Test1235", %{admin_level: 100})
      {:ok, map} = Zone.MapInstance.whereis(0, "RouN")
      b = :sys.get_state(map).block_data

      # no argument: a free cell of the own map
      assert {:ok, <<0x09, 0x18, 150::little-16, x::little-32, y::little-32>>, zone} =
               a.zone |> send!(line("&linkto")) |> TestClient.recv_raw()

      refute GameData.BlockData.blocked?(b, x, y)
      # <map>: the RegenX / RegenY point of MapInfo
      zone =
        zone
        |> complete()
        |> send!(line("&linkto RouN"))
        |> recv!(<<0x09, 0x18, 150::little-16, 6445::little-32, 8630::little-32>>)

      zone = complete(zone)

      zone =
        Enum.reduce(["&linkto Nowhere", "&linkto -", "&linkto - x"], zone, fn l, z ->
          z |> send!(line(l)) |> recv!(notice("Invalid map name"))
        end)

      log = TestLog.capture(fn -> Process.put(:zone, zone |> send!(line("&linkto RouN -5 10")) |> nothing!()) end)
      assert log =~ "[info] Zone: &linkto ignored: coordinates out of range"
      zone = Process.get(:zone)

      # a map that is not running
      {:ok, wm_pid} = Cluster.Registry.whereis_world_manager(0)
      old = :sys.get_state(wm_pid).maps
      :sys.replace_state(wm_pid, &%{&1 | maps: Map.delete(&1.maps, "RouVal01")})
      on_exit(fn -> :sys.replace_state(wm_pid, &%{&1 | maps: old}) end)
      zone = zone |> send!(line("&linkto RouVal01")) |> recv!(notice("Invalid map name")) |> nothing!()
      assert {:ok, %Zone.Player{map: "RouN", x: 6445, y: 8630}} = Zone.MapInstance.player(map, a.handle)
      nothing!(zone)
    end
  end

  describe "two Zone nodes" do
    @describetag topology: :peers

    test "&kickout of a player on a map of another Zone node", t do
      peers = t.peers
      zone2 = TestPeers.add_zone(peers)
      on_exit(fn -> TestPeers.stop_zone(peers, zone2) end)
      zone_maps = :peer.call(zone2.pid, Process, :whereis, [Zone.Maps])
      {:ok, old} = :peer.call(peers.wm, TestMapTable, :move, [0, "RouVal01", zone_maps])
      on_exit(fn -> {:ok, _} = :peer.call(peers.wm, TestMapTable, :move, [0, "RouVal01", old]) end)
      data_dir = System.fetch_env!("PINATA_TEST_DATA_DIR")

      {:ok, _} =
        :peer.call(zone2.pid, DynamicSupervisor, :start_child, [
          Zone.MapSupervisor,
          {Zone.MapInstance, {0, "RouVal01", data_dir}}
        ])

      a = in_world(t, "admin", "Test1235", %{admin_level: 100})
      x = in_world(t, "victim", "X52B", %{login_map: "RouVal01", login_x: 13_658, login_y: 7812})
      assert {a.port, x.port} == {peers.zone_port, zone2.port}

      a.zone |> send!(@kickout52) |> recv!(notice("X52B is banned")) |> nothing!()
      until!(x.wm, @kicked)
      closed!(x.zone)
      wait_until(fn -> saved?(x.id) end)
    end
  end
end
