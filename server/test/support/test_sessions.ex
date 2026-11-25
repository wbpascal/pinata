defmodule TestSessions do
  @moduledoc """
  Waits until no session process (`:pg` group `{:session, _}`) is left on the Login, WorldManager and Zone node. A
  Zone connection of the previous test saves while it ends; the factories reuse character ids, so a late save would
  overwrite the next test's character.
  """

  @doc """
  Polls every 20 ms, 3 s at most, then raises. `call` runs `(part, module, function, args)` on the node of a part;
  the default is `Replay.Topology.call/4`, a test with its own `TestPeers` passes a function that calls them.
  """
  @spec wait_none((atom(), module(), atom(), list() -> term())) :: :ok
  def wait_none(call \\ &Replay.Topology.call/4), do: wait_none(call, 150)

  defp wait_none(call, 0), do: raise("session processes are still running: #{inspect(left(call))}")

  defp wait_none(call, tries) do
    case left(call) do
      [] ->
        :ok

      _left ->
        Process.sleep(20)
        wait_none(call, tries - 1)
    end
  end

  defp left(call) do
    scope = Cluster.Registry.scope()

    for part <- [:login, :wm, :zone],
        {:session, _} = group <- call.(part, :pg, :which_groups, [scope]),
        pid <- call.(part, :pg, :get_local_members, [scope, group]),
        do: {part, group, pid}
  end
end
