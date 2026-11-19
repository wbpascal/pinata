defmodule WorldManager.HandOffTest do
  # Login to WorldManager, in one node (:single) and in two peer nodes (:peers); see TestPeers.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Proto.Packets.{
    UserClientVersionCheckReq,
    UserLoginworldReq,
    UserUsLoginReq,
    UserWorldStatusReq,
    UserWorldselectAck,
    UserWorldselectReq,
    UserXtrapReq
  }

  @key "20151116141627"

  setup_all do
    peers = TestPeers.start()
    on_exit(fn -> TestPeers.stop(peers) end)
    %{peers: peers}
  end

  setup %{topology: topology, peers: peers} do
    Persistence.Repo.active().query!("DELETE FROM accounts")
    {:ok, _} = Persistence.create_account("admin", "pw")

    case topology do
      :single ->
        %{
          login: {~c"127.0.0.1", 9010},
          wm: {~c"127.0.0.1", 9110},
          wm_port: 9110,
          call: fn _part, m, f, a -> apply(m, f, a) end
        }

      :peers ->
        %{
          login: {~c"127.0.0.1", peers.login_port},
          wm: {~c"127.0.0.1", peers.wm_port},
          wm_port: peers.wm_port,
          call: fn part, m, f, a -> :peer.call(peers[part], m, f, a) end
        }
    end
  end

  defp connect({host, port}) do
    client = TestClient.connect(host, port)
    {:ok, <<0x07, 0x08, _::binary>>, client} = TestClient.recv_raw(client)
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

  # Logs in at Login and selects world 0. Returns the key and the Login client.
  defp select(t, status \\ 6) do
    client = connect(t.login)
    client = client |> send!(%UserClientVersionCheckReq{version_key: @key}) |> recv!(<<0x67, 0x0C, 1, 0>>)

    client =
      client
      |> send!(%UserUsLoginReq{user_name: "admin", password: "pw", spawnapps: <<0::160>>})
      |> send!(%UserXtrapReq{key_length: 0, key: ""})
      |> recv!(<<0x05, 0x0C, 1>>)

    assert {:ok, <<0x0A, 0x0C, _::binary>>, client} = TestClient.recv_raw(client)
    client = send!(client, %UserWorldselectReq{world_no: 0})

    assert {:ok, %UserWorldselectAck{world_status: ^status, port: port, validate: key}, client} =
             TestClient.recv(client)

    assert port == t.wm_port
    {key, client}
  end

  defp world_login(t, name, key) do
    t.wm |> connect() |> send!(%UserLoginworldReq{user_name: name, validate: key})
  end

  defp refused(client) do
    client = recv!(client, <<0x15, 0x0C, 0x44, 0x00>>)
    assert {:error, :closed} = TestClient.recv_raw(client)
  end

  defp alive(client) do
    {:ok, client} = TestClient.send_raw(client, <<0x04, 0x08>>)
    recv!(client, <<0x05, 0x08>>)
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not reached")
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  for topology <- [:single, :peers] do
    describe "#{topology}" do
      @describetag topology: topology

      test "an unknown key is refused", t do
        refused(world_login(t, "admin", List.duplicate(1, 32)))
      end

      test "the right key with another user name is refused and the reservation is kept", t do
        {key, _login} = select(t)
        refused(world_login(t, "other", key))
        t |> world_login("admin", key) |> alive()
      end

      test "a key works once", t do
        {key, _login} = select(t)
        first = t |> world_login("admin", key) |> alive()
        refused(world_login(t, "admin", key))
        alive(first)
      end

      test "a key older than 30 s is refused", t do
        :ok = t.call.(:wm, Application, :put_env, [:pinata, :clock_source, TestClock])
        on_exit(fn -> t.call.(:wm, Application, :delete_env, [:pinata, :clock_source]) end)
        :ok = t.call.(:wm, TestClock, :set, [0])
        {key, _login} = select(t)
        :ok = t.call.(:wm, TestClock, :set, [31_000_000])
        refused(world_login(t, "admin", key))
      end

      test "a second login cuts the first", t do
        {key, _login} = select(t)
        first = t |> world_login("admin", key) |> alive()

        {key2, _login2} = select(t)
        first = recv!(first, <<0x17, 0x0C, 0x83, 0x06>>)
        assert {:error, :closed} = TestClient.recv_raw(first)
        t |> world_login("admin", key2) |> alive()
      end

      test "the player count follows the connection", t do
        {key, _login} = select(t)
        client = t |> world_login("admin", key) |> alive()
        eventually(fn -> t.call.(:login, Cluster.Registry, :player_count, [0]) == 1 end)
        TestClient.close(client)
        eventually(fn -> t.call.(:login, Cluster.Registry, :player_count, [0]) == 0 end)
      end
    end
  end

  describe "single node" do
    @describetag topology: :single

    test "a full world makes no reservation", t do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(pid, :kill) end)
      :ok = :pg.join(Cluster.Registry.scope(), {:players, 0}, List.duplicate(pid, 2375))

      {key, _login} = select(t, 5)
      assert Enum.any?(key, &(&1 != 0))
      refused(world_login(t, "admin", key))
    end

    test "a first packet other than 0x0C0F closes the socket", t do
      client = t.wm |> connect() |> send!(%UserWorldStatusReq{})
      assert {:error, :closed} = TestClient.recv_raw(client)
    end

    test "a second 0x0C0F is ignored", t do
      {key, _login} = select(t)
      client = t |> world_login("admin", key) |> alive()
      client |> send!(%UserLoginworldReq{user_name: "admin", validate: key}) |> alive()
    end
  end
end
