defmodule Zone.MapInstance do
  @moduledoc """
  One process per map instance (ADR 0009), registered in `Zone.MapRegistry` under `{world number, map name}`.

  The state holds the NPCs placed from `ShineNPC` (in file order, with their handles), the block data (`nil` until
  the first entry), the players by object handle (`Zone.Player`), the tick count and the tick schedule. A player
  gets the next free handle from 8000 to 9499, counting on from the last one given and wrapping to 8000, so a freed
  handle is not reused before the wrap; 1500 players fill the map. A player enters in mode 0 (receives nothing,
  shown to nobody) and is in mode 1 after `login_complete/2`. The instance monitors the connection of each player
  and removes its players when it ends. The map ticks every 100 ms through `Clock.send_after/3`, only while it has
  players. Each tick is the telemetry span `[:pinata, :tick]` (`docs/technical/telemetry.md`).
  """

  use GenServer

  require Logger

  @tick_ms 100
  # NPC handles 17084 to 17339, docs/knowledge/Z01.md §3
  @first_npc_handle 17_084
  # player handles, docs/knowledge/Z01.md §3
  @first_handle 8000
  @last_handle 9499

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

  @doc """
  A player enters in mode 0 and gets its object handle. The first entry reads the block data; when that fails the
  entry is refused. A full map (1500 players) refuses too.
  """
  @spec enter(pid(), Zone.Player.t()) :: {:ok, 8000..9499} | {:error, :no_block_data | :full}
  def enter(pid, %Zone.Player{} = player), do: GenServer.call(pid, {:enter, player})

  @doc "The player of the handle has loaded the map (`0x1803`): mode 1, and the answer packets of `Zone.MapEntry`."
  @spec login_complete(pid(), 8000..9499) :: {:ok, [struct()]} | {:error, :not_entered}
  def login_complete(pid, handle), do: GenServer.call(pid, {:login_complete, handle})

  @spec leave(pid(), 8000..9499) :: :ok
  def leave(pid, handle), do: GenServer.call(pid, {:leave, handle})

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
       players: %{},
       next_handle: @first_handle,
       ticks: 0,
       tick_ref: nil,
       next_tick: 0
     }}
  end

  @impl GenServer
  def handle_call({:enter, player}, _from, state) do
    with {:ok, state} <- load_block_data(state),
         {:ok, handle} <- free_handle(state) do
      _ = if is_pid(player.conn), do: Process.monitor(player.conn)
      player = %{player | handle: handle, mode: 0}

      state = %{
        state
        | players: Map.put(state.players, handle, player),
          next_handle: if(handle == @last_handle, do: @first_handle, else: handle + 1)
      }

      {:reply, {:ok, handle}, start_ticking(state)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:login_complete, handle}, _from, state) do
    case state.players do
      %{^handle => %Zone.Player{mode: 0} = player} ->
        # issue 109 adds the sight exchange here: the player is shown to the others and sees them
        player = %{player | mode: 1}
        {:reply, {:ok, Zone.MapEntry.login_complete(player)}, put_in(state.players[handle], player)}

      %{} ->
        {:reply, {:error, :not_entered}, state}
    end
  end

  def handle_call({:leave, handle}, _from, state), do: {:reply, :ok, remove(state, &(&1 == handle))}

  # The ref ends a tick chain: a leave and a new entry inside 100 ms would otherwise run two chains.
  @impl GenServer
  def handle_info({:tick, ref}, %{tick_ref: ref} = state) do
    metadata = %{world: state.world, map: state.name}

    :telemetry.span([:pinata, :tick], metadata, fn ->
      next = state.next_tick + @tick_ms
      Clock.send_after(self(), {:tick, ref}, max(next - Clock.monotonic_time(:millisecond), 0))
      {{:noreply, %{state | ticks: state.ticks + 1, next_tick: next}}, metadata}
    end)
  end

  def handle_info({:tick, _stale}, state), do: {:noreply, state}

  # The connection of a player ended: its players leave (saving and 0x1805 are issue 111).
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, remove(state, fn handle -> state.players[handle].conn == pid end)}

  defp remove(state, leaves?) do
    state = %{state | players: Map.reject(state.players, fn {handle, _player} -> leaves?.(handle) end)}
    if map_size(state.players) == 0, do: %{state | tick_ref: nil}, else: state
  end

  # The next free handle from next_handle on, wrapping from 9499 to 8000.
  defp free_handle(state) do
    count = @last_handle - @first_handle + 1

    Enum.find_value(0..(count - 1), {:error, :full}, fn i ->
      handle = @first_handle + rem(state.next_handle - @first_handle + i, count)
      if not Map.has_key?(state.players, handle), do: {:ok, handle}
    end)
  end

  defp load_block_data(%{block_data: nil} = state) do
    case GameData.BlockData.load(state.data_dir, state.name) do
      {:ok, data} ->
        Logger.info("Zone: map #{state.name}: block data loaded, #{byte_size(data.bits)} bytes")
        {:ok, %{state | block_data: data}}

      {:error, message} ->
        Logger.error("Zone: map #{state.name}: #{message}")
        {:error, :no_block_data}
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
