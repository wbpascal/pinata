defmodule Replay.Milestone1Test do
  # The harness swaps the global clock source, so it cannot run async.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  # Each test replays its capture up to the seed packet; the stop point moves forward with issue #41 and later.
  defp replay(name, setup) do
    apply(Replay.Setups, setup, [])

    "transcripts/#{name}.txt"
    |> Path.expand(__DIR__)
    |> Replay.Transcript.read!()
    |> Replay.assert_replay(stop: 1, endpoints: Replay.Topology.endpoints())
  end

  test "26_11_15_login-logout", do: replay("26_11_15_login-logout", :login_logout)
  test "26_11_15_login-errors", do: replay("26_11_15_login-errors", :login_errors)
  test "26_11_15_create-char", do: replay("26_11_15_create-char", :create_char)

  test "26_11_15_37_login-heartbeat-refusals-delete",
    do: replay("26_11_15_37_login-heartbeat-refusals-delete", :login_heartbeat_refusals_delete)

  test "26_11_16_37b_char-select-rename-refusals",
    do: replay("26_11_16_37b_char-select-rename-refusals", :char_select_rename_refusals)
end
