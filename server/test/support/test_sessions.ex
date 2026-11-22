defmodule TestSessions do
  @moduledoc """
  Waits until no session process (`:pg` group `{:session, _}`) is left on the Login, WorldManager and Zone node. A
  Zone connection of the previous test saves while it ends; the factories reuse character ids, so a late save would
  overwrite the next test's character.
  """

  @doc "Polls every 20 ms, 3 s at most, then raises."
  @spec wait_none() :: :ok
  def wait_none, do: wait_none(150)

  defp wait_none(0), do: raise("session processes are still running: #{inspect(left())}")

  defp wait_none(tries) do
    case left() do
      [] ->
        :ok

      _left ->
        Process.sleep(20)
        wait_none(tries - 1)
    end
  end

  defp left do
    scope = Cluster.Registry.scope()

    for part <- [:login, :wm, :zone],
        {:session, _} = group <- Replay.Topology.call(part, :pg, :which_groups, [scope]),
        pid <- Replay.Topology.call(part, :pg, :get_local_members, [scope, group]),
        do: {part, group, pid}
  end
end
