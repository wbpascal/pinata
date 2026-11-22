defmodule Pinata.Figures do
  @moduledoc """
  The capacity figures: the packet handling time and the tick duration, counted in fixed-bucket histograms of
  `:counters` on every node, always on. `bin/pinata rpc "Pinata.Figures.print()"` prints them merged over all
  connected nodes and per node; `Pinata.Figures.reset()` clears them. See `docs/technical/telemetry.md`.
  """

  use Boundary, top_level?: true, deps: []

  @handler "pinata-figures"
  @events [
    [:pinata, :packet, :stop],
    [:pinata, :packet, :exception],
    [:pinata, :tick, :stop],
    [:pinata, :tick, :exception]
  ]
  @boundaries_us [
    100,
    250,
    500,
    1_000,
    2_500,
    5_000,
    10_000,
    25_000,
    50_000,
    75_000,
    100_000,
    250_000,
    500_000,
    1_000_000
  ]
  @buckets length(@boundaries_us) + 1
  @figures [packet: "Packet handling time (ms)", tick: "Tick duration (ms)"]

  @type figure :: :packet | :tick
  @typedoc "One count per boundary plus the overflow bucket."
  @type counts :: [non_neg_integer()]
  @type snapshot :: %{packet: counts(), tick: counts()}
  @type collected :: %{merged: snapshot(), nodes: [{node(), {:ok, snapshot()} | :error}]}

  @doc "Creates the counters of this node and attaches the handler. May be called again."
  @spec attach() :: :ok
  def attach do
    bounds = Enum.map(@boundaries_us, &System.convert_time_unit(&1, :microsecond, :native))
    :persistent_term.put(__MODULE__, %{packet: new(), tick: new(), bounds: bounds})
    _ = :telemetry.detach(@handler)
    :ok = :telemetry.attach_many(@handler, @events, &__MODULE__.handle_event/4, nil)
  end

  defp new, do: :counters.new(@buckets, [:write_concurrency])

  @doc false
  @spec handle_event([atom()], map(), map(), term()) :: :ok
  def handle_event([:pinata, figure, _stop_or_exception], %{duration: duration}, _metadata, _config) do
    terms = :persistent_term.get(__MODULE__)
    :counters.add(Map.fetch!(terms, figure), bucket(duration, terms.bounds), 1)
  end

  @doc "The bucket bounds in ms, upper bounds, inclusive."
  @spec boundaries_ms() :: [number()]
  def boundaries_ms, do: Enum.map(@boundaries_us, &ms/1)

  defp ms(us) when rem(us, 1000) == 0, do: div(us, 1000)
  defp ms(us), do: us / 1000

  @doc "The 1-based bucket of a duration in native time units: the first bound it does not exceed, else the overflow bucket."
  @spec bucket(integer()) :: pos_integer()
  def bucket(duration), do: bucket(duration, :persistent_term.get(__MODULE__).bounds)

  defp bucket(duration, bounds) do
    case Enum.find_index(bounds, &(duration <= &1)) do
      nil -> @buckets
      index -> index + 1
    end
  end

  @doc "The counts of this node."
  @spec snapshot() :: snapshot()
  def snapshot do
    terms = :persistent_term.get(__MODULE__)
    Map.new(Keyword.keys(@figures), fn figure -> {figure, Enum.map(1..@buckets, &:counters.get(terms[figure], &1))} end)
  end

  @doc "Sets every counter of this node to 0."
  @spec reset_local() :: :ok
  def reset_local do
    terms = :persistent_term.get(__MODULE__)
    for figure <- Keyword.keys(@figures), index <- 1..@buckets, do: :counters.put(terms[figure], index, 0)
    :ok
  end

  @doc "The counts of this node and of every connected node, and their sum."
  @spec collect() :: collected()
  def collect do
    all = [node() | Node.list()]

    answers = :erpc.multicall(all, __MODULE__, :snapshot, [], 5_000)
    nodes = Enum.zip_with(all, answers, &{&1, answer(&2)})

    %{merged: merge(for({_node, {:ok, snapshot}} <- nodes, do: snapshot)), nodes: nodes}
  end

  defp answer({:ok, %{packet: _, tick: _} = snapshot}), do: {:ok, snapshot}
  defp answer(_error), do: :error

  @doc "The element-wise sum of the snapshots; all zeros for none."
  @spec merge([snapshot()]) :: snapshot()
  def merge(snapshots) do
    zero = List.duplicate(0, @buckets)

    Map.new(Keyword.keys(@figures), fn figure ->
      {figure, Enum.reduce(snapshots, zero, &Enum.zip_with(&1[figure], &2, fn a, b -> a + b end))}
    end)
  end

  @doc "The upper bound of the first bucket whose cumulative count reaches `ceil(count * p / 100)`."
  @spec percentile(counts(), number()) :: {:le, number()} | {:gt, number()} | :none
  def percentile(counts, p) do
    case Enum.sum(counts) do
      0 ->
        :none

      sum ->
        rank = max(ceil(sum * p / 100), 1)
        index = counts |> Enum.scan(&+/2) |> Enum.find_index(&(&1 >= rank))
        bounds = boundaries_ms()
        if index < length(bounds), do: {:le, Enum.at(bounds, index)}, else: {:gt, List.last(bounds)}
    end
  end

  @doc "The text `print/0` writes."
  @spec format(collected()) :: String.t()
  def format(%{merged: merged, nodes: nodes}) do
    nodes = Enum.sort_by(nodes, fn {node, _answer} -> Atom.to_string(node) end)

    Enum.map_join(@figures, "\n", fn {figure, title} ->
      lines =
        ["buckets <=: " <> Enum.join(boundaries_ms() ++ ["+Inf"], " "), "all nodes: " <> line(merged[figure])] ++
          Enum.map(nodes, fn
            {node, {:ok, snapshot}} -> "#{node}: " <> line(snapshot[figure])
            {node, :error} -> "#{node}: no answer"
          end)

      Enum.join([title | Enum.map(lines, &("  " <> &1))], "\n")
    end)
  end

  defp line(counts) do
    "count #{Enum.sum(counts)}, p50 #{rank(percentile(counts, 50))}, p99 #{rank(percentile(counts, 99))}, " <>
      "buckets " <> Enum.join(counts, " ")
  end

  defp rank({:le, bound}), do: "<= #{bound}"
  defp rank({:gt, bound}), do: "> #{bound}"
  defp rank(:none), do: "-"

  @doc "Prints the figures of all connected nodes."
  @spec print() :: :ok
  def print, do: IO.puts(format(collect()))

  @doc "Clears the figures on this node and every connected node."
  @spec reset() :: :ok
  def reset do
    _ = :erpc.multicall([node() | Node.list()], __MODULE__, :reset_local, [], 5_000)
    :ok
  end
end
