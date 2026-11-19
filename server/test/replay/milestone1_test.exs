defmodule Replay.Milestone1Test do
  # The harness swaps the global clock source, so it cannot run async.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  # Opcodes of later issues (character create and delete). Their lines are left out of every replay; the indices
  # stay. The heartbeat lines 0x0804 / 0x0805 stay: the client 0x0805 lines keep the WorldManager connection of
  # capture 37 alive while the test clock jumps.
  @not_yet [0x1401, 0x1406, 0x1407, 0x140C]

  # Each test replays its capture up to its stop point; the stop point moves forward with later issues. With
  # `conn`, only that connection of the capture is replayed (indices stay). `close_after` lists the packets after
  # which the client closed that connection.
  defp replay(name, setup, stop, opts \\ []) do
    apply(Replay.Setups, setup, [])

    transcript = "transcripts/#{name}.txt" |> Path.expand(__DIR__) |> Replay.Transcript.read!()
    packets = Enum.reject(transcript.packets, &(&1.opcode in @not_yet))
    packets = if conn = opts[:conn], do: Enum.filter(packets, &(&1.conn == conn)), else: packets

    Replay.assert_replay(%{transcript | packets: packets},
      stop: stop,
      endpoints: Replay.Topology.endpoints(),
      close_after: opts[:close_after] || [],
      sync_after: opts[:sync_after] || []
    )
  end

  @heartbeat_refusals "26_11_15_37_login-heartbeat-refusals-delete"

  test "26_11_15_login-logout", do: replay("26_11_15_login-logout", :login_logout, :end, close_after: [16])
  test "26_11_15_login-errors", do: replay("26_11_15_login-errors", :login_errors, 18)
  test "26_11_15_create-char", do: replay("26_11_15_create-char", :create_char, 22)

  test "26_11_15_37_login-heartbeat-refusals-delete",
    do: replay(@heartbeat_refusals, :login_heartbeat_refusals_delete, 70, close_after: [60])

  test "26_11_15_37_login-heartbeat-refusals-delete: world closed" do
    child = {WorldManager.World, 0}
    :ok = Replay.Topology.call(:wm, Supervisor, :terminate_child, [WorldManager.Supervisor, child])

    on_exit(fn ->
      {:ok, _} = Replay.Topology.call(:wm, Supervisor, :restart_child, [WorldManager.Supervisor, child])
    end)

    # the Login node must see it
    wait_until(fn -> Replay.Topology.call(:login, Cluster.Registry, :whereis_world_manager, [0]) == :error end)
    replay(@heartbeat_refusals, :login_heartbeat_refusals_delete, 90, conn: "login#3")
  end

  test "26_11_15_37_login-heartbeat-refusals-delete: world full" do
    # :pg.join takes local pids only, so the process lives on the WorldManager node
    pid = Replay.Topology.call(:wm, :erlang, :spawn, [Process, :sleep, [:infinity]])

    on_exit(fn ->
      Replay.Topology.call(:wm, Process, :exit, [pid, :kill])
      # the next test must not see the full world on the Login node
      wait_until(fn -> Replay.Topology.call(:login, Cluster.Registry, :player_count, [0]) == 0 end)
    end)

    :ok =
      Replay.Topology.call(:wm, :pg, :join, [Cluster.Registry.scope(), {:players, 0}, List.duplicate(pid, 2375)])

    # :pg spreads between nodes asynchronously
    wait_until(fn -> Replay.Topology.call(:login, Cluster.Registry, :player_count, [0]) >= 2375 end)
    replay(@heartbeat_refusals, :login_heartbeat_refusals_delete, 108, conn: "login#4")
  end

  test "26_11_16_37b_char-select-rename-refusals",
    do: replay("26_11_16_37b_char-select-rename-refusals", :char_select_rename_refusals, 9)

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not reached")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end
end
