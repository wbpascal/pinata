defmodule ClusterTest.FakeWorld do
  @moduledoc false
  use GenServer

  @impl GenServer
  def init(test), do: {:ok, test}

  @impl GenServer
  def handle_call({:expect_login, _} = message, _from, test) do
    send(test, message)
    {:reply, :ok, test}
  end
end

defmodule ClusterTest do
  use ExUnit.Case, async: true

  alias Cluster.Registry

  test "names" do
    assert Registry.login() == {:global, {:login}}
    assert Registry.world_manager(901) == {:global, {:world_manager, 901}}
  end

  test "world manager lookup" do
    assert Registry.whereis_world_manager(901) == :error
    spec = %{id: :wm, start: {Agent, :start_link, [fn -> 0 end, [name: Registry.world_manager(901)]]}}
    agent = start_supervised!(spec)
    assert Registry.whereis_world_manager(901) == {:ok, agent}
  end

  test "zones group" do
    pid = start_supervised!({Agent, fn -> 0 end})
    assert Registry.join_zones(902, pid) == :ok
    assert Registry.zones(902) == [pid]
  end

  test "players group" do
    assert Registry.player_count(903) == 0
    pid = start_supervised!({Agent, fn -> 0 end})
    assert Registry.join_players(903, pid) == :ok
    assert Registry.player_count(903) == 1
  end

  test "take_over" do
    assert Cluster.Sessions.take_over(904) == :ok
    assert Cluster.Sessions.take_over(904) == :ok
    refute_receive {:cluster, _}, 50

    test = self()

    spawn_link(fn ->
      :ok = Cluster.Sessions.take_over(904)
      send(test, :joined)

      receive do
        message -> send(test, {:forwarded, message})
      end
    end)

    # The spawned process is the older session now: wait for it, then take over again.
    assert_receive {:cluster, :session_replaced}, 1000
    assert_receive :joined, 1000
    :ok = Cluster.Sessions.take_over(904)
    assert_receive {:forwarded, {:cluster, :session_replaced}}, 1000
  end

  test "leave" do
    :ok = Cluster.Sessions.take_over(906)
    assert Cluster.Sessions.leave(906) == :ok
    assert Cluster.Sessions.leave(906) == :ok
    test = self()
    spawn_link(fn -> send(test, {:took, Cluster.Sessions.take_over(906)}) end)
    assert_receive {:took, :ok}, 1000
    refute_receive {:cluster, _}, 50
  end

  test "find_character" do
    me = self()
    assert Cluster.Sessions.find_character(907, "Test1235") == :error
    assert Cluster.Sessions.enter_world(907, "Test1235") == :ok
    assert Cluster.Sessions.find_character(907, "Test1235") == {:ok, me}
    assert Cluster.Sessions.find_character(907, "tEST1235") == {:ok, me}
    assert Cluster.Sessions.find_character(907, "Test1236") == :error
    assert Cluster.Sessions.find_character(908, "Test1235") == :error

    test = self()

    other =
      spawn_link(fn ->
        :ok = Cluster.Sessions.enter_world(907, "X14B")
        send(test, :entered)
        Process.sleep(:infinity)
      end)

    assert_receive :entered, 1000
    assert Cluster.Sessions.find_character(907, "x14b") == {:ok, other}

    assert Cluster.Sessions.leave_world(907, "TEST1235") == :ok
    assert Cluster.Sessions.leave_world(907, "Test1235") == :ok
    assert Cluster.Sessions.find_character(907, "Test1235") == :error
  end

  test "expect_login" do
    {:ok, _} = GenServer.start_link(ClusterTest.FakeWorld, self(), name: Registry.world_manager(905))
    request = %{user_no: 1, user_name: "a", validate: [1]}
    assert Cluster.WorldManager.expect_login(905, request) == :ok
    assert_receive {:expect_login, ^request}
  end

  test "root children" do
    assert [%{id: :pg}] = Cluster.Root.children([])

    assert [
             %{id: :pg},
             {Cluster.Supervisor,
              [[pinata: [strategy: Cluster.Strategy.Epmd, config: [hosts: [:a@b]]]], [name: Cluster.Libcluster]]}
           ] = Cluster.Root.children(["a@b"])
  end
end
