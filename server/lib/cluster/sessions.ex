defmodule Cluster.Sessions do
  @moduledoc "Which process is the session of an account (`:pg` group `{:session, user_no}`)."

  @doc "Makes the calling process the session of the account. Every older session process gets `{:cluster, :session_replaced}`."
  @spec take_over(pos_integer()) :: :ok
  def take_over(user_no) do
    scope = Cluster.Registry.scope()
    group = {:session, user_no}
    me = self()
    members = :pg.get_members(scope, group)
    Enum.each(members, fn pid -> if pid != me, do: send(pid, {:cluster, :session_replaced}) end)
    # Two logins of one account at the same instant on two nodes can miss each other.
    if me in members, do: :ok, else: :pg.join(scope, group, me)
  end
end
