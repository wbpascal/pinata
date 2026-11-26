defmodule ChatTest do
  # End-to-end over real sockets: normal chat 0x2001, shout 0x201E, the spam filter and 0x082F. Expected bytes of the
  # shouts are written out from the transcripts of scenario 14 (26_11_15_14_second-client-in-sight) and scenario 45
  # (26_11_21_45_walk-sit-emote-stop-shout-whisper-cast-abort, line 844); no player 0x2002 was captured, its bytes
  # follow docs/pseudocode/zone/Z02-actions.md §3.1.
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

  # scenario 45: X45A shouts "x45 shout A"; the captured flag byte 0x64 is stale memory (P02-B29), the rebuild sends 0
  @shout45 <<0x1E, 0x20>> <> Base.decode16!("000b7834352073686f75742041", case: :lower)
  @someone45 <<0x1F, 0x20>> <>
               Base.decode16!("005834354100000000000000000000000000000000000b7834352073686f75742041", case: :lower)
  # scenario 14: X14B (level 1) shouts "test", Test1235 shouts "shout" and "x14 shout A"; captured flags 0x78, 0x74 -> 0
  @shout14b <<0x1E, 0x20>> <> Base.decode16!("000474657374", case: :lower)
  @shout14a <<0x1E, 0x20>> <> Base.decode16!("000573686f7574", case: :lower)
  @someone14a <<0x1F, 0x20>> <>
                Base.decode16!("005465737431323335000000000000000000000000000573686f7574", case: :lower)
  @shout14x <<0x1E, 0x20>> <> Base.decode16!("000b7831342073686f75742041", case: :lower)
  @someone14x <<0x1F, 0x20>> <>
                Base.decode16!("005465737431323335000000000000000000000000000b7831342073686f75742041", case: :lower)
  @hello <<0x01, 0x20, 0, 5, "hello">>

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
    # a Zone connection of the previous test (either topology) saves while it ends
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

  # -- helpers (as in whisper_test.exs)

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

  # the 0x1C06 a player in the world gets when another one enters in sight
  defp seen!(client) do
    assert {:ok, <<0x06, 0x1C, _::binary>>, client} = TestClient.recv_raw(client)
    client
  end

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

  defp char_login(client) do
    client = send!(client, <<0x01, 0x10, 0>>)
    assert {:ok, body, client} = TestClient.recv_raw(client)
    {body, client}
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

  defp until_heartbeat(zone) do
    case TestClient.recv_raw(zone) do
      {:ok, <<0x05, 0x08>>, zone} -> zone
      {:ok, _body, zone} -> until_heartbeat(zone)
    end
  end

  # world login, 0x1001, the map login and 0x1803: the character is in the world in mode 1
  defp in_world(t, account, character, attrs \\ %{}) do
    account(account, character, attrs)
    {wm, wm_handle} = world_login(t, account)
    {body, wm} = char_login(wm)
    assert <<0x03, 0x10, _::binary>> = body
    {handle, zone} = t.zone |> connect() |> send!(map_login(wm_handle, character)) |> until_handle()
    zone = zone |> send!(<<0x03, 0x18>>) |> send!(<<0x04, 0x08>>) |> until_heartbeat()
    %{wm: wm, zone: zone, handle: handle}
  end

  defp chat(content, count, links),
    do: <<0x01, 0x20, count, byte_size(content), content::binary, links::binary>>

  defp shout(content, count \\ 0, links \\ <<>>),
    do: <<0x1E, 0x20, count, byte_size(content), content::binary, links::binary>>

  defp someone(handle, content, count \\ 0, links \\ <<>>),
    do: <<0x02, 0x20, count, handle::little-16, byte_size(content), 0x02, 0, 0, content::binary, links::binary>>

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

      test "a shout reaches a player out of sight and the shouter (scenario 45)", t do
        a = in_world(t, "first", "X45A", %{level: 40})
        b = in_world(t, "second", "X45B", %{login_y: 4000})
        a.zone |> send!(@shout45) |> recv!(@someone45) |> nothing!()
        b.zone |> recv!(@someone45) |> nothing!()
      end

      test "normal chat reaches the speaker and the players in sight", t do
        a = in_world(t, "first", "X45A")
        b = in_world(t, "second", "X45B", %{login_x: 6500, login_y: 9800})
        a.zone |> seen!() |> send!(@hello) |> recv!(someone(a.handle, "hello")) |> nothing!()
        b.zone |> recv!(someone(a.handle, "hello")) |> nothing!()
      end
    end
  end

  describe "single node" do
    @describetag topology: :single

    test "normal chat does not reach a player out of sight", t do
      a = in_world(t, "first", "X45A")
      b = in_world(t, "second", "X45B", %{login_y: 4000})
      a.zone |> send!(@hello) |> recv!(someone(a.handle, "hello")) |> nothing!()
      nothing!(b.zone)
    end

    test "a shout below level 6 is dropped; a shout inside the delay is dropped (scenario 14)", t do
      Application.put_env(:pinata, :clock_source, TestClock)

      on_exit(fn ->
        Application.delete_env(:pinata, :clock_source)
        TestClock.reset()
      end)

      TestClock.set(1_000_000_000)
      a = in_world(t, "admin", "Test1235", %{level: 120})
      b = in_world(t, "second", "X14B", %{login_x: 6500, login_y: 9800})
      a = %{a | zone: seen!(a.zone)}

      b = %{b | zone: b.zone |> send!(@shout14b) |> nothing!()}
      a = %{a | zone: nothing!(a.zone)}

      a = %{a | zone: a.zone |> send!(@shout14a) |> recv!(@someone14a)}
      b = %{b | zone: recv!(b.zone, @someone14a)}

      a = %{a | zone: a.zone |> send!(@shout14x) |> nothing!()}
      b = %{b | zone: nothing!(b.zone)}

      TestClock.set(1_000_000_000 + 2_001_000)
      a.zone |> send!(@shout14x) |> recv!(@someone14x) |> nothing!()
      b.zone |> recv!(@someone14x) |> nothing!()
    end

    test "a shout on a map with the Shout flag off is dropped", t do
      wait_until(fn -> match?({:ok, _}, WorldManager.World.zone_of(0, "EldPri")) end)
      a = in_world(t, "first", "X45A", %{level: 40, login_map: "EldPri", login_x: 896, login_y: 1122})
      a.zone |> send!(shout("hi")) |> nothing!() |> send!(@hello) |> recv!(someone(a.handle, "hello")) |> nothing!()
    end

    test "three lines within 3 s block the player with 0x0848", t do
      a = in_world(t, "first", "X45A")
      b = in_world(t, "second", "X45B", %{login_x: 6500, login_y: 9800})
      line = someone(a.handle, "hello")

      zone =
        a.zone
        |> seen!()
        |> send!(@hello)
        |> recv!(line)
        |> send!(@hello)
        |> recv!(line)
        |> send!(@hello)
        |> recv!(<<0x48, 0x08, 10, 0, 0, 0>>)
        |> send!(@hello)

      assert {:ok, <<0x48, 0x08, s, 0, 0, 0>>, zone} = TestClient.recv_raw(zone)
      assert s in [9, 10]
      nothing!(zone)
      b.zone |> recv!(line) |> recv!(line) |> nothing!()
    end

    test "item links are relayed; a wrong size and 77 links are dropped", t do
      a = in_world(t, "first", "X45A", %{level: 40})
      b = in_world(t, "second", "X45B", %{login_x: 6500, login_y: 9800})
      links = :binary.copy(<<0xAB>>, 0x67)
      line = someone(a.handle, "hi", 1, links)
      shouted = <<0x1F, 0x20, 1, "X45A", 0::128, 0, 2, "hi", links::binary>>

      zone = a.zone |> seen!() |> send!(chat("hi", 1, links)) |> recv!(line)
      zone = zone |> send!(shout("hi", 1, links)) |> recv!(shouted)
      bz = b.zone |> recv!(line) |> recv!(shouted)

      log =
        TestLog.capture(fn ->
          Process.put(:zone, zone |> send!(chat("hi", 1, binary_part(links, 0, 0x66))) |> nothing!())
        end)

      assert [_] = Regex.scan(~r/\[debug\] Zone: dropped a packet of the wrong size/, log)

      many = :binary.copy(<<0xAB>>, 77 * 0x67)

      log =
        TestLog.capture(fn -> Process.put(:zone, Process.get(:zone) |> send!(chat("h", 77, many)) |> nothing!()) end)

      assert [_] = Regex.scan(~r/\[info\] Zone: chat dropped: 77 item links, peer /, log)

      log = TestLog.capture(fn -> Process.get(:zone) |> send!(shout("h", 77, many)) |> nothing!() end)
      assert [_] = Regex.scan(~r/\[info\] Zone: shout dropped: 77 item links, peer /, log)
      nothing!(bz)
    end

    test "0x082F answers 0x0830 with ShoutLevel and ShoutDelay", t do
      a = in_world(t, "first", "X45A")
      a.zone |> send!(<<0x2F, 0x08>>) |> recv!(<<0x30, 0x08, 5, 2, 0>>) |> nothing!()
    end

    test "chat before 0x1803 is ignored", t do
      account("first", "X45A", %{level: 40})
      {wm, wm_handle} = world_login(t, "first")
      {<<0x03, 0x10, _::binary>>, _wm} = char_login(wm)
      zone = t.zone |> connect() |> send!(map_login(wm_handle, "X45A")) |> send!(<<0x04, 0x08>>) |> until_heartbeat()
      zone |> send!(@hello) |> send!(shout("hi")) |> nothing!()
    end
  end
end
