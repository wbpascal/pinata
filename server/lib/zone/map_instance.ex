defmodule Zone.MapInstance do
  @moduledoc """
  One process per map instance (ADR 0009), registered in `Zone.MapRegistry` under `{world number, map name}`.

  The state holds the NPCs placed from `ShineNPC` (in file order, with their handles), the block data (`nil` until
  the first entry), the players, the tick count and the tick schedule. Players are opaque ids until the player
  struct exists (issue 108). The map ticks every 100 ms through `Clock.send_after/3`, only while it has players.
  """

  use GenServer

  require Logger

  @tick_ms 100
  # NPC handles 17084 to 17339, docs/knowledge/Z01.md §3
  @first_npc_handle 17_084

  @spec start_link({Cluster.Registry.world_id(), binary(), Path.t()}) :: GenServer.on_start()
  def start_link({world_id, map_name, _data_dir} = arg),
    do: GenServer.start_link(__MODULE__, arg, name: {:via, Registry, {Zone.MapRegistry, {world_id, map_name}}})

  @spec whereis(Cluster.Registry.world_id(), binary()) :: {:ok, pid()} | :error
  def whereis(world_id, map_name) do
    case Registry.lookup(Zone.MapRegistry, {world_id, map_name}) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc "A player enters. The first entry reads the block data; when that fails the entry is refused."
  @spec enter(pid(), term()) :: :ok | {:error, :no_block_data}
  def enter(pid, id), do: GenServer.call(pid, {:enter, id})

  @spec leave(pid(), term()) :: :ok
  def leave(pid, id), do: GenServer.call(pid, {:leave, id})

  @impl GenServer
  def init({world_id, name, data_dir}) do
    npcs =
      GameData.ShineNpc
      |> GameData.lookup(:map, name)
      |> Enum.with_index(@first_npc_handle)
      |> Enum.map(fn {row, handle} -> %{handle: handle, row: row} end)

    # A cast to a name nobody holds is dropped (an instance started alone).
    GenServer.cast(Zone.Maps, {:watch, world_id, name, self()})

    {:ok,
     %{
       world: world_id,
       name: name,
       data_dir: data_dir,
       npcs: npcs,
       block_data: nil,
       players: MapSet.new(),
       ticks: 0,
       tick_ref: nil,
       next_tick: 0
     }}
  end

  @impl GenServer
  def handle_call({:enter, id}, _from, state) do
    case load_block_data(state) do
      {:ok, state} -> {:reply, :ok, state |> Map.update!(:players, &MapSet.put(&1, id)) |> start_ticking()}
      :error -> {:reply, {:error, :no_block_data}, state}
    end
  end

  def handle_call({:leave, id}, _from, state) do
    state = Map.update!(state, :players, &MapSet.delete(&1, id))
    {:reply, :ok, if(MapSet.size(state.players) == 0, do: %{state | tick_ref: nil}, else: state)}
  end

  # The ref ends a tick chain: a leave and a new entry inside 100 ms would otherwise run two chains.
  @impl GenServer
  def handle_info({:tick, ref}, %{tick_ref: ref} = state) do
    next = state.next_tick + @tick_ms
    Clock.send_after(self(), {:tick, ref}, max(next - Clock.monotonic_time(:millisecond), 0))
    {:noreply, %{state | ticks: state.ticks + 1, next_tick: next}}
  end

  def handle_info({:tick, _stale}, state), do: {:noreply, state}

  defp load_block_data(%{block_data: nil} = state) do
    case GameData.BlockData.load(state.data_dir, state.name) do
      {:ok, data} ->
        Logger.info("Zone: map #{state.name}: block data loaded, #{byte_size(data.bits)} bytes")
        {:ok, %{state | block_data: data}}

      {:error, message} ->
        Logger.error("Zone: map #{state.name}: #{message}")
        :error
    end
  end

  defp load_block_data(state), do: {:ok, state}

  defp start_ticking(%{tick_ref: nil} = state) do
    ref = make_ref()
    Clock.send_after(self(), {:tick, ref}, @tick_ms)
    %{state | tick_ref: ref, next_tick: Clock.monotonic_time(:millisecond) + @tick_ms}
  end

  defp start_ticking(state), do: state
end
