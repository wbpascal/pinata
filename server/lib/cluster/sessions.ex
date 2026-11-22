defmodule Cluster.Sessions do
  @moduledoc """
  Which process is the session of an account (`:pg` group `{:session, user_no}`), and which sessions have a session
  handle (`:pg` group `{:wm_handle, handle}`): the Zone finds the session of a map login by it (flow:
  `docs/technical/flows/enter-world.md`).
  """

  @type entry :: %{
          kind: :first_entry,
          world_no: Cluster.Registry.world_id(),
          user_no: pos_integer(),
          character_id: pos_integer(),
          name: binary(),
          map: String.t()
        }
  @type refusal :: :no_session | :no_ticket | :wrong_character | :wrong_node

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

  @doc "The calling process stops being the session of the account."
  @spec leave(pos_integer()) :: :ok
  def leave(user_no) do
    _ = :pg.leave(Cluster.Registry.scope(), {:session, user_no}, self())
    :ok
  end

  @doc "The calling session process can be found by its session handle."
  @spec register_handle(0..0xFFFF) :: :ok
  def register_handle(handle), do: :pg.join(Cluster.Registry.scope(), {:wm_handle, handle}, self())

  @doc """
  Redeems the map-login ticket of the session with this handle for the calling Zone connection process. Every
  session with the handle is asked (a handle can repeat after 65536 logins); the character name and the node decide.
  """
  @spec redeem(0..0xFFFF, binary()) :: {:ok, pid(), entry()} | {:error, refusal()}
  def redeem(handle, name) do
    request = {:cluster, {:redeem, name, node(), self()}}

    results =
      for pid <- :pg.get_members(Cluster.Registry.scope(), {:wm_handle, handle}) do
        {pid, ask(pid, request)}
      end

    case Enum.find(results, &match?({_pid, {:ok, _entry}}, &1)) do
      {pid, {:ok, entry}} -> {:ok, pid, entry}
      nil -> first_refusal(results)
    end
  end

  defp ask(pid, request) do
    GenServer.call(pid, request)
  catch
    :exit, _reason -> {:error, :no_session}
  end

  defp first_refusal(results) do
    case Enum.find(results, fn {_pid, result} -> result != {:error, :no_session} end) do
      {_pid, {:error, reason}} -> {:error, reason}
      nil -> {:error, :no_session}
    end
  end
end
