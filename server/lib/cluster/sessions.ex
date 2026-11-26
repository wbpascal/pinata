defmodule Cluster.Sessions do
  @moduledoc """
  Which process is the session of an account (`:pg` group `{:session, user_no}`), and which sessions have a session
  handle (`:pg` group `{:wm_handle, handle}`): the Zone finds the session of a map login by it (flow:
  `docs/technical/flows/enter-world.md`). A session whose character is in the world is a member of the `:pg` group
  `{:character, world_no, key}` (`key` = the name with ASCII letters lower-cased): a whisper finds its receiver by it
  and the sessions pass the whisper on in messages (flow: `docs/technical/flows/whisper.md`).

  A map change (flow: `docs/technical/flows/map-change.md`): the old Zone connection parks the player struct in the
  session with `reserve/2`; the request carries the calling Zone connection and the session accepts it only from its
  current Zone connection; a `leave` call that arrives during the wait is answered `:ok`. The reservation is the
  map-login ticket the new Zone connection redeems with `redeem/2` as an entry of kind `:map_change`. It has no timer
  and ends with the session process, its next `0x1001` or `0x0C18 {1}`.

  A kick (`&kickout`, flow: `docs/technical/flows/gm-commands.md`): the GM's Zone connection finds the session by
  character name (`find_character/2`) and sends it `kick/2`; the session sends `0x0C17` and tells its Zone connection
  with `kicked/1`, which closes. Neither waits for an answer.
  """

  @type entry ::
          %{
            kind: :first_entry,
            world_no: Cluster.Registry.world_id(),
            user_no: pos_integer(),
            character_id: pos_integer(),
            name: binary(),
            map: String.t()
          }
          | %{
              kind: :map_change,
              world_no: Cluster.Registry.world_id(),
              user_no: pos_integer(),
              character_id: pos_integer(),
              name: binary(),
              map: String.t(),
              x: non_neg_integer(),
              y: non_neg_integer(),
              player: struct()
            }
  @type reservation :: %{
          character_id: pos_integer(),
          map: String.t(),
          x: non_neg_integer(),
          y: non_neg_integer(),
          node: node(),
          player: struct()
        }
  @type whisper :: %{
          talker: binary(),
          receiver: binary(),
          item_link_count: 0..255,
          content: binary(),
          links: binary()
        }
  @type refusal :: :no_session | :no_ticket | :wrong_character | :wrong_node

  @doc """
  Makes the calling process the session of the account. The other members of the account's group (the older
  session and its Zone connection) get `{:cluster, :session_replaced}`; the call returns when they have all ended,
  so the character of the older session is saved, or `{:error, :timeout}` after the replace timeout (5 s).
  """
  @spec take_over(pos_integer()) :: :ok | {:error, :timeout}
  def take_over(user_no) do
    scope = Cluster.Registry.scope()
    group = {:session, user_no}
    me = self()
    members = :pg.get_members(scope, group)

    refs =
      for pid <- members, pid != me do
        ref = Process.monitor(pid)
        send(pid, {:cluster, :session_replaced})
        ref
      end

    # Two logins of one account at the same instant on two nodes can miss each other.
    :ok = if me in members, do: :ok, else: :pg.join(scope, group, me)
    timer = make_ref()
    timer_ref = Process.send_after(self(), {timer, :timeout}, Application.get_env(:pinata, :replace_timeout_ms, 5_000))
    result = await_down(refs, timer)
    _ = Process.cancel_timer(timer_ref)

    receive do
      {^timer, :timeout} -> :ok
    after
      0 -> :ok
    end

    result
  end

  @doc "The calling process (a Zone connection) joins the group of the account, so a take-over tells it and waits for it."
  @spec join(pos_integer()) :: :ok
  def join(user_no), do: :pg.join(Cluster.Registry.scope(), {:session, user_no}, self())

  @doc """
  Asks the Zone connection to leave the world (save, remove from the map) and waits for it, 5 s at most. A Zone
  connection that has ended counts as left: it saves before it ends.
  """
  @spec leave_world(pid()) :: :ok | {:error, :timeout}
  def leave_world(pid) do
    GenServer.call(pid, {:cluster, :leave}, 5_000)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ended -> :ok
  end

  defp await_down([], _timer), do: :ok

  defp await_down([ref | rest] = refs, timer) do
    receive do
      {:DOWN, ^ref, :process, _pid, _reason} ->
        await_down(rest, timer)

      {^timer, :timeout} ->
        Enum.each(refs, &Process.demonitor(&1, [:flush]))
        {:error, :timeout}
    end
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

  @doc """
  Parks a player in its session as the reservation of a map change; the answer is the session handle for 0x180A.
  The request names the calling Zone connection, and the session accepts it only from its current Zone connection.
  A `leave` call (`leave_world/1`) the session makes during the wait is answered `:ok` (the player is saved and off
  the map already); the session then refuses the reserve. 5 s at most.
  """
  @spec reserve(pid(), reservation()) :: {:ok, 0..0xFFFF} | {:error, :no_session}
  def reserve(pid, reservation) do
    # the reply goes to the monitor's alias, as in GenServer.call/3: a late reply never reaches the mailbox
    # (Net.Connection would crash on it)
    ref = Process.monitor(pid, alias: :reply_demonitor)
    send(pid, {:"$gen_call", {ref, ref}, {:cluster, {:reserve, self(), reservation}}})
    await_reserved(ref)
  end

  defp await_reserved(ref) do
    receive do
      {^ref, reply} ->
        reply

      {:DOWN, ^ref, :process, _pid, _reason} ->
        {:error, :no_session}

      # the session waits for this connection in leave_world/1: the player is saved and off the map already
      {:"$gen_call", from, {:cluster, :leave}} ->
        GenServer.reply(from, :ok)
        await_reserved(ref)
    after
      5_000 ->
        Process.demonitor(ref, [:flush])
        {:error, :no_session}
    end
  end

  @doc "Tells the session process that its character has loaded the map (`0x1803`): it sends the WorldManager burst."
  @spec map_login_done(pid()) :: :ok
  def map_login_done(pid) do
    send(pid, {:cluster, :map_login_done})
    :ok
  end

  @doc "The character of the calling session process is in the world: `find_character/2` finds the process by its name."
  @spec enter_world(Cluster.Registry.world_id(), binary()) :: :ok
  def enter_world(world_no, name), do: :pg.join(Cluster.Registry.scope(), {:character, world_no, key(name)}, self())

  @doc "The character of the calling session process is no longer in the world."
  @spec leave_world(Cluster.Registry.world_id(), binary()) :: :ok
  def leave_world(world_no, name) do
    _ = :pg.leave(Cluster.Registry.scope(), {:character, world_no, key(name)}, self())
    :ok
  end

  @doc "The session process whose character of this name is in the world, on any node; ASCII letter case is ignored."
  @spec find_character(Cluster.Registry.world_id(), binary()) :: {:ok, pid()} | :error
  def find_character(world_no, name) do
    case :pg.get_members(Cluster.Registry.scope(), {:character, world_no, key(name)}) do
      [pid | _] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc "Passes a whisper from the calling session process to the receiver's session process."
  @spec whisper(pid(), whisper()) :: :ok
  def whisper(pid, whisper) do
    send(pid, {:cluster, {:whisper, self(), whisper}})
    :ok
  end

  @doc "Tells the talker's session process that the whisper reached the receiver (with the receiver's stored spelling)."
  @spec whisper_delivered(pid(), whisper()) :: :ok
  def whisper_delivered(pid, whisper) do
    send(pid, {:cluster, {:whisper_delivered, whisper}})
    :ok
  end

  @doc "Tells the talker's session process that the receiver was no longer in the world."
  @spec whisper_refused(pid(), binary()) :: :ok
  def whisper_refused(pid, receiver) do
    send(pid, {:cluster, {:whisper_refused, receiver}})
    :ok
  end

  @doc "Kicks the character of a session process: the session sends `0x0C17` with the code and leaves the world."
  @spec kick(pid(), 0..0xFFFF) :: :ok
  def kick(pid, code) do
    send(pid, {:cluster, {:kick, code}})
    :ok
  end

  @doc "Tells a Zone connection that its session kicked the character: the connection closes (and saves)."
  @spec kicked(pid()) :: :ok
  def kicked(zone_pid) do
    send(zone_pid, {:cluster, :kicked})
    :ok
  end

  # the rule of Persistence.Character.name_key/1 (Cluster may not depend on Persistence)
  defp key(name), do: for(<<b <- name>>, into: <<>>, do: <<if(b in ?A..?Z, do: b + 32, else: b)>>)

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
