defmodule MovementTest do
  # End-to-end over real sockets: walk, run and stop between two test clients on RouN with the test clock, with the
  # bytes of scenario 45 (re-data/captures, transcript test/replay/transcripts/26_11_21_45_*.txt) and of
  # walk-run-portals.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Proto.Packets.BriefinfoLogincharacterCmd
  alias Proto.Packets.MapLoginReq
  alias Proto.Packets.UserClientVersionCheckReq
  alias Proto.Packets.UserLoginworldAck
  alias Proto.Packets.UserLoginworldReq
  alias Proto.Packets.UserUsLoginReq
  alias Proto.Packets.UserWorldselectAck
  alias Proto.Packets.UserWorldselectReq
  alias Proto.Packets.UserXtrapReq

  @key "20151116141627"

  setup do
    wait_until(fn -> match?({:ok, _}, WorldManager.World.zone_of(0, "RouN")) end)
    {:ok, map} = Zone.MapInstance.whereis(0, "RouN")
    wait_until(fn -> :sys.get_state(map).players == %{} end)
    # a Zone connection of the previous test saves while it ends
    :ok = TestSessions.wait_none()
    Persistence.Repo.active().query!("DELETE FROM accounts")
    Application.put_env(:pinata, :clock_source, TestClock)
    TestClock.set(1_000_000)

    on_exit(fn ->
      Application.delete_env(:pinata, :clock_source)
      TestClock.reset()
    end)

    %{map: map}
  end

  defp account!(account, name, {x, y}) do
    {:ok, id} = Persistence.create_account(account, "pw")
    Factory.character(id, %{slot: 0, name: name, login_map: "RouN", login_x: x, login_y: y, hp: 52, sp: 10})
  end

  # -- helpers (as in sight_test.exs)

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

  defp op(<<lo, hi, _::binary>>), do: hi * 256 + lo

  defp until!(client, opcode, acc \\ []) do
    assert {:ok, body, client} = TestClient.recv_raw(client)
    if op(body) == opcode, do: {Enum.reverse([body | acc]), client}, else: until!(client, opcode, [body | acc])
  end

  # the bodies the server sent before the answer of a heartbeat, NPC appears (0x1C08) left out: a step re-sends the
  # appear of an NPC that comes into sight
  defp bodies!(client) do
    client = send!(client, <<0x04, 0x08>>)
    {bodies, client} = until!(client, 0x0805)
    {bodies |> Enum.drop(-1) |> Enum.reject(&(op(&1) == 0x1C08)), client}
  end

  defp nothing!(client) do
    {bodies, client} = bodies!(client)
    assert bodies == []
    client
  end

  defp checksums do
    transcript = "replay/transcripts/26_11_15_idle_in_world.txt" |> Path.expand(__DIR__) |> Replay.Transcript.read!()
    %{payload: payload} = Enum.find(transcript.packets, &(&1.opcode == 0x1801 and &1.dir == :client))
    binary_part(payload, 22, 1568)
  end

  # login, world login, 0x1001 and the map login up to 0x1802 (step :loading)
  defp loading(account, name) do
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
    Process.put({:wm, account}, wm)

    zone =
      TestPorts.endpoint(:zone)
      |> connect()
      |> send!(%MapLoginReq{wm_handle: wm_handle, char_name: name, checksums: checksums()})

    {first, zone} = until!(zone, 0x1802)
    <<_op::16, handle::little-16, _::binary>> = List.last(first)
    %{zone: zone, handle: handle}
  end

  defp enter(account, name, pos) do
    account!(account, name, pos)
    p = loading(account, name)
    {_second, zone} = p.zone |> send!(<<0x03, 0x18>>) |> until!(0x245F)
    %{p | zone: zone}
  end

  # A and B; the appears of the entry exchange are read
  defp two(a_pos, b_pos) do
    a = enter("alice", "Alice", a_pos)
    b = enter("bobby", "Bobby", b_pos)
    {_, a_zone} = bodies!(a.zone)
    {_, b_zone} = bodies!(b.zone)
    TestClock.set(5_000_000)
    {%{a | zone: a_zone}, %{b | zone: b_zone}}
  end

  defp h(%{handle: handle}), do: <<handle::little-16>>
  defp hex(text), do: Base.decode16!(text, case: :lower)

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not reached")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  # -- tests

  test "a run is relayed from the server position; a stop in the middle of a slice" do
    {a, b} = two({6396, 9381}, {6428, 8900})
    # scenario 45, file lines 1760 and 1761
    b_zone = b.zone |> send!(<<0x19, 0x20>> <> hex("28190000c5220000c4180000c2220000")) |> nothing!()
    {[relay], a_zone} = bodies!(a.zone)
    assert relay == <<0x1A, 0x20>> <> h(b) <> hex("1c190000c4220000c4180000c22200007f000000")
    # file lines 1762 and 1766: 25 ms later, inside the first slice
    TestClock.set(5_025_000)
    b_zone |> send!(<<0x12, 0x20>> <> hex("24190000c5220000")) |> nothing!()
    {[stop], _} = bodies!(a_zone)
    assert stop == <<0x13, 0x20>> <> h(b) <> hex("19190000c4220000")
  end

  test "a walker leaves sight on the tick: 0x1C0E both ways" do
    {a, b} = two({6396, 9381}, {6437, 7862})
    # scenario 45 step 8, file lines 1910 and 1911
    b_zone = b.zone |> send!(<<0x17, 0x20>> <> hex("25190000b61e000027190000bc1d0000")) |> nothing!()
    {[relay], a_zone} = bodies!(a.zone)
    assert relay == <<0x18, 0x20>> <> h(b) <> hex("25190000b61e000027190000bc1d000021000000")
    TestClock.set(7_400_000)
    a_zone = nothing!(a_zone)
    b_zone = nothing!(b_zone)
    # file lines 1913 and 1914: the tick with 2455 ms or more applied
    TestClock.set(7_500_000)
    assert {[<<0x0E, 0x1C>> <> hb], _} = bodies!(a_zone)
    assert hb == h(b)
    assert {[<<0x0E, 0x1C>> <> ha], _} = bodies!(b_zone)
    assert ha == h(a)
  end

  test "a runner comes into sight on the tick: 0x1C06 at the position before the step, then the move" do
    # scenario 45, file lines 887 to 891: 1602 units apart, the entry exchange shows neither to the other
    {a, b} = two({6392, 9856}, {6422, 8254})
    b_zone = b.zone |> send!(<<0x19, 0x20>> <> hex("17190000232000001719000086200000")) |> nothing!()
    a_zone = nothing!(a.zone)
    TestClock.set(5_100_000)
    {[appear, relay], _} = bodies!(a_zone)
    assert {:ok, %BriefinfoLogincharacterCmd{x: 6422, y: 8254, dir: 0} = brief} = Proto.decode(appear)
    assert brief.handle == b.handle
    assert relay == <<0x1A, 0x20>> <> h(b) <> hex("161900003e2000001719000086200000") <> hex("7f000000")
    {[appear], _} = bodies!(b_zone)
    assert {:ok, %BriefinfoLogincharacterCmd{x: 6392, y: 9856}} = Proto.decode(appear)
  end

  test "refusals answer 0x201B with the server position" do
    # walk-run-portals, file lines 701 and 702: from == to
    p = enter("alice", "Alice", {5862, 6677})
    zone = p.zone |> send!(<<0x19, 0x20>> <> hex("e6160000151a0000e6160000151a0000"))
    {[refusal], zone} = bodies!(zone)
    assert refusal == <<0x1B, 0x20>> <> hex("e6160000151a0000")

    # from 300 units away
    zone = send!(zone, <<0x19, 0x20, 6162::little-32, 6677::little-32, 5900::little-32, 6677::little-32>>)
    assert {[<<0x1B, 0x20, 5862::little-32, 6677::little-32>>], zone} = bodies!(zone)

    # a target without a free cell (outside the map)
    zone = send!(zone, <<0x17, 0x20, 5862::little-32, 6677::little-32, 4_000_000_000::little-32, 0::little-32>>)
    assert {[<<0x1B, 0x20, 5862::little-32, 6677::little-32>>], zone} = bodies!(zone)

    # a stop 300 units away
    zone = send!(zone, <<0x12, 0x20, 6162::little-32, 6677::little-32>>)
    assert {[<<0x1B, 0x20, 5862::little-32, 6677::little-32>>], _zone} = bodies!(zone)
  end

  test "a move before 0x1803 gets no answer and the connection stays open", %{map: map} do
    account!("alice", "Alice", {5862, 6677})
    p = loading("alice", "Alice")
    zone = p.zone |> send!(<<0x19, 0x20>> <> hex("e6160000151a0000e6160000201a0000")) |> nothing!()
    zone |> send!(<<0x12, 0x20>> <> hex("e6160000151a0000")) |> nothing!()
    assert %{mover: :none, move: :none} = :sys.get_state(map).players[p.handle]
  end
end
