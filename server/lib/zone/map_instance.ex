defmodule Zone.MapInstance do
  @moduledoc """
  One process per map instance (ADR 0009), registered in `Zone.MapRegistry` under `{world number, map name}`.

  The state holds the sight radius (`MapInfo.Sight`; 0 for a map without a row), the NPCs placed from `ShineNPC`
  (`Zone.Npc`, in file order, with their handles) and the shown ones by handle, the grid of every object position
  (`Zone.Grid`, cell size = the sight radius, 1600 when it is 0), the block data (`nil` until the first entry), the
  players by object handle (`Zone.Player`), the chat rules of the map (`Zone.Chat.rules/1`), the tick count and the
  tick schedule. A player
  gets the next free handle from 8000 to 9499, counting on from the last one given and wrapping to 8000, so a freed
  handle is not reused before the wrap; 1500 players fill the map. A player enters in mode 0 (receives nothing,
  shown to nobody) and is in mode 1 after `login_complete/2`. The instance monitors the connection of each player
  and removes its players when it ends. It never touches the database: the connection saves its player (flow:
  `docs/technical/flows/leave-world.md`). Stopped in order (`:normal`, `:shutdown`), it sends each player's
  connection `{:cluster, {:map_stopped, player}}` so the connection saves that snapshot and closes; a crash sends
  nothing. The map ticks every 100 ms through `Clock.send_after/3`, only while it has
  players. Each tick is the telemetry span `[:pinata, :tick]` (`docs/technical/telemetry.md`).

  Sight (`Zone.Sight`, `docs/technical/sight.md`): `login_complete/2` runs the entry exchange, `step/3` sends the
  appears and disappears of a position change, `inform/3` answers `0x1C01`, a player that leaves is announced with
  `0x1805` to the players in sight. Packets for other players go to their connections as
  `{:cluster, {:packets, packets}}`.

  Chat (`Zone.Chat`, `docs/technical/flows/chat.md`): `chat/4` checks a line of a player in mode 1 against the map's
  rules and the player's `chat` state, sends a passed line to the other receivers (the players in sight for normal
  chat, every player in mode 1 for a shout) and returns the speaker's own packets: its copy of the line, `0x0848`
  for a spam block, or nothing.
  """

  use GenServer

  alias Proto.Packets.MapLogoutCmd
  alias Proto.Packets.MiscChatBlockSpamerBlocktimeCmd

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

  @doc "Removes the player of the handle and returns it as it was on the map; `:error` for an unknown handle."
  @spec leave(pid(), 8000..9499) :: {:ok, Zone.Player.t()} | :error
  def leave(pid, handle), do: GenServer.call(pid, {:leave, handle})

  @doc "The current player of the handle (for the auto-save)."
  @spec player(pid(), 8000..9499) :: {:ok, Zone.Player.t()} | :error
  def player(pid, handle), do: GenServer.call(pid, {:player, handle})

  @doc """
  The player of the handle stands at a new point: the appear and disappear packets go to the players concerned.
  Called by the movement of issue 110; the caller has checked the point.
  """
  @spec step(pid(), 8000..9499, Zone.Grid.point()) :: :ok | {:error, :not_entered}
  def step(pid, handle, {x, y}) when is_integer(x) and x >= 0 and is_integer(y) and y >= 0,
    do: GenServer.call(pid, {:step, handle, {x, y}})

  @doc "Sets the dimension and the sub-layer of the player of the handle; sends nothing."
  @spec set_layer(pid(), 8000..9499, integer(), 0..5) :: :ok | {:error, :not_entered}
  def set_layer(pid, handle, dimension, sub_layer) when is_integer(dimension) and sub_layer in 0..5,
    do: GenServer.call(pid, {:set_layer, handle, dimension, sub_layer})

  @doc "The answer to `0x1C01` of the player of `requester` for an object handle; `[]` when it is not on the map."
  @spec inform(pid(), 8000..9499, non_neg_integer()) :: [struct()]
  def inform(pid, requester, handle), do: GenServer.call(pid, {:inform, requester, handle})

  @doc """
  A chat line of the player of the handle (`Zone.Chat`): returns the packets for the speaker's own connection (its
  copy of the line, or `0x0848`, or nothing) and sends the line to the other receivers: the players in sight for
  `:normal`, every player in mode 1 for `:shout`. `[]` for an unknown handle or a player in mode 0.
  """
  @spec chat(pid(), 8000..9499, :normal | :shout, Zone.Chat.line()) :: [struct()]
  def chat(pid, handle, kind, line) when kind in [:normal, :shout],
    do: GenServer.call(pid, {:chat, handle, kind, line})

  @impl GenServer
  def init({world_id, name, data_dir}) do
    # terminate/2 runs on a supervisor shutdown only when exits are trapped.
    Process.flag(:trap_exit, true)

    radius =
      case GameData.fetch(GameData.MapInfo, name) do
        {:ok, %{sight: sight}} ->
          sight

        :error ->
          Logger.info("Zone: map #{name}: no MapInfo row, sight radius 0")
          0
      end

    npcs =
      GameData.ShineNpc
      |> GameData.lookup(:map, name)
      |> Enum.with_index(@first_npc_handle)
      |> Enum.map(fn {row, handle} -> Zone.Npc.new(row, handle) end)

    _ =
      for %Zone.Npc{brief: :none} = npc <- npcs,
          do: Logger.info("Zone: map #{name}: NPC #{npc.row.mob_name} not shown: no MobInfo row")

    shown = for %Zone.Npc{brief: %{}} = npc <- npcs, do: npc
    grid = Enum.reduce(shown, Zone.Grid.new(if(radius > 0, do: radius, else: 1600)), &put_grid(&2, &1))

    # A cast to a name nobody holds is dropped (an instance started alone).
    GenServer.cast(Zone.Maps, {:watch, world_id, name, self()})

    {:ok,
     %{
       world: world_id,
       name: name,
       data_dir: data_dir,
       radius: radius,
       npcs: npcs,
       npc_index: Map.new(shown, &{&1.handle, &1}),
       grid: grid,
       block_data: nil,
       chat: Zone.Chat.rules(name),
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
          grid: put_grid(state.grid, player),
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
        player = %{player | mode: 1}
        state = put_in(state.players[handle], player)
        {packets, deliveries} = Zone.Sight.entry(view(state), player)
        deliver(deliveries)
        {:reply, {:ok, Zone.MapEntry.login_complete(player, packets)}, state}

      %{} ->
        {:reply, {:error, :not_entered}, state}
    end
  end

  def handle_call({:leave, handle}, _from, state) do
    case Map.fetch(state.players, handle) do
      {:ok, player} -> {:reply, {:ok, player}, remove(state, &(&1 == handle))}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call({:player, handle}, _from, state), do: {:reply, Map.fetch(state.players, handle), state}

  def handle_call({:step, handle, {x, y} = point}, _from, state) do
    case state.players do
      %{^handle => %Zone.Player{} = player} ->
        deliveries = Zone.Sight.step(view(state), player, point)
        moved = %{player | x: x, y: y}
        grid = state.grid |> Zone.Grid.delete(handle, {player.x, player.y}) |> put_grid(moved)
        deliver(deliveries)
        {:reply, :ok, %{state | players: Map.put(state.players, handle, moved), grid: grid}}

      %{} ->
        {:reply, {:error, :not_entered}, state}
    end
  end

  def handle_call({:set_layer, handle, dimension, sub_layer}, _from, state) do
    case state.players do
      %{^handle => %Zone.Player{} = player} ->
        player = %{player | dimension: dimension, sub_layer: sub_layer}
        {:reply, :ok, put_in(state.players[handle], player)}

      %{} ->
        {:reply, {:error, :not_entered}, state}
    end
  end

  def handle_call({:inform, requester, handle}, _from, state) do
    case state.players do
      %{^requester => %Zone.Player{} = player} -> {:reply, Zone.Sight.inform(view(state), player, handle), state}
      %{} -> {:reply, [], state}
    end
  end

  def handle_call({:chat, handle, kind, line}, _from, state) do
    case state.players do
      %{^handle => %Zone.Player{mode: 1} = player} ->
        now = Clock.monotonic_time(:millisecond)
        {verdict, chat} = Zone.Chat.check(kind, player.chat, player.character.level, state.chat, now)
        player = %{player | chat: chat}
        state = put_in(state.players[handle], player)

        case verdict do
          :pass ->
            packet = Zone.Chat.packet(kind, player, line)
            kind |> others(state, player) |> Enum.map(&{&1, [packet]}) |> deliver()
            {:reply, [packet], state}

          :silent ->
            {:reply, [], state}

          {:blocked, seconds} ->
            {:reply, [%MiscChatBlockSpamerBlocktimeCmd{block_time: seconds}], state}
        end

      %{} ->
        {:reply, [], state}
    end
  end

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

  # The connection of a player ended (the Zone connection saves, or was killed): its players leave and are announced with 0x1805.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, remove(state, fn handle -> state.players[handle].conn == pid end)}

  # Trapped exits of linked processes (none today) are ignored; the parent's exit is handled by GenServer.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # Stopped in order: each connection saves the snapshot of its player and closes.
  @impl GenServer
  def terminate(reason, state) do
    if reason in [:normal, :shutdown] or match?({:shutdown, _}, reason) do
      Enum.each(state.players, fn
        {_handle, %Zone.Player{conn: conn} = player} when is_pid(conn) -> send(conn, {:cluster, {:map_stopped, player}})
        {_handle, _player} -> :ok
      end)
    end

    :ok
  end

  defp remove(state, leaves?) do
    state =
      for {handle, player} <- state.players, leaves?.(handle), reduce: state do
        state ->
          broadcast(state, player, [%MapLogoutCmd{handle: handle}])

          %{
            state
            | players: Map.delete(state.players, handle),
              grid: Zone.Grid.delete(state.grid, handle, {player.x, player.y})
          }
      end

    if map_size(state.players) == 0, do: %{state | tick_ref: nil}, else: state
  end

  # The one "to players in sight" function, at the full radius, for the relays of later issues.
  defp broadcast(state, %Zone.Player{} = sender, packets),
    do: state |> view() |> Zone.Sight.receivers(sender) |> Enum.map(&{&1, packets}) |> deliver()

  # The receivers of a passed line besides the speaker.
  defp others(:normal, state, player), do: state |> view() |> Zone.Sight.receivers(player)

  defp others(:shout, state, player),
    do: for({h, %Zone.Player{mode: 1} = p} <- state.players, h != player.handle, do: p)

  defp view(state), do: %{radius: state.radius, grid: state.grid, npcs: state.npc_index, players: state.players}

  defp deliver(deliveries) do
    _ =
      for {%Zone.Player{conn: conn}, packets} <- deliveries,
          is_pid(conn),
          do: send(conn, {:cluster, {:packets, packets}})

    :ok
  end

  defp put_grid(grid, %{handle: handle, x: x, y: y}), do: Zone.Grid.put(grid, handle, {x, y})

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
