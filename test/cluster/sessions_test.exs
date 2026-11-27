defmodule Cluster.SessionsTest do
  use ExUnit.Case, async: true

  @reservation %{character_id: 7, map: "RouN", x: 1, y: 2, node: :a@x, player: %{}}

  test "a reserve answers the leave call of a session that waits for this Zone connection" do
    zone = self()
    test = self()

    session =
      spawn(fn ->
        send(test, {:left, GenServer.call(zone, {:cluster, :leave}, 2_000)})

        receive do
          {:"$gen_call", from, {:cluster, {:reserve, ^zone, _r}}} -> GenServer.reply(from, {:ok, 7})
        end
      end)

    # the stub is blocked in its leave call now
    Process.sleep(50)
    {us, result} = :timer.tc(fn -> Cluster.Sessions.reserve(session, @reservation) end)
    assert {:ok, 7} = result
    assert us < 1_000_000
    assert_received {:left, :ok}
  end

  test "a session that has ended is :no_session and leaves no message behind" do
    session = spawn(fn -> :ok end)
    ref = Process.monitor(session)
    assert_receive {:DOWN, ^ref, :process, _, _}
    assert {:error, :no_session} = Cluster.Sessions.reserve(session, @reservation)
    refute_received _any
  end
end
