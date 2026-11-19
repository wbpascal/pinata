defmodule Replay.Milestone1Test do
  # The harness swaps the global clock source, so it cannot run async.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  # Each test replays its capture up to the packet before the first world select (0x0C0B, issue #42); the stop point moves forward with later issues.
  defp replay(name, setup, stop) do
    apply(Replay.Setups, setup, [])

    "transcripts/#{name}.txt"
    |> Path.expand(__DIR__)
    |> Replay.Transcript.read!()
    |> Replay.assert_replay(stop: stop, endpoints: Replay.Topology.endpoints())
  end

  test "26_11_15_login-logout", do: replay("26_11_15_login-logout", :login_logout, 7)
  test "26_11_15_login-errors", do: replay("26_11_15_login-errors", :login_errors, 16)
  test "26_11_15_create-char", do: replay("26_11_15_create-char", :create_char, 9)

  test "26_11_15_37_login-heartbeat-refusals-delete",
    do: replay("26_11_15_37_login-heartbeat-refusals-delete", :login_heartbeat_refusals_delete, 21)

  test "26_11_16_37b_char-select-rename-refusals",
    do: replay("26_11_16_37b_char-select-rename-refusals", :char_select_rename_refusals, 7)
end
