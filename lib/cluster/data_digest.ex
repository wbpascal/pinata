defmodule Cluster.DataDigest do
  @moduledoc """
  The data directory digest check of multi-node mode (ADR 0006). One process per node, named `Cluster.DataDigest`.
  When two nodes connect, each sends its digest to the other. A node without the WorldManager part whose digest
  differs from that of a WorldManager node prints both digests and stops. Not started in single-node mode.
  """
  use GenServer

  require Logger

  @type option :: {:digest, String.t()} | {:authority?, boolean()}

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts), name: __MODULE__)

  @impl GenServer
  def init(state) do
    # returns :error on a node without distribution; then no node ever connects
    _ = :net_kernel.monitor_nodes(true)
    Enum.each(Node.list(), &announce(&1, state))
    {:ok, state}
  end

  @impl GenServer
  def handle_info({:nodeup, node}, state) do
    announce(node, state)
    {:noreply, state}
  end

  def handle_info({:nodedown, _node}, state), do: {:noreply, state}

  @impl GenServer
  def handle_cast({:digest, _node, digest, _authority?}, %{digest: digest} = state), do: {:noreply, state}

  def handle_cast({:digest, node, theirs, true}, %{authority?: false} = state) do
    IO.puts(:stderr, """
    Data directory digest mismatch, the node stops:
      this node (#{node()}): #{state.digest}
      WorldManager node (#{node}): #{theirs}
    Every node must use the same data directory.\
    """)

    System.stop(1)
    {:noreply, state}
  end

  def handle_cast({:digest, node, theirs, false}, %{authority?: true} = state) do
    Logger.error(
      "Cluster: node #{node} is refused: its data directory digest #{theirs} " <>
        "differs from #{state.digest} of this WorldManager node"
    )

    # the answer makes the other node stop, also when it missed the first announcement
    announce(node, state)
    {:noreply, state}
  end

  # two nodes of the same kind: neither decides
  def handle_cast({:digest, _node, _theirs, _authority?}, state), do: {:noreply, state}

  defp announce(node, state),
    do: GenServer.cast({__MODULE__, node}, {:digest, node(), state.digest, state.authority?})
end
