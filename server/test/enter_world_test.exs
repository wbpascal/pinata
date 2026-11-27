defmodule EnterWorldTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Proto.Packets.CharLoginfailAck
  alias Proto.Packets.MapLoginfailAck
  alias Proto.Packets.UserAvatarListReq
  alias Proto.Packets.UserClientVersionCheckReq
  alias Proto.Packets.UserLoginworldAck
  alias Proto.Packets.UserLoginworldReq
  alias Proto.Packets.UserNormallogoutCmd
  alias Proto.Packets.UserUsLoginReq
  alias Proto.Packets.UserWorldselectAck
  alias Proto.Packets.UserWorldselectReq
  alias Proto.Packets.UserXtrapReq

  @key "20151116141627"
  @tutorial "26_11_21_52_stale-tutorial-rename-kickout-shn"
  @idle "26_11_15_idle_in_world"

  setup do
    # after a test that restarted the application the Zone part joins its world again a moment later
    wait_until(fn -> match?({:ok, _}, WorldManager.World.zone_of(0, "RouN")) end)
    :ok = TestSessions.wait_none()
    Persistence.Repo.active().query!("DELETE FROM accounts")
    {:ok, id} = Persistence.create_account("admin", "pw")
    %{id: id}
  end

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

  # the client after the character list (0x0C14) has been read, and the session handle
  defp world_login(name \\ "admin") do
    {key, _login} = select(name)
    client = TestPorts.endpoint(:wm) |> connect() |> send!(%UserLoginworldReq{user_name: name, validate: key})
    assert {:ok, %UserLoginworldAck{worldmanager: handle}, client} = TestClient.recv(client)
    {client, handle}
  end

  defp capture(name, opcode, dir) do
    transcript = "replay/transcripts/#{name}.txt" |> Path.expand(__DIR__) |> Replay.Transcript.read!()
    Enum.find(transcript.packets, &(&1.opcode == opcode and &1.dir == dir)).payload
  end

  defp ack_1003, do: <<0x03, 0x10, "127.0.0.1", 0::56, TestPorts.app().zone::little-16>>

  defp char_login(client, slot) do
    client = send!(client, <<0x01, 0x10, slot>>)
    assert {:ok, body, client} = TestClient.recv_raw(client)
    {body, client}
  end

  defp list(client) do
    client = send!(client, %UserAvatarListReq{unset: 0})
    assert {:ok, %UserLoginworldAck{avatars: avatars}, client} = TestClient.recv(client)
    {avatars, client}
  end

  # the captured 0x1801 of the idle capture (character "Test1235") with this handle
  defp map_login(handle) do
    <<_handle::16, rest::binary>> = capture(@idle, 0x1801, :client)
    <<0x01, 0x18, handle::little-16, rest::binary>>
  end

  defp zone_login(body) do
    zone = TestPorts.endpoint(:zone) |> connect() |> send!(body)
    {TestClient.recv_raw(zone), zone}
  end

  # sends 0x0804 and reads the map-entry burst up to the 0x0805: no 0x1804 came and the connection is open
  defp accepted(body) do
    zone = TestPorts.endpoint(:zone) |> connect() |> send!(body) |> send!(<<0x04, 0x08>>)
    until_heartbeat(zone)
  end

  defp until_heartbeat(zone) do
    case TestClient.recv_raw(zone) do
      {:ok, <<0x05, 0x08>>, zone} -> zone
      {:ok, <<0x04, 0x18, _::binary>> = body, _zone} -> flunk("map login refused: #{inspect(body)}")
      {:ok, _body, zone} -> until_heartbeat(zone)
    end
  end

  defp refused(body, code) do
    {result, _zone} = zone_login(body)
    assert {:ok, ^code, zone} = result
    assert TestClient.recv_raw(zone) == {:error, :closed}
  end

  defp entered(id) do
    Factory.character(id, %{slot: 0, name: "Test1235"})
    {client, handle} = world_login()
    {body, client} = char_login(client, 0)
    assert body == ack_1003()
    {TestClient.option_pushes!(client), handle}
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not reached")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end

  test "0x1001 for a character on a running map answers 0x1003 with the Zone node's address", %{id: id} do
    entered(id)
  end

  test "0x1001 is answered with 0x1003, then the empty option pushes 0x7032, 0x7033, 0x7034", %{id: id} do
    Factory.character(id, %{slot: 0, name: "Test1235"})
    {client, _handle} = world_login()
    {body, client} = char_login(client, 0)
    assert body == ack_1003()
    assert {:ok, <<0x32, 0x70, 0, 0>>, client} = TestClient.recv_raw(client)
    assert {:ok, <<0x33, 0x70, 0, 0>>, client} = TestClient.recv_raw(client)
    assert {:ok, <<0x34, 0x70, 0, 0>>, _client} = TestClient.recv_raw(client)
  end

  test "slot 6 and an empty slot", %{id: id} do
    Factory.character(id, %{slot: 0})
    {client, _handle} = world_login()
    {body, client} = char_login(client, 6)
    assert body == <<0x02, 0x10, 0x43, 0x01>>
    {body, _client} = char_login(client, 1)
    assert body == <<0x02, 0x10, 0xEB, 0x31>>
  end

  test "a map that does not run answers 0x145 with an info line", %{id: id} do
    Factory.character(id, %{slot: 0, login_map: "GuildT01"})
    {client, _handle} = world_login()

    log =
      TestLog.capture(fn ->
        {body, _client} = char_login(client, 0)
        assert body == <<0x02, 0x10>> <> capture(@tutorial, 0x1002, :server)
        assert body == <<0x02, 0x10, 0x45, 0x01>>
      end)

    assert log =~ "[info] WorldManager: character login refused: map GuildT01 is not running, peer 127.0.0.1:"
  end

  test "tutorial state 0: a skip saves state 2 and enters on the stored map", %{id: id} do
    Factory.character(id, %{slot: 3, name: "Tut", tutorial_state: 0})
    {client, _handle} = world_login()
    <<slot>> = capture(@tutorial, 0x1001, :client)
    assert slot == 3
    {body, client} = char_login(client, slot)
    assert body == <<0x10, 0x11, 0x00>>
    client = send!(client, <<0x11, 0x11>> <> capture(@tutorial, 0x1111, :client))
    client = client |> recv!(ack_1003()) |> TestClient.option_pushes!()
    assert {[avatar], _client} = list(client)
    assert {avatar.tutorial_state, avatar.loginmap} == {2, "RouN"}
  end

  test "tutorial state 0: \"yes\" answers 0x145, keeps the state and asks again", %{id: id} do
    Factory.character(id, %{slot: 3, name: "Tut", tutorial_state: 0})
    {client, _handle} = world_login()
    {<<0x10, 0x11, 0>>, client} = char_login(client, 3)
    client = client |> send!(<<0x11, 0x11, 0>>) |> recv!(<<0x02, 0x10, 0x45, 0x01>>)
    assert {[avatar], client} = list(client)
    assert {avatar.tutorial_state, avatar.loginmap} == {0, "RouT"}
    {body, client} = char_login(client, 3)
    assert body == <<0x10, 0x11, 0x00>>
    client |> send!(<<0x11, 0x11, 1>>) |> recv!(ack_1003())
  end

  test "0x1111 without a question gets no answer", %{id: id} do
    Factory.character(id, %{slot: 0})
    {client, _handle} = world_login()
    client = client |> send!(<<0x11, 0x11, 1>>) |> send!(<<0x0D, 0x08>>)
    assert {:ok, <<0x0E, 0x08, _::binary>>, _client} = TestClient.recv_raw(client)
  end

  test "a skip whose character changed in the meantime answers 0x145", %{id: id} do
    Factory.character(id, %{slot: 3, name: "Tut", tutorial_state: 0})
    {client, _handle} = world_login()
    {<<0x10, 0x11, 0>>, client} = char_login(client, 3)
    Persistence.Repo.active().query!("UPDATE characters SET tutorial_state = 1")
    client |> send!(<<0x11, 0x11, 1>>) |> recv!(<<0x02, 0x10, 0x45, 0x01>>)
  end

  defp tables_off do
    Persistence.Repo.active().query!("ALTER TABLE characters RENAME TO characters_off")
    on_exit(fn -> Persistence.Repo.active().query!("ALTER TABLE characters_off RENAME TO characters") end)
  end

  test "a database failure on 0x1001 answers 0x145 with a warning", %{id: id} do
    Factory.character(id, %{slot: 0})
    {client, _handle} = world_login()
    tables_off()
    log = TestLog.capture(fn -> recv!(send!(client, <<0x01, 0x10, 0>>), <<0x02, 0x10, 0x45, 0x01>>) end)
    assert log =~ "[warning] WorldManager: character login failed, database failure"
  end

  test "a database failure on a skip answers 0x145 with a warning", %{id: id} do
    Factory.character(id, %{slot: 3, name: "Tut", tutorial_state: 0})
    {client, _handle} = world_login()
    {<<0x10, 0x11, 0>>, client} = char_login(client, 3)
    tables_off()
    log = TestLog.capture(fn -> recv!(send!(client, <<0x11, 0x11, 1>>), <<0x02, 0x10, 0x45, 0x01>>) end)
    assert log =~ "[warning] WorldManager: tutorial skip failed, database failure"
  end

  test "an accepted map login keeps the Zone connection open with an info line", %{id: id} do
    {_client, handle} = entered(id)
    log = TestLog.capture(fn -> accepted(map_login(handle)) end)
    assert log =~ ~r/\[info\] Zone: map login accepted: character \d+, map RouN, peer 127\.0\.0\.1:/
  end

  test "while the Zone connection lives 0x1001 answers 0x145; after it closed 0x1003 again", %{id: id} do
    {client, handle} = entered(id)
    zone = accepted(map_login(handle))
    {body, client} = char_login(client, 0)
    assert body == <<0x02, 0x10, 0x45, 0x01>>
    TestClient.close(zone)

    Process.put(:client, client)

    wait_until(fn ->
      {body, client} = char_login(Process.get(:client), 0)
      Process.put(:client, client)
      body == ack_1003()
    end)
  end

  test "closing the WorldManager connection closes the Zone connection", %{id: id} do
    {client, handle} = entered(id)
    zone = accepted(map_login(handle))
    TestClient.close(client)
    assert TestClient.recv_raw(zone, 2000) == {:error, :closed}
  end

  test "a changed checksum answers 0x1804 {0x147, 32}, closes with a warning and keeps the ticket", %{id: id} do
    {_client, handle} = entered(id)
    <<head::binary-size(24 + 32 * 32 + 3), byte, rest::binary>> = map_login(handle)
    changed = head <> <<Bitwise.bxor(byte, 1)>> <> rest
    theirs = binary_part(changed, 24 + 32 * 32, 32)

    log =
      TestLog.capture(fn ->
        {{:ok, body, zone}, _} = zone_login(changed)
        assert body == <<0x04, 0x18, 0x47, 0x01, 0x20>>
        assert body == <<0x04, 0x18>> <> capture(@tutorial, 0x1804, :server)
        assert TestClient.recv_raw(zone) == {:error, :closed}
      end)

    assert log =~
             "[warning] Zone: connection closed: Client data check failed: character \"Test1235\", table MapViewInfo.shn, " <>
               "server d23b262f2066487f0b122e18eeb25eb4, client #{inspect(theirs)}, peer 127.0.0.1:"

    accepted(map_login(handle))
  end

  test "ticket refusals: unknown handle, no 0x1001, used ticket", %{id: id} do
    Factory.character(id, %{slot: 0, name: "Test1235"})
    {client, handle} = world_login()
    refused(map_login(rem(handle + 1000, 0x10000)), <<0x04, 0x18, 0x41, 0x01, 0xFF>>)
    refused(map_login(handle), <<0x04, 0x18, 0x41, 0x01, 0xFF>>)
    {body, _client} = char_login(client, 0)
    assert body == ack_1003()
    accepted(map_login(handle))
    refused(map_login(handle), <<0x04, 0x18, 0x41, 0x01, 0xFF>>)
  end

  test "a wrong name answers 0x590 and leaves the ticket", %{id: id} do
    {_client, handle} = entered(id)
    <<head::binary-4, _name::binary-20, rest::binary>> = map_login(handle)

    log =
      TestLog.capture(fn ->
        refused(head <> String.pad_trailing("Other", 20, <<0>>) <> rest, <<0x04, 0x18, 0x90, 0x05, 0xFF>>)
      end)

    assert log =~ "[info] Zone: connection closed: map login refused: not the reserved character, peer 127.0.0.1:"
    accepted(map_login(handle))
  end

  describe "handlers" do
    @reservation %{kind: :first_entry, character_id: 7, name: "Test1235", map: "RouN", node: :a@x}

    defp wm_state(fields),
      do: struct!(WorldManager.Handler, Map.merge(%{worlds: [0], world_no: 0, step: :open, user_no: 1}, fields))

    test "a refusal with a log line writes the line before it sends 0x145" do
      state = wm_state(%{})
      fail = %CharLoginfailAck{error: 0x145}

      assert {^state, [{:log, :warning, "character login failed, database failure"}, {:send, ^fail}]} =
               WorldManager.Handler.handle_info(state, {:character_selected, {:error, :database}})

      assert {^state, [{:log, :info, "character login refused: map GuildT01 is not running"}, {:send, ^fail}]} =
               WorldManager.Handler.handle_info(state, {:zone_found, %{login_map: "GuildT01"}, :error})

      assert {^state, [{:log, :warning, "tutorial skip failed, database failure"}, {:send, ^fail}]} =
               WorldManager.Handler.handle_info(state, {:tutorial_skipped, %{}, {:error, :database}})
    end

    test "a redeem from another node is :wrong_node and keeps the reservation" do
      state = wm_state(%{reservation: @reservation})

      assert {{:error, :wrong_node}, ^state, []} =
               WorldManager.Handler.handle_call(state, {:redeem, "Test1235", :b@x, self()})

      assert {{:ok, %{kind: :first_entry, character_id: 7, map: "RouN"}}, %{reservation: :none}, [_watch]} =
               WorldManager.Handler.handle_call(state, {:redeem, "Test1235", :a@x, self()})
    end

    test "a map-change reservation: another node is :wrong_node and keeps it, the right node gets the struct" do
      parked = %{placeholder: :player}
      reserve = %{character_id: 7, map: "RouVal01", x: 13_658, y: 7812, node: :a@x, player: parked}
      zone_pid = self()
      state = wm_state(%{character: "Test1235", handle: 0x445C, zone: zone_pid})

      assert {{:ok, 0x445C}, %{reservation: %{kind: :map_change}, zone: :none} = reserved, []} =
               WorldManager.Handler.handle_call(state, {:reserve, zone_pid, reserve})

      assert {{:error, :wrong_node}, ^reserved, []} =
               WorldManager.Handler.handle_call(reserved, {:redeem, "Test1235", :b@x, self()})

      me = self()

      assert {{:ok, %{kind: :map_change, character_id: 7, map: "RouVal01", x: 13_658, y: 7812, player: ^parked}},
              %{reservation: :none, character: "Test1235"}, [{:perform, {:watch_zone, ^me}}]} =
               WorldManager.Handler.handle_call(reserved, {:redeem, "Test1235", :a@x, me})
    end

    test "a reserve on a session without a character in the world is :no_session" do
      state = wm_state(%{handle: 1})
      assert {{:error, :no_session}, ^state, []} = WorldManager.Handler.handle_call(state, {:reserve, self(), %{}})
    end

    test "a reserve from a process that is not the session's Zone connection is :no_session" do
      other = spawn(fn -> :ok end)
      state = wm_state(%{character: "Test1235", handle: 1, zone: other})
      assert {{:error, :no_session}, ^state, []} = WorldManager.Handler.handle_call(state, {:reserve, self(), %{}})
    end

    test "0x0C18 {1} between two maps drops the map-login ticket with one info line" do
      reservation = %{kind: :map_change, character_id: 7, name: "Test1235", map: "RouN", node: :a@x}
      state = wm_state(%{character: "Test1235", zone: :none, reservation: reservation})

      assert {%{reservation: :none}, [{:log, :info, "map-login ticket dropped: back to the character list"}]} =
               WorldManager.Handler.handle_packet(state, %UserNormallogoutCmd{logout_type: 1})
    end

    test "the Zone answers :wrong_node with 0x1804 {0x141, 0xFF} and closes" do
      state = %Zone.Handler{checksums: []}

      assert {^state,
              [
                {:send, %MapLoginfailAck{error: 0x141, wrong_data_file_index: 0xFF}},
                {:close, :info, "map login refused: reserved for another Zone node"}
              ]} = Zone.Handler.handle_info(state, {:redeemed, {:error, :wrong_node}})
    end

    test "an auto-save timer in step :loading is dropped and the next 0x1803 arms it again" do
      player =
        struct!(Zone.Player,
          character: %{},
          world_no: 0,
          map: "RouN",
          x: 0,
          y: 0,
          walk_speed: 0,
          run_speed: 0,
          map_type: 0,
          equipment: %{},
          address: "",
          last_good: {0, 0}
        )

      state = %Zone.Handler{checksums: [], step: :loading, auto_save?: true, player: player}

      assert {%{auto_save?: false} = loading, []} = Zone.Handler.handle_info(state, {:timer, :auto_save})

      assert {_, [{:perform, {:login_complete, _, _, _, false}}]} =
               Zone.Handler.handle_packet(loading, %Proto.Packets.MapLogincompleteCmd{})
    end

    test "pushed sight packets are dropped before the world and sent in it" do
      msg = {:cluster, {:packets, [%Proto.Packets.MapLogoutCmd{handle: 8001}]}}
      state = %Zone.Handler{checksums: [], step: :loading}

      assert {^state, []} = Zone.Handler.handle_info(state, msg)

      assert {_, [{:send, %Proto.Packets.MapLogoutCmd{handle: 8001}}]} =
               Zone.Handler.handle_info(%{state | step: :in_world}, msg)
    end
  end
end
