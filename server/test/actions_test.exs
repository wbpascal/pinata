defmodule ActionsTest do
  # End-to-end over real sockets: emotes, the sit, the emote stop, the jump and the stance between test clients on
  # RouN. Bytes of scenario 45 (transcript test/replay/transcripts/26_11_21_45_*.txt, file line = index + 2) and of
  # scenario 14 where captured; 0x2022 / 0x2023 were never captured, their layouts are those of Z02 §4.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Proto.Packets.BriefinfoCharacterCmd
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
    {p, _burst} = enter_burst(account, name, pos)
    p
  end

  # enter/3 that also returns the bodies up to 0x245F
  defp enter_burst(account, name, pos) do
    account!(account, name, pos)
    p = loading(account, name)
    {burst, zone} = p.zone |> send!(<<0x03, 0x18>>) |> until!(0x245F)
    {%{p | zone: zone}, burst}
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

  # C comes into sight of A and B; returns the 0x1C07 elements C got, by handle, and checks that A and B each got C's
  # own 0x1C06 of the entry exchange with the emote state of a new player
  defp newcomer(a, b) do
    {c, burst} = enter_burst("carol", "Carol", {6400, 9000})

    chars =
      for body <- burst,
          op(body) == 0x1C07,
          {:ok, %BriefinfoCharacterCmd{chars: cs}} = Proto.decode(body),
          x <- cs,
          do: x

    for p <- [a, b] do
      {bodies, _} = bodies!(p.zone)

      assert [%BriefinfoLogincharacterCmd{emoticon_id: 0xFF, emoticon_frame: 0} = brief] =
               for(body <- bodies, op(body) == 0x1C06, do: elem(Proto.decode(body), 1))

      assert brief.handle == c.handle
    end

    Map.new(chars, &{&1.handle, &1})
  end

  # -- tests

  test "the sit 0x2020 {7} goes to the sitter and the player in sight; a newcomer sees it sit" do
    {a, b} = two({6396, 9381}, {6428, 8900})
    # scenario 45 indices 518 to 520
    {[own], b_zone} = b.zone |> send!(hex("202007")) |> bodies!()
    assert own == <<0x21, 0x20>> <> h(b) <> <<7>>
    {[seen], a_zone} = bodies!(a.zone)
    assert seen == own
    elements = newcomer(%{a | zone: a_zone}, %{b | zone: b_zone})
    assert %{emoticon_id: 7, emoticon_frame: 0, mode: 1} = elements[b.handle]
    assert %{emoticon_id: 0xFF, emoticon_frame: 0xFFFF} = elements[a.handle]
  end

  test "a free emote row 0x2020 {6} goes to both" do
    {a, b} = two({6396, 9381}, {6428, 8900})
    {[own], _} = b.zone |> send!(<<0x20, 0x20, 6>>) |> bodies!()
    assert own == <<0x21, 0x20>> <> h(b) <> <<6>>
    assert {[^own], _} = bodies!(a.zone)
  end

  test "an emote stop 0x2022 goes to both; a newcomer sees the frozen frame" do
    {a, b} = two({6396, 9381}, {6428, 8900})
    {[own], b_zone} = b.zone |> send!(<<0x22, 0x20, 23, 300::little-16>>) |> bodies!()
    assert own == <<0x23, 0x20>> <> h(b) <> <<23, 300::little-16>>
    assert {[^own], a_zone} = bodies!(a.zone)
    elements = newcomer(%{a | zone: a_zone}, %{b | zone: b_zone})
    assert %{emoticon_id: 23, emoticon_frame: 300} = elements[b.handle]
  end

  test "an accepted run clears the emote state, a stop does not" do
    {a, b} = two({6396, 9381}, {6428, 8900})
    {_, b_zone} = b.zone |> send!(<<0x20, 0x20, 7>>) |> bodies!()
    {_, a_zone} = bodies!(a.zone)
    b_zone = b_zone |> send!(<<0x12, 0x20, 6428::little-32, 8900::little-32>>) |> nothing!()
    assert {[<<0x13, 0x20, _::binary>>], a_zone} = bodies!(a_zone)
    {:ok, map} = Zone.MapInstance.whereis(0, "RouN")
    assert %{emoticon: {7, 0}} = :sys.get_state(map).players[b.handle]
    # scenario 45, file line 1760
    b_zone = b_zone |> send!(<<0x19, 0x20>> <> hex("28190000c5220000c4180000c2220000")) |> nothing!()
    assert {[<<0x1A, 0x20, _::binary>>], a_zone} = bodies!(a_zone)
    elements = newcomer(%{a | zone: a_zone}, %{b | zone: b_zone})
    assert %{emoticon_id: 0xFF, emoticon_frame: 0xFFFF} = elements[b.handle]
  end

  test "a sitter that stops still sits for a newcomer" do
    {a, b} = two({6396, 9381}, {6428, 8900})
    {_, b_zone} = b.zone |> send!(<<0x20, 0x20, 7>>) |> bodies!()
    {_, a_zone} = bodies!(a.zone)
    b_zone = b_zone |> send!(<<0x12, 0x20, 6428::little-32, 8900::little-32>>) |> nothing!()
    {_, a_zone} = bodies!(a_zone)
    elements = newcomer(%{a | zone: a_zone}, %{b | zone: b_zone})
    assert %{emoticon_id: 7, emoticon_frame: 0} = elements[b.handle]
  end

  test "a jump 0x2024 goes to the player in sight only" do
    {a, b} = two({6396, 9381}, {6428, 8900})
    # scenario 45 index 534
    b.zone |> send!(<<0x24, 0x20>>) |> nothing!()
    {[seen], _} = bodies!(a.zone)
    assert seen == <<0x25, 0x20>> <> h(b)
  end

  test "a stance 0x2008 {2} goes to the player in sight only and shows in later appears" do
    {a, b} = two({6396, 9381}, {6428, 8900})
    # scenario 14, file lines 875 and 876
    b_zone = b.zone |> send!(hex("082002")) |> nothing!()
    {[seen], a_zone} = bodies!(a.zone)
    assert seen == <<0x09, 0x20>> <> h(b) <> <<2>>
    elements = newcomer(%{a | zone: a_zone}, %{b | zone: b_zone})
    assert %{mode: 2} = elements[b.handle]
    assert %{mode: 1} = elements[a.handle]
  end

  test "ignored input: unknown and charged emote ids, an unknown emote stop, stance 3" do
    {a, b} = two({6396, 9381}, {6428, 8900})

    cases = [
      {<<0x20, 0x20, 200>>, ~r/\[info\] Zone: emote ignored: unknown id 200, peer /},
      {<<0x20, 0x20, 21>>, ~r/\[info\] Zone: emote ignored: unknown id 21, peer /},
      {<<0x20, 0x20, 31>>, ~r/\[info\] Zone: emote ignored: charged emote 31, peer /},
      {<<0x22, 0x20, 200, 0::little-16>>, ~r/\[info\] Zone: emote stop ignored: unknown id 200, peer /},
      {<<0x08, 0x20, 3>>, ~r/\[info\] Zone: stance ignored: mode 3, peer /}
    ]

    for {body, line} <- cases do
      log = TestLog.capture(fn -> Process.put(:b, (Process.get(:b) || b.zone) |> send!(body) |> nothing!()) end)
      assert [_] = Regex.scan(line, log)
    end

    nothing!(a.zone)
    {:ok, map} = Zone.MapInstance.whereis(0, "RouN")
    assert %{stance: 1, emoticon: {0xFF, 0xFFFF}} = :sys.get_state(map).players[b.handle]
  end

  test "the four packets before 0x1803 get no answer and change nothing", %{map: map} do
    account!("alice", "Alice", {5862, 6677})
    p = loading("alice", "Alice")

    p.zone
    |> send!(<<0x20, 0x20, 7>>)
    |> send!(<<0x22, 0x20, 7, 1::little-16>>)
    |> send!(<<0x24, 0x20>>)
    |> send!(<<0x08, 0x20, 2>>)
    |> nothing!()

    assert %{stance: 1, emoticon: {0xFF, 0}} = :sys.get_state(map).players[p.handle]
  end
end
