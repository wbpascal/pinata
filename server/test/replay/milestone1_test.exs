defmodule Replay.Milestone1Test do
  # The harness swaps the global clock source, so it cannot run async.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  # Each test replays its capture up to the successful world select (the S 0x0C0C line); the stop point moves
  # forward with later issues. With `conn`, only that connection of the capture is replayed (indices stay).
  defp replay(name, setup, stop, conn \\ nil) do
    apply(Replay.Setups, setup, [])

    transcript = "transcripts/#{name}.txt" |> Path.expand(__DIR__) |> Replay.Transcript.read!()

    transcript =
      if conn, do: %{transcript | packets: Enum.filter(transcript.packets, &(&1.conn == conn))}, else: transcript

    Replay.assert_replay(transcript, stop: stop, endpoints: Replay.Topology.endpoints())
  end

  @heartbeat_refusals "26_11_15_37_login-heartbeat-refusals-delete"

  test "26_11_15_login-logout", do: replay("26_11_15_login-logout", :login_logout, 9)
  test "26_11_15_login-errors", do: replay("26_11_15_login-errors", :login_errors, 18)
  test "26_11_15_create-char", do: replay("26_11_15_create-char", :create_char, 11)

  test "26_11_15_37_login-heartbeat-refusals-delete",
    do: replay(@heartbeat_refusals, :login_heartbeat_refusals_delete, 23)

  test "26_11_15_37_login-heartbeat-refusals-delete: world closed" do
    # Index 90 is 0x0C18, which is not defined yet.
    :ok = Supervisor.terminate_child(WorldManager.Supervisor, {WorldManager.World, 0})

    on_exit(fn -> {:ok, _} = Supervisor.restart_child(WorldManager.Supervisor, {WorldManager.World, 0}) end)

    wait_until(fn -> Cluster.Registry.whereis_world_manager(0) == :error end)
    replay(@heartbeat_refusals, :login_heartbeat_refusals_delete, 89, "login#3")
  end

  test "26_11_15_37_login-heartbeat-refusals-delete: world full" do
    # Index 108 is 0x0C18, which is not defined yet.
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    :ok = :pg.join(Cluster.Registry.scope(), {:players, 0}, List.duplicate(pid, 2375))
    replay(@heartbeat_refusals, :login_heartbeat_refusals_delete, 107, "login#4")
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
