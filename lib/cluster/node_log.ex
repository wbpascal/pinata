defmodule Cluster.NodeLog do
  @moduledoc "Logs when a node connects or is lost. Started in multi-node mode only."
  use GenServer

  require Logger

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_arg), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl GenServer
  def init(state) do
    # returns :error on a node without distribution; then no node ever connects
    _ = :net_kernel.monitor_nodes(true)
    {:ok, state}
  end

  @impl GenServer
  def handle_info({:nodeup, node}, state) do
    Logger.info("Cluster: node #{node} connected")
    {:noreply, state}
  end

  def handle_info({:nodedown, node}, state) do
    Logger.warning("Cluster: node #{node} lost")
    {:noreply, state}
  end
end
