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

  test "root children" do
    assert [%{id: :pg}] = Cluster.Root.children([])

    assert [
             %{id: :pg},
             {Cluster.Supervisor,
              [[pinata: [strategy: Cluster.Strategy.Epmd, config: [hosts: [:a@b]]]], [name: Cluster.Libcluster]]}
           ] = Cluster.Root.children(["a@b"])
  end
end
