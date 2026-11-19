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

  test "root children" do
    assert [%{id: :pg}] = Cluster.Root.children([])

    assert [
             %{id: :pg},
             {Cluster.Supervisor,
              [[pinata: [strategy: Cluster.Strategy.Epmd, config: [hosts: [:a@b]]]], [name: Cluster.Libcluster]]}
           ] = Cluster.Root.children(["a@b"])
  end
end
