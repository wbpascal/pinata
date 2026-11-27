defmodule Zone.MapTableTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000
  @moduletag capture_log: true

  test "single node: the test VM runs every plain field map" do
    zone = TestPorts.app().zone
    assert Registry.count(Zone.MapRegistry) >= 88
    assert {:ok, %{node: node(), host: "127.0.0.1", port: zone}} == WorldManager.World.zone_of(0, "Rou")
    assert :error = WorldManager.World.zone_of(0, "GuildT01")
  end

  test "multi node: the Zone peer runs the maps" do
    peers = TestPeers.start()
    on_exit(fn -> TestPeers.stop(peers) end)

    assert {:ok, %{node: peers.nodes.zone, host: "127.0.0.1", port: peers.zone_port}} ==
             :peer.call(peers.wm, WorldManager.World, :zone_of, [0, "Rou"])
  end

  test "a second Zone node gets the maps of a lost one" do
    start_supervised!({WorldManager.World, %{number: 201, name: "T"}})
    a = spawn(fn -> Process.sleep(:infinity) end)
    assert ["X", "Y"] = Cluster.WorldManager.join_zone(201, a, {"10.0.0.1", 1}, ["X", "Y"])
    assert [] = Cluster.WorldManager.join_zone(201, self(), {"10.0.0.2", 2}, ["X", "Y"])
    assert {:ok, %{host: "10.0.0.1"}} = WorldManager.World.zone_of(201, "X")

    Process.exit(a, :kill)
    assert_receive {:run_maps, 201, names}
    assert Enum.sort(names) == ["X", "Y"]
    assert {:ok, %{host: "10.0.0.2", port: 2}} = WorldManager.World.zone_of(201, "X")
    assert :error = WorldManager.World.zone_of(201, "Z")
  end
end
