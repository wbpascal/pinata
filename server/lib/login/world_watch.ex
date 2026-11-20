defmodule Login.WorldWatch do
  @moduledoc """
  Logs when a world becomes available to Login or unavailable. It looks every world up in `Cluster.Registry` once a
  second. A world counts as unavailable at start, so nothing is logged until it appears. Started in multi-node mode
  only.
  """
  use GenServer

  require Logger

  @check_ms 1_000

  @spec start_link([Settings.world()]) :: GenServer.on_start()
  def start_link(worlds), do: GenServer.start_link(__MODULE__, worlds, name: __MODULE__)

  @impl GenServer
  def init(worlds) do
    send(self(), :check)
    {:ok, %{worlds: worlds, up: MapSet.new()}}
  end

  @impl GenServer
  def handle_info(:check, state) do
    _ = Process.send_after(self(), :check, @check_ms)

    up =
      for world <- state.worlds, available?(world, state.up), into: MapSet.new(), do: world.number

    {:noreply, %{state | up: up}}
  end

  defp available?(world, up) do
    now? = match?({:ok, _}, Cluster.Registry.whereis_world_manager(world.number))
    before? = MapSet.member?(up, world.number)

    cond do
      now? and not before? -> Logger.info("Login: world #{world.number} (#{world.name}) is available")
      before? and not now? -> Logger.warning("Login: world #{world.number} (#{world.name}) is unavailable")
      true -> :ok
    end

    now?
  end
end
