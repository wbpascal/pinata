defmodule WorldManager.World do
  @moduledoc """
  The registered process of one world: its presence under `Cluster.Registry.world_manager/1` marks the world open.

  It also holds the login reservations Login makes when a client selects the world (flow:
  `docs/technical/flows/world-select.md`). They live in memory, are good for one use and expire after 30 s; the
  original never expires them. A successful take also hands out the session handle of
  `0x0C14` (`worldmanager`): a counter per world, 0, 1, 2, ... wrapping at 0xFFFF.
  """

  use GenServer

  @login_ttl_ms 30_000

  @spec start_link(Settings.world()) :: GenServer.on_start()
  def start_link(world), do: GenServer.start_link(__MODULE__, world, name: Cluster.Registry.world_manager(world.number))

  @doc "Uses up the reservation with this key and user name. `:error` when there is none or it is too old."
  @spec take_login(Cluster.Registry.world_id(), String.t(), [0..0xFFFF]) :: {:ok, pos_integer(), 0..0xFFFF} | :error
  def take_login(world_id, user_name, validate),
    do: GenServer.call(Cluster.Registry.world_manager(world_id), {:take_login, user_name, validate})

  @impl GenServer
  def init(world), do: {:ok, %{world: world, logins: %{}, next_handle: 0}}

  @impl GenServer
  def handle_call({:expect_login, %{user_no: user_no, user_name: user_name, validate: validate}}, _from, state) do
    now = now()
    fresh = Map.filter(state.logins, fn {_key, {_no, _name, at}} -> now - at < @login_ttl_ms end)
    {:reply, :ok, %{state | logins: Map.put(fresh, validate, {user_no, user_name, now})}}
  end

  def handle_call({:take_login, user_name, validate}, _from, state) do
    case Map.fetch(state.logins, validate) do
      {:ok, {user_no, ^user_name, at}} ->
        logins = Map.delete(state.logins, validate)

        if now() - at < @login_ttl_ms do
          # shortcut: a counter, a handle of a live session can repeat after 65536 logins; make it a unique key when 0x1801 looks sessions up by it (milestone 2)
          handle = state.next_handle
          {:reply, {:ok, user_no, handle}, %{state | logins: logins, next_handle: rem(handle + 1, 0x10000)}}
        else
          {:reply, :error, %{state | logins: logins}}
        end

      _other ->
        {:reply, :error, state}
    end
  end

  defp now, do: Clock.monotonic_time(:millisecond)
end
