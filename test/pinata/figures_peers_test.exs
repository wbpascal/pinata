defmodule Pinata.FiguresPeersTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000
  @moduletag capture_log: true

  test "collect merges the figures of every connected node" do
    peers = TestPeers.start()
    on_exit(fn -> TestPeers.stop(peers) end)

    :ok = :peer.call(peers.wm, Pinata.Figures, :reset, [])
    d = System.convert_time_unit(2_000_000, :microsecond, :native)

    for peer <- [peers.login, peers.zone] do
      :ok = :peer.call(peer, :telemetry, :execute, [[:pinata, :tick, :stop], %{duration: d}, %{}])
    end

    %{merged: merged, nodes: nodes} = :peer.call(peers.wm, Pinata.Figures, :collect, [])
    assert List.last(merged.tick) == 2
    assert length(nodes) == 3
    nodes = Map.new(nodes)
    assert {:ok, %{tick: login}} = nodes[peers.nodes.login]
    assert {:ok, %{tick: zone}} = nodes[peers.nodes.zone]
    assert {:ok, %{tick: wm}} = nodes[peers.nodes.wm]
    assert {List.last(login), List.last(zone), List.last(wm)} == {1, 1, 0}
  end
end
