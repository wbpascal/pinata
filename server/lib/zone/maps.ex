defmodule Zone.Maps do
  @moduledoc """
  Joins the WorldManager of each world, starts the map instances it assigns and watches them for the crash line.

  It joins inside `init/1`, so in single-node mode the maps run before the listener starts. When the WorldManager of
  a world is not registered yet, or is lost, it tries again every second. A crashed map instance is started again,
  empty, by `Zone.MapSupervisor`; this process only logs it. Started again itself, it watches the instances that
  kept running.
  """

  use GenServer

  require Logger

  @retry_ms 1_000

  @spec start_link(Settings.t()) :: GenServer.on_start()
  def start_link(settings), do: GenServer.start_link(__MODULE__, settings, name: __MODULE__)

  @impl GenServer
  def init(settings) do
    names = Enum.map(GameData.plain_field_maps(), & &1.map_id_client)
    placed = names |> Enum.map(&length(GameData.lookup(GameData.ShineNpc, :map, &1))) |> Enum.sum()
    total = GameData.count(GameData.ShineNpc)
    Logger.info("Zone: #{total - placed} of #{total} NPC rows skipped: their map does not run")

    state = %{settings: settings, names: names, worlds: %{}, maps: %{}}
    for %{number: n} <- settings.world, do: :ok = Cluster.Registry.join_zones(n, self())
    {:ok, Enum.reduce(settings.world, state, &join(&2, &1.number))}
  end

  @impl GenServer
  def handle_info({:join, number}, state), do: {:noreply, join(state, number)}

  def handle_info({:run_maps, world, names}, state) do
    _ = start_maps(state.settings, world, names)
    Logger.info("Zone: world #{world}: #{length(names)} map instances taken over from a lost Zone node")
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case {Map.pop(state.worlds, ref), Map.pop(state.maps, ref)} do
      {{number, worlds}, _maps} when is_integer(number) ->
        Logger.warning("Zone: WorldManager of world #{number} lost, joining again when it returns")
        _ = Process.send_after(self(), {:join, number}, @retry_ms)
        {:noreply, %{state | worlds: worlds}}

      {_worlds, {{world, name, _pid}, maps}} ->
        unless graceful?(reason) do
          Logger.error("Zone: map instance #{name} of world #{world} crashed (#{inspect(reason)}), started again empty")
        end

        {:noreply, %{state | maps: maps}}

      _unknown ->
        {:noreply, state}
    end
  end

  @impl GenServer
  # A join again (a WorldManager that returned) re-watches the running instances: one monitor per instance.
  def handle_cast({:watch, world, name, pid}, state) do
    if Enum.any?(state.maps, &match?({_ref, {_world, _name, ^pid}}, &1)),
      do: {:noreply, state},
      else: {:noreply, %{state | maps: Map.put(state.maps, Process.monitor(pid), {world, name, pid})}}
  end

  defp graceful?(reason), do: reason in [:normal, :shutdown] or match?({:shutdown, _}, reason)

  defp join(state, number) do
    case Cluster.Registry.whereis_world_manager(number) do
      :error ->
        _ = Process.send_after(self(), {:join, number}, @retry_ms)
        state

      {:ok, pid} ->
        address = {state.settings.public_host, state.settings.zone.port}
        assigned = Cluster.WorldManager.join_zone(number, self(), address, state.names)
        _ = start_maps(state.settings, number, assigned)
        Logger.info("Zone: world #{number}: #{length(assigned)} map instances started")
        %{state | worlds: Map.put(state.worlds, Process.monitor(pid), number)}
    end
  end

  defp start_maps(settings, world, names) do
    for name <- names do
      case DynamicSupervisor.start_child(Zone.MapSupervisor, {Zone.MapInstance, {world, name, settings.data_dir}}) do
        {:ok, _pid} -> :ok
        # A restarted Zone.Maps watches the instances that kept running.
        {:error, {:already_started, pid}} -> GenServer.cast(self(), {:watch, world, name, pid})
      end
    end
  end
end
