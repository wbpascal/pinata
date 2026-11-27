defmodule Cluster.NodeLogTest do
  use ExUnit.Case, async: false

  test "a node that connects and one that is lost" do
    pid = start_supervised!(Cluster.NodeLog)

    log =
      TestLog.capture(fn ->
        send(pid, {:nodeup, :"a@127.0.0.1"})
        send(pid, {:nodedown, :"a@127.0.0.1"})
        _ = :sys.get_state(pid)
      end)

    assert log =~ "[info] Cluster: node a@127.0.0.1 connected\n"
    assert log =~ "[warning] Cluster: node a@127.0.0.1 lost\n"
  end
end
