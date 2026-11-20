defmodule Login.WorldWatchTest do
  use ExUnit.Case, async: false

  test "a world that appears and disappears" do
    pid = start_supervised!({Login.WorldWatch, [%{number: 77, name: "TEST"}]})
    _ = :sys.get_state(pid)

    assert TestLog.capture(fn ->
             send(pid, :check)
             _ = :sys.get_state(pid)
           end) == ""

    spec = %{id: :wm, start: {Agent, :start_link, [fn -> 0 end, [name: Cluster.Registry.world_manager(77)]]}}
    agent = start_supervised!(spec)

    log =
      TestLog.capture(fn ->
        send(pid, :check)
        _ = :sys.get_state(pid)
      end)

    assert log =~ "[info] Login: world 77 (TEST) is available\n"

    :ok = stop_supervised(:wm)
    refute Process.alive?(agent)

    log =
      TestLog.capture(fn ->
        send(pid, :check)
        _ = :sys.get_state(pid)
      end)

    assert log =~ "[warning] Login: world 77 (TEST) is unavailable\n"
  end
end
