defmodule Replay.Milestone1Test do
  # The harness swaps the global clock source, so it cannot run async.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  # Each test replays its capture up to its stop point; the stop point moves forward with later issues. With
  # `conn`, only that connection of the capture is replayed (indices stay). `close_after` lists the packets after
  # which the client closed that connection.
  defp replay(name, setup, stop, opts \\ []) do
    apply(Replay.Setups, setup, [])

    transcript = "transcripts/#{name}.txt" |> Path.expand(__DIR__) |> Replay.Transcript.read!()
    packets = transcript.packets
    packets = if conn = opts[:conn], do: Enum.filter(packets, &(&1.conn == conn)), else: packets

    Replay.assert_replay(%{transcript | packets: packets},
      stop: stop,
      endpoints: Replay.Topology.endpoints(),
      close_after: opts[:close_after] || [],
      sync_after: opts[:sync_after] || [],
      masks: opts[:masks] || [],
      before: opts[:before] || %{}
    )
  end

  @heartbeat_refusals "26_11_15_37_login-heartbeat-refusals-delete"

  test "26_11_15_login-logout", do: replay("26_11_15_login-logout", :login_logout, :end, close_after: [16])
  test "26_11_15_login-errors", do: replay("26_11_15_login-errors", :login_errors, :end)
  test "26_11_15_create-char", do: replay("26_11_15_create-char", :create_char, :end)

  test "26_11_15_37_login-heartbeat-refusals-delete",
    do: replay(@heartbeat_refusals, :login_heartbeat_refusals_delete, 70, close_after: [60])

  test "26_11_15_37_login-heartbeat-refusals-delete: world closed" do
    child = {WorldManager.World, 0}
    :ok = Replay.Topology.call(:wm, Supervisor, :terminate_child, [WorldManager.Supervisor, child])

    on_exit(fn ->
      {:ok, _} = Replay.Topology.call(:wm, Supervisor, :restart_child, [WorldManager.Supervisor, child])
      # the new World has an empty map table until Zone.Maps joins again by its 1 s retry; the next test needs it
      wait_until(fn -> Replay.Topology.call(:wm, WorldManager.World, :zone_of, [0, "Rou"]) != :error end, 250)
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

  # Account B of the capture; the flag is set as the capture's server script did before each login.
  for {conn, login, stop, flag, function} <- [
        {"login#5", 112, 115, "blocked", :set_blocked},
        {"login#6", 119, 122, "not login-able", :set_login_able}
      ] do
    test "26_11_15_37_login-heartbeat-refusals-delete: #{flag}" do
      value = unquote(function) == :set_blocked

      replay(@heartbeat_refusals, :login_heartbeat_refusals_delete, unquote(stop),
        conn: unquote(conn),
        before: %{unquote(login) => fn -> :ok = apply(Persistence, unquote(function), ["testaccountB", value]) end}
      )
    end
  end

  # Stops before the rename 0x140F (index 27, milestone 2): the list, the refused create and five heartbeats.
  test "26_11_16_37b_char-select-rename-refusals" do
    reason =
      "rename right of Test2 (a tCharacterChangeID row made by the capture's prep): character rename is " <>
        "milestone 2, the rebuild sends the values of a character without one; the mask covers every character of the list"

    masks =
      for field <- [:need_change_id, :change_id_init, :change_id_row_no],
          do: {Proto.Packets.UserLoginworldAck, [:avatars, field], reason}

    replay("26_11_16_37b_char-select-rename-refusals", :char_select_rename_refusals, 26, masks: masks)
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not reached")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end
end
