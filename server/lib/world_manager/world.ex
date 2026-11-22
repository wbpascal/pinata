defmodule WorldManager.World do
  @moduledoc """
  The registered process of one world: its presence under `Cluster.Registry.world_manager/1` marks the world open.

  It also holds the login reservations Login makes when a client selects the world (flow:
  `docs/technical/flows/world-select.md`). They live in memory, are good for one use and expire after 30 s; the
  original never expires them. A successful take also hands out the session handle of
  `0x0C14` (`worldmanager`): a counter per world, 0, 1, 2, ... wrapping at 0xFFFF.

  It also keeps the map table (ADR 0002): which Zone node runs which map. A joining Zone node gets every map it offers
  that no other Zone node runs. When a Zone node is lost, each of its maps goes to the remaining Zone node that
  offered it with the highest rendezvous hash, and that node is sent `{:run_maps, world_number, names}`.
  """

  use GenServer

  require Logger

  @login_ttl_ms 30_000

  @spec start_link(Settings.world()) :: GenServer.on_start()
  def start_link(world), do: GenServer.start_link(__MODULE__, world, name: Cluster.Registry.world_manager(world.number))

  @doc "Uses up the reservation with this key and user name. `:error` when there is none or it is too old."
  @spec take_login(Cluster.Registry.world_id(), String.t(), [0..0xFFFF]) :: {:ok, pos_integer(), 0..0xFFFF} | :error
  def take_login(world_id, user_name, validate),
    do: GenServer.call(Cluster.Registry.world_manager(world_id), {:take_login, user_name, validate})

  @doc "The Zone node that runs the map (the map table of ADR 0002); used by character select and map change."
  @spec zone_of(Cluster.Registry.world_id(), binary()) ::
          {:ok, %{node: node(), host: String.t(), port: pos_integer()}} | :error
  def zone_of(world_id, map_name),
    do: GenServer.call(Cluster.Registry.world_manager(world_id), {:zone_of, map_name})

  @impl GenServer
  def init(world), do: {:ok, %{world: world, logins: %{}, next_handle: 0, zones: %{}, maps: %{}}}

  @impl GenServer
  def handle_call({:expect_login, %{user_no: user_no, user_name: user_name, validate: validate}}, _from, state) do
    now = now()
    fresh = Map.filter(state.logins, fn {_key, {_no, _name, at}} -> now - at < @login_ttl_ms end)
    {:reply, :ok, %{state | logins: Map.put(fresh, validate, {user_no, user_name, now})}}
  end

  def handle_call({:join_zone, pid, {host, port}, offered}, _from, state) do
    assigned = Enum.reject(offered, &is_map_key(state.maps, &1))
    maps = Enum.reduce(assigned, state.maps, &Map.put(&2, &1, pid))
    zone = %{ref: Process.monitor(pid), host: host, port: port, offered: offered}
    number = state.world.number

    Logger.info(
      "WorldManager: Zone node #{node(pid)} joined world #{number} at #{host}:#{port}, #{length(assigned)} maps"
    )

    {:reply, assigned, %{state | zones: Map.put(state.zones, pid, zone), maps: maps}}
  end

  def handle_call({:zone_of, map_name}, _from, state) do
    reply =
      with {:ok, pid} <- Map.fetch(state.maps, map_name),
           {:ok, zone} <- Map.fetch(state.zones, pid) do
        {:ok, %{node: node(pid), host: zone.host, port: zone.port}}
      end

    {:reply, reply, state}
  end

  def handle_call({:take_login, user_name, validate}, _from, state) do
    case Map.fetch(state.logins, validate) do
      {:ok, {user_no, ^user_name, at}} ->
        logins = Map.delete(state.logins, validate)

        if now() - at < @login_ttl_ms do
          # A counter: the handle of a live session can repeat after 65536 logins. Harmless: Cluster.Sessions.redeem/2 asks every session with the handle and the character name decides.
          handle = state.next_handle
          {:reply, {:ok, user_no, handle}, %{state | logins: logins, next_handle: rem(handle + 1, 0x10000)}}
        else
          {:reply, :error, %{state | logins: logins}}
        end

      _other ->
        {:reply, :error, state}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case Map.pop(state.zones, pid) do
      {nil, _zones} -> {:noreply, state}
      {_zone, zones} -> {:noreply, lose_zone(state, pid, zones, stopping?(pid, reason))}
    end
  end

  # A local Zone part that exits with a shutdown reason means this node is stopping: not a lost Zone node.
  defp stopping?(pid, reason), do: node(pid) == node() and (reason == :shutdown or match?({:shutdown, _}, reason))

  defp lose_zone(state, pid, zones, stopping?) do
    lost = for {name, ^pid} <- state.maps, do: name
    kept = Map.drop(state.maps, lost)

    {maps, moves} = Enum.reduce(lost, {kept, %{}}, &reassign(&1, &2, zones))

    number = state.world.number
    for {winner, names} <- moves, do: send(winner, {:run_maps, number, Enum.reverse(names)})
    moved = moves |> Map.values() |> Enum.map(&length/1) |> Enum.sum()

    unless stopping? do
      Logger.warning(
        "WorldManager: Zone node #{node(pid)} of world #{number} lost, #{moved} maps reassigned, #{length(lost) - moved} not running"
      )
    end

    %{state | zones: zones, maps: maps}
  end

  defp reassign(name, {maps, moves}, zones) do
    case for({zone, %{offered: offered}} <- zones, name in offered, do: zone) do
      [] ->
        {maps, moves}

      candidates ->
        winner = Enum.max_by(candidates, &:erlang.phash2({name, &1}))
        {Map.put(maps, name, winner), Map.update(moves, winner, [name], &[name | &1])}
    end
  end

  defp now, do: Clock.monotonic_time(:millisecond)
end
