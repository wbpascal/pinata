defmodule Pinata.FiguresTest do
  # Resets the counters of the test VM.
  use ExUnit.Case, async: false

  alias Pinata.Figures

  defp n(us), do: System.convert_time_unit(us, :microsecond, :native)
  defp counts(pairs), do: Enum.map(1..15, &Map.get(Map.new(pairs), &1, 0))

  test "bucket bounds are upper bounds, inclusive" do
    assert 50 in Figures.boundaries_ms()
    assert 100 in Figures.boundaries_ms()
    assert Figures.bucket(0) == 1
    assert Figures.bucket(n(50_000)) == 9
    assert Figures.bucket(n(50_000) + 1) == 10
    assert Figures.bucket(n(100_000)) == 11
    assert Figures.bucket(n(1_000_001)) == 15
  end

  test "percentiles" do
    counts = counts(%{1 => 98, 9 => 1, 11 => 1})
    assert Figures.percentile(counts, 50) == {:le, 0.1}
    assert Figures.percentile(counts, 99) == {:le, 50}
    assert Figures.percentile(counts, 100) == {:le, 100}
    assert Figures.percentile(counts(%{}), 99) == :none
    assert Figures.percentile(counts(%{15 => 3}), 50) == {:gt, 1000}
  end

  test "merge adds element-wise" do
    a = %{packet: counts(%{1 => 1}), tick: counts(%{15 => 2})}
    b = %{packet: counts(%{1 => 2, 3 => 1}), tick: counts(%{})}
    assert Figures.merge([a, b]) == %{packet: counts(%{1 => 3, 3 => 1}), tick: counts(%{15 => 2})}
    assert Figures.merge([]) == %{packet: counts(%{}), tick: counts(%{})}
  end

  test "the stop events are counted" do
    :ok = Figures.reset_local()
    :telemetry.execute([:pinata, :packet, :stop], %{duration: n(2_000_000)}, %{})
    :telemetry.execute([:pinata, :tick, :stop], %{duration: n(2_000_000)}, %{})
    # The overflow bucket: other processes of the test VM may handle real packets meanwhile.
    assert %{packet: packet, tick: tick} = Figures.snapshot()
    assert List.last(packet) == 1
    assert List.last(tick) == 1
  end

  test "format" do
    full = %{packet: counts(%{1 => 98, 9 => 1, 11 => 1}), tick: counts(%{15 => 1})}

    text =
      Figures.format(%{
        merged: full,
        nodes: [{:b@host, :error}, {:a@host, {:ok, %{full | tick: counts(%{})}}}]
      })

    assert text =~ "Packet handling time (ms)\n  buckets <=: 0.1 0.25 0.5 1 2.5 5 10 25 50 75 100 250 500 1000 +Inf\n"
    assert text =~ "  all nodes: count 100, p50 <= 0.1, p99 <= 50, buckets 98 0 0 0 0 0 0 0 1 0 1 0 0 0 0\n"
    assert text =~ "  a@host: count 100, p50 <= 0.1, p99 <= 50, buckets "
    assert text =~ "Tick duration (ms)\n"
    assert text =~ "  all nodes: count 1, p50 > 1000, p99 > 1000, buckets "
    assert text =~ "  a@host: count 0, p50 -, p99 -, buckets 0 "
    assert text =~ "  b@host: no answer"
    assert [_, _] = Regex.scan(~r/a@host.*\n  b@host/, text)
  end
end
